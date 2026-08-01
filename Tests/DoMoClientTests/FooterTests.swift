// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The accounting footer: where you are, and what this session has spent.
//
// Three levels, deliberately, because the failures are at three levels.
//
// * `FooterRow` is pure, so the width fitting — the part that has historically
//   killed a session by handing the renderer an over-wide row — is tested
//   exhaustively and without a terminal.
// * `EventStore` owns the arithmetic that makes the number move live and then
//   snap back to the server's answer. Asserting it here is what makes "the
//   polled total wins" a checkable claim rather than a comment.
// * The rest runs the REAL client — `runFullScreenClient`, a real `ServerClient`,
//   a real `TerminalDriver` — and asserts on the CELLS a VT100 emulator ends up
//   with. A store test proves the model; only this proves the screen.

import DoMoHarness
import DoMoLLM
import DoMoServer
import DoMoTUI
import Foundation
import Testing

@testable import DoMoClient

// MARK: - Fixtures

private func accounting(
    tokens: Int = 0,
    cost: Decimal = 0,
    contextTokens: Int = 0,
    window: Int? = 200_000,
    turns: Int = 0
) -> SessionAccounting {
    SessionAccounting(
        usage: Usage(input: tokens),
        costTotal: cost,
        contextTokens: contextTokens,
        contextWindow: window,
        turns: turns
    )
}

/// The model every width test starts from: a short path, a branch, and a session
/// that has spent something.
private let sampleModel = FooterModel(
    cwd: "/home/me/proj",
    branch: "main",
    accounting: accounting(
        tokens: 7_000,
        cost: Decimal(string: "0.0031")!,
        contextTokens: 50_000,
        window: 200_000,
        turns: 3
    )
)

// MARK: - Composition

@Suite("Footer composition")
struct FooterCompositionTests {

    @Test("At a normal width every segment is on the row, in display order")
    func fullRowAtNormalWidth() {
        let row = FooterRow.compose(sampleModel, width: 80)
        #expect(row == "/home/me/proj  git:main  tok 7.0k  $0.0031  ctx 50.0k (25%)")
    }

