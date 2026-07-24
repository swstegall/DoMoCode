// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing
@testable import DoMoTUI

@Suite("Fuzzy")
struct FuzzyTests {
    // MARK: Ranking

    @Test("Contiguous start-of-word matches rank above scattered ones")
    func ranksContiguousAboveScattered() {
        // Deliberately fed worst-first so a passing order proves the sort ran.
        let candidates = ["flavor of oregano", "xfooy", "foobar"]
        let ranked = fuzzyFilter(candidates, query: "foo", getText: { $0 }).map(\.item)
        #expect(ranked == ["foobar", "xfooy", "flavor of oregano"])
    }

    @Test("A word-boundary match scores better than a mid-word one")
    func wordBoundaryBeatsMidWord() {
        // 'b' at a '_' boundary (better/lower) vs 'b' mid-token.
        let boundary = fuzzyMatch("b", "foo_bar")
        let midWord = fuzzyMatch("b", "abc")
        #expect(boundary.matches)
        #expect(midWord.matches)
        #expect(boundary.score < midWord.score)
    }

    @Test("Exact whole-string equality is the strongest match")
    func exactMatchWins() {
        let exact = fuzzyMatch("readme", "readme")
        let prefix = fuzzyMatch("readme", "readme.md")
        #expect(exact.matches)
        #expect(prefix.matches)
        #expect(exact.score < prefix.score)
    }

    // MARK: Positions

    @Test("Match reports the grapheme indices it consumed, for highlighting")
    func reportsHighlightPositions() {
        // "compact": c0 o1 m2 p3 a4 c5 t6 — "cmp" lands on 0, 2, 3.
        let match = fuzzyMatch("cmp", "compact")
        #expect(match.matches)
        #expect(match.positions == [0, 2, 3])
    }

    @Test("Positions address graphemes, not UTF-16 units, past the BMP")
    func positionsAreGraphemeIndices() {
        // "a😀bc": grapheme 1 is the emoji (2 UTF-16 units); 'b' is grapheme 2.
        let match = fuzzyMatch("ab", "a😀bc")
        #expect(match.matches)
        #expect(match.positions == [0, 2])
    }

    @Test("An empty query matches everything with no positions")
    func emptyQueryMatches() {
        let match = fuzzyMatch("", "anything")
        #expect(match.matches)
        #expect(match.score == 0)
        #expect(match.positions.isEmpty)
    }

    // MARK: Non-matches and fallbacks

    @Test("A query not present as a subsequence does not match")
    func nonSubsequenceFails() {
        #expect(!fuzzyMatch("xyz", "abcdef").matches)
        // In order but not a subsequence: 'o' before 'f' — 'foo' can't reach.
        #expect(!fuzzyMatch("zzz", "z").matches)
    }

    @Test("Letters/digits swap fallback finds a transposed query")
    func alphaNumericSwapFallback() {
        // "2fa" fails directly against "fa2" (no letters after the trailing digit),
        // but pi's swap retries "fa2", which matches exactly.
        let direct = fuzzyMatch("2fa", "fa2")
        #expect(direct.matches)
    }

    // MARK: Stability

    @Test("Ties keep input order — the rank is stable")
    func stableTies() {
        struct Row: Sendable, Equatable { var id: Int; var text: String }
        // Same text ⇒ identical score; a stable sort must preserve 1,2,3.
        let rows = [Row(id: 1, text: "abc"), Row(id: 2, text: "abc"), Row(id: 3, text: "abc")]
        let ranked = fuzzyFilter(rows, query: "ab", getText: { $0.text }).map(\.item.id)
        #expect(ranked == [1, 2, 3])
    }

    @Test("Blank query keeps every item in input order")
    func blankQueryPassthrough() {
        let items = ["c", "a", "b"]
        let ranked = fuzzyFilter(items, query: "   ", getText: { $0 }).map(\.item)
        #expect(ranked == items)
    }

    @Test("All slash/whitespace tokens must match")
    func multiTokenConjunction() {
        // "src comp" ⇒ tokens [src, comp]; both must fuzzy-match the text.
        let both = fuzzyFilter(["src/components/button", "src/index", "docs/comparison"],
                               query: "src comp", getText: { $0 }).map(\.item)
        #expect(both == ["src/components/button"])
    }
}