    @Test("Segments go in the documented order as the row narrows")
    func segmentsDropInPriorityOrder() {
        // Each of these is the FIRST width at which the row changes shape, so a
        // reordered `dropOrder` moves at least one of them.
        //
        // 59 columns is the whole row; at 55 only the path has room to give, and
        // it gives from the LEFT so the leaf stays. At 50 even eight columns of
        // path are not there, so the path goes and the branch survives. At 40 the
        // branch goes; at 30 the token count; and the context meter is the last
        // thing standing.
        #expect(FooterRow.compose(sampleModel, width: 59)
            == "/home/me/proj  git:main  tok 7.0k  $0.0031  ctx 50.0k (25%)")
        #expect(FooterRow.compose(sampleModel, width: 55)
            == "…/me/proj  git:main  tok 7.0k  $0.0031  ctx 50.0k (25%)")
        #expect(FooterRow.compose(sampleModel, width: 50)
            == "git:main  tok 7.0k  $0.0031  ctx 50.0k (25%)")
        #expect(FooterRow.compose(sampleModel, width: 40)
            == "tok 7.0k  $0.0031  ctx 50.0k (25%)")
        #expect(FooterRow.compose(sampleModel, width: 30)
            == "$0.0031  ctx 50.0k (25%)")
        #expect(FooterRow.compose(sampleModel, width: 20)
            == "ctx 50.0k (25%)")
    }

    @Test("A path that no longer fits is cut from the LEFT, keeping the leaf")
    func longPathKeepsItsTail() {
        var model = sampleModel
        model.cwd = "/home/me/very/deep/nested/workspace/leaf"
        model.branch = nil
        let row = FooterRow.compose(model, width: 45)
        #expect(row.contains("leaf"), "the identifying half of the path was thrown away: \(row)")
        #expect(!row.contains("/home"), "the head should have been the part that went: \(row)")
        #expect(row.hasPrefix("…"))
        #expect(visibleWidth(row) <= 45)
    }

    @Test("The path is offered again once a segment it was crowding out has gone")
    func pathReturnsWhenAnotherSegmentIsDropped() {
        // A single-pass drop loop that never reconsiders leaves the right half of
        // the row blank: it sheds the path, then sheds a branch that was the real
        // problem, and never notices the path would now fit whole.
        var model = sampleModel
        model.branch = "feature/truth-and-plumbing"
        // 66 columns: the long branch fits, so the path is what gives.
        #expect(FooterRow.compose(model, width: 66)
            == "git:feature/truth-and-plumbing  tok 7.0k  $0.0031  ctx 50.0k (25%)")
        // 49: the branch is gone and the path is back, whole.
        #expect(FooterRow.compose(model, width: 49)
            == "/home/me/proj  tok 7.0k  $0.0031  ctx 50.0k (25%)")
    }

    @Test("A path shorter than the floor is not dropped for columns it never wanted")
    func shortPathIsNotDroppedForTheMinimumWidth() {
        // The floor exists so a `…c` stub does not cost the numbers a column, not
        // to reserve eight columns for a two-column path.
        var model = sampleModel
        model.cwd = "/w"
        #expect(FooterRow.compose(model, width: 38) == "/w  tok 7.0k  $0.0031  ctx 50.0k (25%)")
    }

    @Test("A terminal narrower than the shortest segment still yields a fitting row")
    func degenerateWidthsNeverOverflow() {
        for width in 1...15 {
            let row = FooterRow.compose(sampleModel, width: width)
            #expect(visibleWidth(row) <= width, "w=\(width) produced \(visibleWidth(row)): \(row)")
        }
        // Not merely "it fits": at three columns the context meter is what is
        // shown, cut, rather than the row going blank.
        #expect(FooterRow.compose(sampleModel, width: 3).contains("ctx"))
        #expect(FooterRow.compose(sampleModel, width: 0).isEmpty)
    }

    @Test("No model at any width produces an over-wide row")
    func noModelOverflowsAtAnyWidth() {
        // `AltScreenCore.frame` treats an over-wide row as fatal, so this is a
        // liveness property, not a cosmetic one. Paired with the exact-content
        // assertions above so it cannot pass by returning "" everywhere.
        var deep = sampleModel
        deep.cwd = "/home/me/very/deep/nested/workspace/leaf"
        var unknown = sampleModel
        unknown.accounting = accounting(tokens: 1_234_567, cost: 9, contextTokens: 9, window: nil)
        let models = [sampleModel, deep, unknown, FooterModel(), FooterModel(cwd: "/x")]
        for model in models {
            for width in 1...200 {
                let row = FooterRow.compose(model, width: width)
                #expect(visibleWidth(row) <= width, "w=\(width): \(row)")
            }
        }
    }

    @Test("Untrusted cwd and branch text cannot paint escape sequences")
    func externalTextIsSanitized() {
        // Both come from outside the process: the cwd off the wire, the branch out
        // of `.git/HEAD`, which is whatever bytes somebody put there.
        let model = FooterModel(
            cwd: "/tmp/a\u{1b}[2Jb",
            branch: "main\u{1b}]0;pwned\u{7}",
            accounting: accounting(tokens: 10)
        )
        let row = FooterRow.compose(model, width: 200)
        // The property that matters: no control character survives to be
        // interpreted by the terminal. `sanitizeUntrustedText` REPLACES each one
        // with a visible marker rather than deleting it, so the inert remainder
        // of the payload is still there — which is the point, since silently
        // dropping bytes would make a hostile path look ordinary.
        #expect(!row.unicodeScalars.contains { $0.value == 0x1b })
        #expect(!row.unicodeScalars.contains { $0.value == 0x07 })
        #expect(row.contains("[2Jb"))
        #expect(row.contains("0;pwned"))
        #expect(row.contains("git:main"))
    }

    @Test("A multi-line branch name is folded to one row")
    func branchIsCollapsedToOneLine() {
        let model = FooterModel(cwd: "/w", branch: "main\nsecond", accounting: nil)
        let row = FooterRow.compose(model, width: 60)
        #expect(!row.contains("\n"))
        #expect(row.contains("git:main"))
    }

    @Test("Nothing accounted for prints no numbers at all, rather than zeros")
    func absentAccountingPrintsNothing() {
        // `nil` is "the server did not say", which is a different claim from
        // "$0.00". Inventing the second is the class of confident falsehood the
        // whole phase is about.
        let row = FooterRow.compose(FooterModel(cwd: "/w", branch: "main"), width: 60)
        #expect(row == "/w  git:main")
    }

    // MARK: Numbers

    @Test("Token counts are compact and roll over at the right places")
    func tokenFormatting() {
        #expect(FooterRow.formatTokens(0) == "0")
        #expect(FooterRow.formatTokens(999) == "999")
        #expect(FooterRow.formatTokens(1_000) == "1.0k")
        #expect(FooterRow.formatTokens(7_000) == "7.0k")
        #expect(FooterRow.formatTokens(8_234) == "8.2k")
        #expect(FooterRow.formatTokens(999_949) == "999.9k")
        #expect(FooterRow.formatTokens(999_950) == "1.0M")
        #expect(FooterRow.formatTokens(1_500_000) == "1.5M")
    }

    @Test("A cheap turn's cost is still a non-zero number")
    func costKeepsItsSmallDigits() {
        // Two decimal places is what a currency wants and what would render this
        // as `$0.00`, which is the exact falsehood the phase exists to remove.
        #expect(FooterRow.formatCost(Decimal(string: "0.0031")!, turns: 1, tokens: 10) == "$0.0031")
        #expect(FooterRow.formatCost(Decimal(string: "12.5")!, turns: 9, tokens: 10) == "$12.5")
    }

    @Test("A credit renders as a negative number, never as an unpriced session")
    func aNegativeCostIsANumberAndNotAQuestionMark() {
        // `$0.00?` is reserved for exactly one situation: nobody priced this
        // session. A credit — `costTotal` is whatever number arrived in the
        // `/status` body, and nothing on this side bounds it — is a session that
        // WAS priced and came out below zero, and the old `> 0` test could not
        // tell the two apart: it showed a credit as "unpriced", a different claim
        // entirely.
        #expect(FooterRow.formatCost(Decimal(string: "-0.25")!, turns: 4, tokens: 12_000) == "-$0.25")
        #expect(FooterRow.formatCost(Decimal(string: "-12.5")!, turns: 1, tokens: 10) == "-$12.5")
        // The sign goes in front of the amount, the way accounting spells a
        // credit, and never inside it.
        #expect(!FooterRow.formatCost(Decimal(string: "-0.25")!, turns: 1, tokens: 1).contains("$-"))
        // Exactly zero is still the unknown marker, so the fix did not widen it.
        #expect(FooterRow.formatCost(0, turns: 4, tokens: 12_000) == "$0.00?")
    }

    @Test("A negative total still composes a row that fits")
    func aNegativeCostFitsTheRow() {
        // The `?` and the `-` are different widths; this is the fitting loop
        // seeing the new spelling.
        var model = sampleModel
        model.accounting = accounting(
            tokens: 7_000, cost: Decimal(string: "-0.25")!,
            contextTokens: 50_000, window: 200_000, turns: 3
        )
        #expect(FooterRow.compose(model, width: 80).contains("-$0.25"))
        for width in 1...200 { #expect(visibleWidth(FooterRow.compose(model, width: width)) <= width) }
    }

    @Test("A session that spent nothing shows $0.00, and one that cannot know marks it")
    func zeroCostIsPrintedAndQualified() {
        // No turns: the session genuinely has not spent anything.
        #expect(FooterRow.formatCost(0, turns: 0, tokens: 0) == "$0.00")
        // Turns AND tokens, but no cost. Either nobody priced the model or the
        // session file predates costs being recorded at all; the client cannot
        // tell, so it says so instead of asserting "free".
        #expect(FooterRow.formatCost(0, turns: 4, tokens: 12_000) == "$0.00?")
        // Turns with no tokens is not that situation.
        #expect(FooterRow.formatCost(0, turns: 4, tokens: 0) == "$0.00")
    }

    @Test("An unknown context window renders ? and never a percentage")
    func unknownContextWindowShowsAQuestionMark() {
        let unknown = FooterRow.formatContext(accounting(contextTokens: 50_000, window: nil))
        #expect(unknown == "ctx 50.0k (?)")
        #expect(!unknown.contains("%"), "a percentage of a fallback window is a new lie for an old one")
        // A zero or negative window is just as unknown as an absent one.
        #expect(FooterRow.formatContext(accounting(contextTokens: 10, window: 0)) == "ctx 10 (?)")
    }

    @Test("A known window gives a percentage, uncapped at 100 and bounded above")
    func knownContextWindowGivesAPercentage() {
        #expect(FooterRow.formatContext(accounting(contextTokens: 50_000, window: 200_000))
            == "ctx 50.0k (25%)")
        // Past the window is a real state — the next turn is what compacts — so
        // it is reported rather than pinned at 100.
        #expect(FooterRow.formatContext(accounting(contextTokens: 300_000, window: 200_000))
            == "ctx 300.0k (150%)")
        // A hostile snapshot must not trap the multiply or widen the row.
        let absurd = FooterRow.formatContext(accounting(contextTokens: Int.max, window: 1))
        #expect(absurd.hasSuffix("(9999%)"))
    }

    @Test("A hostile /status body draws a row instead of killing the session")
    func absurdTotalsCannotTrapTheFooter() throws {
        // DECODED, not constructed. The trap this closes is on numbers that
        // arrive over the socket: `ServerClient.status` uses a plain
        // `JSONDecoder` and nothing bounds any field on the way in, so a buggy,
        // older or hostile server puts these straight into the footer's
        // arithmetic. A hand-built fixture would not prove the decoder lets them
        // through.
        let json = """
            {"usage":{"input":9223372036854775807,"output":9223372036854775807,\
            "cacheRead":9223372036854775807,"cacheWrite":9223372036854775807,\
            "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}},\
            "costTotal":0,"contextTokens":9223372036854775807,\
            "contextWindow":1,"turns":9223372036854775807}
            """
        let totals = try JSONDecoder().decode(SessionAccounting.self, from: Data(json.utf8))
        #expect(totals.usage.input == Int.max, "the decoder did not carry the value through")
        // Every one of these three lines is a SIGTRAP without the saturation, in
        // debug AND in release: `+` on `Int` traps on overflow in both.
        #expect(totals.usage.totalTokens == Int.max)
        #expect(FooterRow.formatTokens(totals.usage.totalTokens).hasSuffix("M"))
        let row = FooterRow.compose(FooterModel(cwd: "/w", branch: "main", accounting: totals), width: 200)
        #expect(visibleWidth(row) <= 200)
        #expect(row.contains("tok "))
        #expect(row.hasSuffix("(9999%)"))
    }

    @Test("The rendered row is one line and fits, escapes included")
    @MainActor
    func footerBarPaintsOneFittingRow() {
        let bar = FooterBar()
        bar.model = sampleModel
        for width in [0, 1, 12, 40, 80, 200] {
            let lines = bar.render(width: width)
            #expect(lines.count == (width > 0 ? 1 : 0), "w=\(width)")
            for line in lines { #expect(visibleWidth(line) <= width, "w=\(width): \(line)") }
        }
        #expect(bar.render(width: 80)[0].contains("ctx 50.0k (25%)"))
    }
}

// MARK: - The fold, and what corrects it

@MainActor
@Suite("Footer accounting fold")
struct FooterAccountingTests {

    private func makeStore(_ id: String = "s1") -> EventStore {
        let store = EventStore()
        store.setSessions([SessionSummary(id: id, path: "/tmp/\(id).jsonl", cwd: "/w", timestamp: "2026")])
        store.select(id)
        return store
    }

    private func status(
        _ id: String = "s1",
        running: Bool = false,
        accounting: SessionAccounting?
    ) -> SessionStatus {
        SessionStatus(
            sessionID: id, running: running, pendingPermissionIDs: [],
            subscribers: 1, runStartedAt: nil, accounting: accounting
        )
    }

    private func assistant(_ usage: Usage, text: String = "") -> ServerEvent {
        .messageEnd(.assistant(AssistantMessage(
            content: text.isEmpty ? [] : [.text(text)],
            model: "test-model",
            usage: usage
        )))
    }

    @Test("Nothing said means nil, not zero")
    func nothingReportedIsNil() {
        #expect(makeStore().accounting == nil)
    }

    @Test("A streamed turn moves the totals without waiting for a poll")
    func liveFoldMovesTheNumbers() {
        // `AssistantMessage.usage` rode the wire and was decoded and dropped on
        // the floor; a footer fed only by the poll would sit still for the whole
        // five seconds between them.
        let store = makeStore()
        store.apply(assistant(Usage(input: 1_000, output: 234), text: "hi"))
        #expect(store.accounting?.usage.totalTokens == 1_234)
        #expect(store.accounting?.turns == 1)
        // No poll has happened, so the window is genuinely unknown.
        #expect(store.accounting?.contextWindow == nil)
    }

    @Test("A tool-call-only turn is billed too")
    func aTurnWithNoTextIsStillFolded() {
        // The display switch matches assistant messages WITH text; folding inside
        // it would bill the turns that talked and not the turns that worked.
        let store = makeStore()
        store.apply(assistant(Usage(input: 500, output: 20)))
        #expect(store.accounting?.usage.totalTokens == 520)
        #expect(store.accounting?.turns == 1)
    }

    @Test("Turns accumulate, and the reported cost accumulates with them")
    func foldsAccumulate() {
        let store = makeStore()
        store.apply(assistant(Usage(input: 100, reportedCost: Decimal(string: "0.001")!)))
        store.apply(assistant(Usage(input: 200, reportedCost: Decimal(string: "0.002")!)))
        #expect(store.accounting?.usage.totalTokens == 300)
        #expect(store.accounting?.turns == 2)
        #expect(store.accounting?.costTotal == Decimal(string: "0.003")!)
    }

    @Test("A polled snapshot REPLACES the local fold rather than adding to it")
    func polledTotalWinsOverTheFold() {
        // The server counted the turns this client never saw — everything before
        // it attached, plus every compaction. Adding the local delta on top would
        // double-count exactly the turns the poll already includes.
        let store = makeStore()
        store.apply(assistant(Usage(input: 1_000, output: 234)))
        #expect(store.accounting?.usage.totalTokens == 1_234)

        store.adopt(status(accounting: accounting(
            tokens: 90_000, cost: Decimal(string: "0.5")!, contextTokens: 60_000,
            window: 128_000, turns: 5
        )))
        #expect(store.accounting?.usage.totalTokens == 90_000, "the fold must be discarded, not added")
        #expect(store.accounting?.turns == 5)
        #expect(store.accounting?.costTotal == Decimal(string: "0.5")!)
        #expect(store.accounting?.contextTokens == 60_000)
        #expect(store.accounting?.contextWindow == 128_000)
    }

    @Test("A turn after a poll is a delta on top of it")
    func foldsResumeOnTopOfThePolledBaseline() {
        let store = makeStore()
        store.adopt(status(accounting: accounting(
            tokens: 90_000, cost: Decimal(string: "0.5")!, contextTokens: 60_000, turns: 5
        )))
        store.apply(assistant(Usage(input: 1_000, output: 234, reportedCost: Decimal(string: "0.25")!)))
        #expect(store.accounting?.usage.totalTokens == 91_234)
        #expect(store.accounting?.turns == 6)
        #expect(store.accounting?.costTotal == Decimal(string: "0.75")!)
        // The window survives the delta — only the server knows it.
        #expect(store.accounting?.contextWindow == 200_000)
    }

    @Test("A server that reports no accounting leaves the fold alone")
    func aSnapshotWithoutTotalsDoesNotWipeTheFold() {
        // An older runtime answers `/status` without the field. Treating that as
        // "zero" would blank a footer that had real numbers on it.
        let store = makeStore()
        store.apply(assistant(Usage(input: 1_000)))
        store.adopt(status(accounting: nil))
        #expect(store.accounting?.usage.totalTokens == 1_000)
        // …but it must stop the client asking again forever.
        #expect(store.wantsAccountingPoll == false)
    }

    @Test("A folded turn arms one poll, and one answer disarms it")
    func aFoldedTurnAsksForExactlyOnePoll() {
        let store = makeStore()
        #expect(store.wantsAccountingPoll == false, "a fresh session has nothing to correct")
        store.apply(assistant(Usage(input: 10)))
        #expect(store.wantsAccountingPoll)
        store.adopt(status(accounting: accounting(tokens: 10, turns: 1)))
        #expect(store.wantsAccountingPoll == false)
        // A failure disarms it too, or a dead runtime is polled forever.
        store.apply(assistant(Usage(input: 10)))
        #expect(store.wantsAccountingPoll)
        store.noteAccountingPollFailed()
        #expect(store.wantsAccountingPoll == false)
    }

    @Test("A re-seed keeps the totals; switching session drops them")
    func accountingIsSessionScopedAndSurvivesAReSeed() {
        // `seed` runs again on every reconnect for the SAME session. Resetting
        // there would blank the footer on every stream blip.
        let store = makeStore()
        store.apply(assistant(Usage(input: 1_000)))
        store.seed([])
        #expect(store.accounting?.usage.totalTokens == 1_000)

        store.select("other")
        #expect(store.accounting == nil, "another session is another bill")
    }

    @Test("A snapshot for a session that is no longer open is ignored")
    func aStaleSnapshotCannotRewriteAnotherSessionsTotals() {
        let store = makeStore()
        store.apply(assistant(Usage(input: 1_000)))
        store.adopt(status("someone-else", accounting: accounting(tokens: 99, turns: 9)))
        #expect(store.accounting?.usage.totalTokens == 1_000)
    }

    @Test("The accounting-only entry point checks the session too, not just adopt()")
    func adoptAccountingChecksItsOwnSession() {
        // `adoptAccounting` is a SECOND door — the session-open seed calls it
        // directly, never through `adopt` — so its own guard has to be exercised
        // directly. The test above only ever reached the guard inside `adopt`,
        // which left this one dead code that nothing would have noticed the loss
        // of.
        let store = makeStore()
        store.apply(assistant(Usage(input: 1_000)))
        #expect(store.wantsAccountingPoll)
        store.adoptAccounting(status("someone-else", accounting: accounting(tokens: 99, turns: 9)))
        #expect(store.accounting?.usage.totalTokens == 1_000, "another session's totals were adopted")
        #expect(store.accounting?.turns == 1)
        // The guard sits BEFORE the flag, and must: a poll answered for the
        // session we just left has not answered this one's question.
        #expect(store.wantsAccountingPoll, "the wrong session's answer disarmed this session's poll")
    }

    // MARK: The context estimate

    @Test("A streamed turn's own usage is what the context meter reads between polls")
    func aFoldedTurnSetsTheContextEstimate() {
        // The live estimate was entirely untested: replacing the assignment with
        // `0` left the whole suite green. It is the prompt (billed, cached and
        // cache-written alike) plus the completion.
        let store = makeStore()
        store.apply(assistant(Usage(input: 1_000, output: 234, cacheRead: 500, cacheWrite: 100)))
        #expect(store.accounting?.contextTokens == 1_834)
        // And on top of a polled baseline it supersedes the server's older figure.
        let store2 = makeStore()
        store2.adopt(status(accounting: accounting(
            tokens: 90_000, contextTokens: 60_000, window: 120_000, turns: 5
        )))
        store2.apply(assistant(Usage(input: 1_000, output: 234, cacheRead: 500, cacheWrite: 100)))
        #expect(store2.accounting?.contextTokens == 1_834)
    }

    @Test("An aborted turn does not rebase the context meter onto zero")
    func aTurnThatReportedNoUsageLeavesTheContextEstimateAlone() {
        // `AgentLoop` emits `message_end` for an assistant message with
        // `usage: .zero` when the user presses Esc. Taking that literally read
        // `ctx 0 (0%)` on a 120k context and stuck there until the next poll. A
        // turn that reported nothing has not told us the context shrank.
        let store = makeStore()
        store.adopt(status(accounting: accounting(
            tokens: 90_000, contextTokens: 60_000, window: 120_000, turns: 5
        )))
        store.apply(assistant(.zero))
        #expect(store.accounting?.contextTokens == 60_000, "an abort deleted the context meter")
        // The abort is still a turn, and still folds into the totals — only the
        // context ESTIMATE is left alone.
        #expect(store.accounting?.turns == 6)
        #expect(store.accounting?.usage.totalTokens == 90_000)
        #expect(store.wantsAccountingPoll, "the abort still needs the server's correction")
    }

    @Test("With no earlier number to keep, a usage-less turn honestly reads zero")
    func theLegitimateZeroContextStillReadsZero() {
        // The other half of the guard: it must not invent a context out of
        // nothing, and it must not freeze the meter once a real number exists.
        let store = makeStore()
        store.apply(assistant(.zero))
        #expect(store.accounting?.turns == 1)
        #expect(store.accounting?.contextTokens == 0, "there was no earlier figure to preserve")
        store.apply(assistant(Usage(input: 700, output: 42)))
        #expect(store.accounting?.contextTokens == 742, "a real turn must still move it")
        store.apply(assistant(.zero))
        #expect(store.accounting?.contextTokens == 742, "and an abort after it must not delete it")
    }

    // MARK: A snapshot older than the fold

    @Test("A /status computed before a turn was persisted cannot delete that turn")
    func aStalePollCannotUnfoldATurn() {
        // The interleave: the poll's snapshot is taken, the turn is persisted and
        // streamed, the client folds it, and only THEN does the snapshot arrive.
        // Adopting it would re-base onto the older total, discard the delta and
        // disarm the poll — so the turn's tokens and cost vanish until the next
        // prompt re-arms everything.
        let store = makeStore()
        let before = accounting(
            tokens: 90_000, cost: Decimal(string: "0.5")!,
            contextTokens: 60_000, window: 120_000, turns: 5
        )
        store.adopt(status(accounting: before))
        store.apply(assistant(Usage(input: 1_000, output: 234, reportedCost: Decimal(string: "0.25")!)))
        #expect(store.accounting?.usage.totalTokens == 91_234)

        store.adopt(status(accounting: before))     // the snapshot from before the turn
        #expect(store.accounting?.usage.totalTokens == 91_234, "a stale poll deleted the folded turn")
        #expect(store.accounting?.turns == 6)
        #expect(store.accounting?.costTotal == Decimal(string: "0.75")!)
        #expect(store.wantsAccountingPoll, "and it must leave the poll armed to ask again")

        // The answer that does include the turn wins, exactly as it always did.
        store.adopt(status(accounting: accounting(
            tokens: 91_234, cost: Decimal(string: "0.75")!,
            contextTokens: 61_000, window: 120_000, turns: 6
        )))
        #expect(store.accounting?.turns == 6)
        #expect(store.accounting?.contextTokens == 61_000)
        #expect(store.wantsAccountingPoll == false)
    }

    @Test("The staleness guard cannot weld the poll shut when the CLIENT is what is wrong")
    func aPersistentlyLowSnapshotIsEventuallyBelieved() {
        // If the fold is the thing that is wrong — one turn counted twice —
        // refusing forever would leave the footer permanently inflated and the
        // poll re-asking every five seconds with no answer it would ever accept.
        // The server is the authority; the refusal is bounded.
        let store = makeStore()
        store.adopt(status(accounting: accounting(tokens: 90_000, turns: 5)))
        store.apply(assistant(Usage(input: 1_000)))
        store.apply(assistant(Usage(input: 1_000)))   // the same turn, folded twice
        #expect(store.accounting?.turns == 7)

        let truth = status(accounting: accounting(tokens: 91_000, contextTokens: 61_000, turns: 6))
        store.adopt(truth)
        #expect(store.accounting?.turns == 7, "the first refusal")
        store.adopt(truth)
        #expect(store.accounting?.turns == 7, "the second refusal")
        store.adopt(truth)
        #expect(store.accounting?.turns == 6, "the guard never let go of a wrong local count")
        #expect(store.accounting?.usage.totalTokens == 91_000)
        #expect(store.wantsAccountingPoll == false)
    }

    @Test("A snapshot with no totals is still an answer, stale guard or not")
    func aSnapshotWithoutTotalsStillDisarmsThePoll() {
        // The guard reads `status.accounting`; a server that reports none must
        // still be able to stop the poll loop, or an older runtime is asked every
        // five seconds forever.
        let store = makeStore()
        store.adopt(status(accounting: accounting(tokens: 90_000, turns: 5)))
        store.apply(assistant(Usage(input: 1_000)))
        store.adopt(status(accounting: nil))
        #expect(store.accounting?.usage.totalTokens == 91_000)
        #expect(store.wantsAccountingPoll == false)
    }

    // MARK: Numbers that arrived over a socket

    @Test("Absurd totals fold and re-base without trapping the session")
    func hostileNumbersSaturateInsteadOfTrapping() {
        // Both doors, on the store: the SSE fold (`Usage.+`) and the
        // baseline-plus-delta sum the footer reads every frame.
        let store = makeStore()
        store.apply(assistant(Usage(input: Int.max, output: Int.max)))
        store.apply(assistant(Usage(input: Int.max, output: Int.max)))
        #expect(store.accounting?.usage.totalTokens == Int.max)

        let other = makeStore("s2")
        other.adopt(status("s2", accounting: SessionAccounting(
            usage: Usage(input: Int.max), costTotal: 0, contextTokens: Int.max,
            contextWindow: 1, turns: Int.max
        )))
        other.apply(assistant(Usage(input: 10)))
        #expect(other.accounting?.turns == Int.max, "baseline.turns + pendingTurns trapped")
        #expect(other.accounting?.usage.totalTokens == Int.max)
    }
}

// MARK: - On the screen

@MainActor
@Suite(.serialized, .timeLimit(.minutes(4)))
struct FooterScreenTests {
    private static let token = "footer-screen-token"
    private static let sessionRef = #"{"id":"abc123","path":"/tmp/abc123.jsonl"}"#
    private static let sessionList =
        #"[{"id":"abc123","path":"/tmp/abc123.jsonl","cwd":"/home/me/proj","timestamp":"2026-01-01"}]"#

    /// SSE frames encoded by the SAME `Codable` the server uses, so the wire
    /// format cannot drift from a hand-written literal here.
    private static func sse(_ events: [ServerEvent]) -> String {
        let encoder = JSONEncoder()
        return events.map { event in
            let json = (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return "data: \(json)\n\n"
        }.joined()
    }

    private static func connected(running: Bool) -> String {
        sse([.connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: running)])
    }

    private static func statusBody(running: Bool, _ totals: SessionAccounting?) -> String {
        let status = SessionStatus(
            sessionID: "abc123", running: running, pendingPermissionIDs: [],
            subscribers: 1, runStartedAt: nil, accounting: totals
        )
        return (try? JSONEncoder().encode(status)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// A runtime that comes up healthy, with `extra` spliced in FIRST so a test
    /// can make one endpoint answer differently.
    private static func runtime(_ extra: [StubRoute] = []) throws -> ExplainingServer {
        try ExplainingServer(
            routes: extra + [
                StubRoute("GET", "/status", 200, "OK", statusBody(running: false, nil)),
                StubRoute("GET", "/sessions", 200, "OK", sessionList),
                StubRoute("GET", "/messages", 200, "OK", "[]"),
                StubRoute("GET", "/permissions", 200, "OK", "[]"),
                StubRoute("GET", "/events", 200, "OK", connected(running: false)),
                StubRoute("POST", "/session", 201, "Created", sessionRef),
            ],
            fallback: StubRoute("", "", 404, "Not Found", "")
        )
    }

    @Test("At a normal width the footer shows cwd, tokens, cost and the context meter")
    func footerReachesTheScreen() async throws {
        let totals = accounting(
            tokens: 7_000, cost: Decimal(string: "0.0031")!,
            contextTokens: 50_000, window: 200_000, turns: 3
        )
        let stub = try Self.runtime([
            StubRoute("GET", "/status", 200, "OK", Self.statusBody(running: false, totals)),
        ])
        stub.start()
        defer { stub.stop() }
        // One whole-client run at a time — see FullScreenClientGate. These tests
        // watch for a value that is on screen only between two network answers,
        // and a second client on the same main actor spends that window.
        await FullScreenClientGate.shared.enter()

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        // ONE row must hold all four. Scattered across the screen proves nothing:
        // the cwd is also in the sidebar, and every number would still "appear"
        // if the footer row itself were deleted and the values logged elsewhere.
        let shown = await client.waitForRow(
            with: ["/home/me/proj", "tok 7.0k", "$0.0031", "ctx 50.0k (25%)"]
        )
        #expect(shown, "no single row carried the footer:\n\(client.joined())")
        await client.quit()
        await FullScreenClientGate.shared.leave()
    }

    @Test("A session that spent nothing shows $0.00 on the footer, not a blank")
    func zeroCostReachesTheScreen() async throws {
        let stub = try Self.runtime([
            StubRoute("GET", "/status", 200, "OK",
                      Self.statusBody(running: false, accounting(window: 200_000))),
        ])
        stub.start()
        defer { stub.stop() }
        // One whole-client run at a time — see FullScreenClientGate. These tests
        // watch for a value that is on screen only between two network answers,
        // and a second client on the same main actor spends that window.
        await FullScreenClientGate.shared.enter()

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        let shown = await client.waitForRow(with: ["/home/me/proj", "tok 0", "$0.00", "ctx 0 (0%)"])
        #expect(shown, "a spent-nothing session drew no footer numbers:\n\(client.joined())")
        await client.quit()
        await FullScreenClientGate.shared.leave()
    }

    @Test("An unknown context window puts ? on the screen, never a percentage")
    func unknownWindowReachesTheScreen() async throws {
        let totals = accounting(
            tokens: 7_000, cost: Decimal(string: "0.0031")!,
            contextTokens: 50_000, window: nil, turns: 3
        )
        let stub = try Self.runtime([
            StubRoute("GET", "/status", 200, "OK", Self.statusBody(running: false, totals)),
        ])
        stub.start()
        defer { stub.stop() }
        // One whole-client run at a time — see FullScreenClientGate. These tests
        // watch for a value that is on screen only between two network answers,
        // and a second client on the same main actor spends that window.
        await FullScreenClientGate.shared.enter()

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        let shown = await client.waitForRow(with: ["/home/me/proj", "ctx 50.0k (?)"])
        #expect(shown, "the unknown-window meter never drew:\n\(client.joined())")
        // The compaction fallback is 200_000, which would have rendered 25%.
        #expect(!client.showing("25%"), "a percentage of the fallback window reached the screen")
        await client.quit()
        await FullScreenClientGate.shared.leave()
    }

    @Test("A narrow terminal sheds segments instead of overflowing the row")
    func narrowTerminalKeepsTheContextMeter() async throws {
        let totals = accounting(
            tokens: 7_000, cost: Decimal(string: "0.0031")!,
            contextTokens: 50_000, window: 200_000, turns: 3
        )
        let stub = try Self.runtime([
            StubRoute("GET", "/status", 200, "OK", Self.statusBody(running: false, totals)),
        ])
        stub.start()
        defer { stub.stop() }
        await FullScreenClientGate.shared.enter()

        // 40 columns leaves the main column 24 wide once the sidebar takes its
        // minimum 16 — room for the cost and the context meter and nothing else.
        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token, columns: 40, rows: 24)
        let shown = await client.waitForRow(with: ["$0.0031", "ctx 50.0k (25%)"])
        #expect(shown, "the footer lost its last two segments on a narrow screen:\n\(client.joined())")
        #expect(!client.showing("tok 7.0k"), "the token count should have been shed first")
        await client.quit()
        await FullScreenClientGate.shared.leave()
    }

    @Test("A status poll corrects a live fold instead of stacking on top of it")
    func aPollCorrectsTheLiveFold() async throws {
        // The first `/status` answers 7.0k; a streamed turn then adds 1,234
        // locally, which is 8.2k; the next `/status` answers 90.0k. If the poll
        // re-based nothing the screen would read 91.2k, so 90.0k is reachable
        // only by discarding the fold — which is exactly the claim.
        //
        // The turn arrives on the SECOND `/events` body rather than the first,
        // and each body is served once. That is what makes the ordering
        // deterministic: the open-time poll is issued in the same main-actor hop
        // as the first subscription, so a turn on that body would race it, and
        // the reconnect's own backoff puts the second body unambiguously after.
        // It also stops the same turn being re-folded by every reconnect, which
        // would make the number a moving target.
        let first = accounting(tokens: 7_000, contextTokens: 50_000, window: 200_000, turns: 3)
        let second = accounting(tokens: 90_000, contextTokens: 60_000, window: 200_000, turns: 5)
        let turn = Self.sse([
            .connected(protocolVersion: serverProtocolVersion, sessionID: "abc123", running: false),
            .messageEnd(.assistant(AssistantMessage(
                content: [.text("done")], model: "test-model",
                usage: Usage(input: 1_000, output: 234)
            ))),
        ])
        // Every frame says `running: false`, which is what pins the ordering.
        // The five-second poll runs only while a turn is in flight or while a
        // folded turn is waiting to be corrected, so the second `/status` cannot
        // be reached until the fold has happened — there is no clock here to
        // race, only a sequence.
        let stub = try Self.runtime([
            StubRoute("GET", "/status", 200, "OK", Self.statusBody(running: false, first), times: 1),
            StubRoute("GET", "/status", 200, "OK", Self.statusBody(running: false, second)),
            StubRoute("GET", "/events", 200, "OK", Self.connected(running: false), times: 1),
            StubRoute("GET", "/events", 200, "OK", turn, times: 1),
        ])
        stub.start()
        defer { stub.stop() }
        // One whole-client run at a time — see FullScreenClientGate. These tests
        // watch for a value that is on screen only between two network answers,
        // and a second client on the same main actor spends that window.
        await FullScreenClientGate.shared.enter()

        let client = WedgeClient(baseURL: stub.baseURL, token: Self.token)
        #expect(await client.wait(for: "tok 8.2k"),
                "the streamed turn never moved the footer:\n\(client.joined())")
        #expect(await client.waitForRow(with: ["tok 90.0k"], timeout: .seconds(40)),
                "the poll never re-based the total:\n\(client.joined())")
        #expect(!client.showing("tok 91.2k"),
                "the polled total was added to the fold instead of replacing it")
        await client.quit()
        await FullScreenClientGate.shared.leave()
    }
}

// MARK: - The row the footer costs

@Suite("Footer geometry")
struct FooterGeometryTests {

    @Test("The footer's row never comes out of the transcript's last one")
    func theFooterNeverStarvesTheTranscript() {
        // `Fixed.measure` returns its basis unconditionally and the flexible
        // transcript is handed only what is left, so a second unconditional
        // footer row takes the transcript to zero and then overruns the rect.
        for height in 3...80 {
            let rows = ClientLayout.footerRows(for: height)
            let cap = ClientLayout.promptRowCap(for: height, footerRows: rows)
            let layout = ClientLayout(width: 80, height: height, promptRows: cap, footerRows: rows)
            #expect(layout.transcriptHeight >= 1, "h=\(height) rows=\(rows) cap=\(cap)")
        }
    }

    @Test("A terminal too short for both drops the footer, not the conversation")
    func shortTerminalsShedTheFooterFirst() {
        #expect(ClientLayout.footerRows(for: 9) == 0)
        #expect(ClientLayout.footerRows(for: 10) == 1)
        // And the row really is a row: this is what it costs.
        #expect(ClientLayout(width: 80, height: 24, promptRows: 3, footerRows: 1).transcriptHeight == 19)
        #expect(ClientLayout(width: 80, height: 24, promptRows: 3, footerRows: 0).transcriptHeight == 20)
        #expect(ClientLayout(width: 80, height: 24, promptRows: 3, footerRows: 1).mainFooterRows == 5)
    }

    @Test("Asking for no footer leaves the old geometry byte for byte")
    func theDefaultGeometryIsUnchanged() {
        // Everything that does not paint a footer — the pane hit tests, the
        // existing layout suite — must see exactly what it saw before.
        #expect(ClientLayout(width: 100, height: 24, promptRows: 5).footerRows == 0)
        #expect(ClientLayout(width: 100, height: 24, promptRows: 5).transcriptHeight == 18)
        #expect(ClientLayout.promptRowCap(for: 24) == 8)
        // With a footer the ceiling still binds at ordinary heights, and the
        // one-transcript-row clamp binds at small ones.
        #expect(ClientLayout.promptRowCap(for: 24, footerRows: 1) == 8)
        #expect(ClientLayout.promptRowCap(for: 12, footerRows: 1) == 4)
        #expect(ClientLayout.promptRowCap(for: 10, footerRows: 1) == 3)
        // A height the app never asks for a footer at, so that the one-transcript-
        // row clamp is the binding constraint and the `footerRows` term is
        // actually observable. Without it this is 3, and the transcript is 0.
        #expect(ClientLayout.promptRowCap(for: 5, footerRows: 1) == 2)
        #expect(ClientLayout(width: 80, height: 5, promptRows: 2, footerRows: 1).transcriptHeight == 1)
    }

    @Test("A footer row is inside the main footer pane, never the transcript")
    func theFooterRowHitTestsAsFooter() {
        // The hit test is what a wheel report and a drag-selection are clamped
        // to; a layout that forgot the extra row would send a click on the footer
        // into the transcript.
        let layout = ClientLayout(width: 100, height: 24, promptRows: 3, footerRows: 1)
        #expect(layout.pane(atColumn: 60, row: 18) == .transcript)
        #expect(layout.pane(atColumn: 60, row: 19) == .mainFooter)   // status
        #expect(layout.pane(atColumn: 60, row: 20) == .mainFooter)   // accounting
        #expect(layout.pane(atColumn: 60, row: 23) == .mainFooter)   // prompt
        #expect(layout.bounds(of: .transcript).rows == 0..<19)
    }
}
