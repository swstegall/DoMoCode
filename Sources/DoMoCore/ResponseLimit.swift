// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Settings

/// The knobs behind the adaptive response-character limit.
///
/// The problem this exists for: a LiteLLM gateway in front of the model refuses
/// to return a response past some character count it never documents and never
/// reports. The turn simply comes back short, or does not come back at all. The
/// only way to find the real ceiling is to ask for a little more than the last
/// thing that worked and see what happens — so every prompt carries a limit
/// sentence, and every Nth prompt asks for slightly more than the current
/// known-good ceiling.
///
/// The values here are policy inputs only. ``ResponseLimitPolicy`` clamps every
/// one of them again before using it, because a typo in `settings.json` reaching
/// an integer multiplication is a crashed session rather than a bad answer, and
/// a crashed session is the worse failure by a wide margin.
public struct ResponseLimitSettings: Sendable, Hashable, Codable {
    /// Whether a limit sentence is appended at all. On by default: the gateway's
    /// silent ceiling is the normal case for the deployment this was written for,
    /// and a limit that has to be switched on is a limit nobody switches on.
    public var enabled: Bool
    /// The seed ceiling used for a model nothing has been learned about yet.
    public var thresholdCharacters: Int
    /// How far above the known-good ceiling a probe reaches, in percent.
    public var jumpPercentage: Int
    /// Probe on every Nth eligible prompt. Every prompt still carries a limit;
    /// this only controls how often that limit is a question rather than an
    /// answer.
    public var probeEvery: Int
    /// The floor a learned ceiling may never fall below. Without it, a run of
    /// unrelated failures would back the limit down until the model could only
    /// answer in fragments, and the user would blame the model.
    public var minimumThreshold: Int
    /// The ceiling a probe may never reach past, so a gateway with no limit at
    /// all does not drive an unbounded search.
    public var maximumThreshold: Int
    /// The sentence appended to each prompt. `{limit}` is replaced with the
    /// decimal limit; see ``ResponseLimitPolicy/limitToken``.
    public var template: String

    /// The shipped sentence. Kept as a named constant because both the renderer
    /// and the idempotence scan have to agree on it exactly.
    public static let defaultTemplate = "Respond in less than {limit} characters or less."

    public init(
        enabled: Bool = true,
        thresholdCharacters: Int = 500,
        jumpPercentage: Int = 10,
        probeEvery: Int = 4,
        minimumThreshold: Int = 200,
        maximumThreshold: Int = 200_000,
        template: String = ResponseLimitSettings.defaultTemplate
    ) {
        self.enabled = enabled
        self.thresholdCharacters = thresholdCharacters
        self.jumpPercentage = jumpPercentage
        self.probeEvery = probeEvery
        self.minimumThreshold = minimumThreshold
        self.maximumThreshold = maximumThreshold
        self.template = template
    }

    public static let `default` = ResponseLimitSettings()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case thresholdCharacters
        case jumpPercentage
        case probeEvery
        case minimumThreshold
        case maximumThreshold
        case template
    }

    /// Decodes field by field, falling back to the shipped default for anything
    /// absent.
    ///
    /// Not the synthesized initializer, which requires every key: these settings
    /// can arrive from a hand-edited file, and "you left out `probeEvery`, so
    /// none of your other values took effect" is a failure mode with no visible
    /// symptom. A partial object is a legitimate way to say "change one thing".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ResponseLimitSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        thresholdCharacters =
            try container.decodeIfPresent(Int.self, forKey: .thresholdCharacters)
            ?? fallback.thresholdCharacters
        jumpPercentage =
            try container.decodeIfPresent(Int.self, forKey: .jumpPercentage) ?? fallback.jumpPercentage
        probeEvery = try container.decodeIfPresent(Int.self, forKey: .probeEvery) ?? fallback.probeEvery
        minimumThreshold =
            try container.decodeIfPresent(Int.self, forKey: .minimumThreshold) ?? fallback.minimumThreshold
        maximumThreshold =
            try container.decodeIfPresent(Int.self, forKey: .maximumThreshold) ?? fallback.maximumThreshold
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? fallback.template
    }
}

// MARK: - Learned state

/// What has been learned about one model alias' response ceiling.
///
/// One record per alias rather than one per gateway: aliases on the same LiteLLM
/// deployment can route to different upstreams with different response budgets,
/// and folding them together would let the smallest one drag every other model's
/// ceiling down.
public struct ResponseLimitState: Sendable, Hashable, Codable {
    /// The highest limit known to have been answered in full.
    public var threshold: Int
    /// The lowest limit ever observed to fail, or nil when the search has no
    /// upper bound yet. Its presence is what turns the probe from "reach 10%
    /// higher" into a binary search downward toward the real ceiling.
    public var knownBad: Int?
    /// The longest assistant text delivered intact. Diagnostic only — the policy
    /// never reads it — but it is the one number that says whether the learned
    /// threshold is being exercised at all.
    public var maxObservedSuccess: Int
    /// Eligible prompts since the last probe. The cadence counter.
    public var promptsSinceProbe: Int
    /// Non-probe failures in a row. Two of them are read as the gateway having
    /// moved, not as a coincidence, and trigger the back-off.
    public var consecutiveFailures: Int

    /// Seeds a state for an alias nothing is known about.
    ///
    /// The threshold is stored exactly as given, including an absurd one: this
    /// type is a record of observations, and the clamping belongs in
    /// ``ResponseLimitPolicy`` where it can be reasoned about in one place
    /// rather than split between a constructor and a decoder.
    public init(threshold: Int) {
        self.threshold = threshold
        self.knownBad = nil
        self.maxObservedSuccess = 0
        self.promptsSinceProbe = 0
        self.consecutiveFailures = 0
    }

    private enum CodingKeys: String, CodingKey {
        case threshold
        case knownBad
        case maxObservedSuccess
        case promptsSinceProbe
        case consecutiveFailures
    }

    /// `threshold` is required; every other field defaults.
    ///
    /// A record with no threshold is not a partially-written record, it is not a
    /// record at all, and admitting it as `threshold: 0` would hand the policy a
    /// learned ceiling of zero. The counters are a different case: they are
    /// bookkeeping, they mean "none yet" when absent, and refusing the whole
    /// document over a missing counter would throw away every other alias'
    /// learning too.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try container.decode(Int.self, forKey: .threshold)
        knownBad = try container.decodeIfPresent(Int.self, forKey: .knownBad)
        maxObservedSuccess = try container.decodeIfPresent(Int.self, forKey: .maxObservedSuccess) ?? 0
        promptsSinceProbe = try container.decodeIfPresent(Int.self, forKey: .promptsSinceProbe) ?? 0
        consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
    }
}

/// The on-disk document: every alias' learned state under one version tag.
public struct ResponseLimitDocument: Sendable, Hashable, Codable {
    /// The only version this build writes or accepts.
    public static let currentVersion = 1

    public var version: Int
    public var models: [String: ResponseLimitState]

    public init(
        version: Int = ResponseLimitDocument.currentVersion,
        models: [String: ResponseLimitState] = [:]
    ) {
        self.version = version
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case models
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        models = try container.decodeIfPresent([String: ResponseLimitState].self, forKey: .models) ?? [:]
    }
}

// MARK: - Policy inputs and outputs

/// What to ask for on this prompt, and the state to persist for the next one.
public struct ResponseLimitDecision: Sendable, Hashable {
    /// The number that goes into the prompt, already clamped.
    public var limit: Int
    /// Whether this limit is a question rather than a repetition of what is
    /// already known to work. Only a probe's outcome may move the ceiling.
    public var isProbe: Bool
    /// The state the caller persists. Returned rather than mutated in place so
    /// the policy stays a pure function of its inputs.
    public var state: ResponseLimitState

    public init(limit: Int, isProbe: Bool, state: ResponseLimitState) {
        self.limit = limit
        self.isProbe = isProbe
        self.state = state
    }
}

/// What actually happened to a prompt that carried a limit.
public struct ResponseLimitOutcome: Sendable, Hashable {
    /// The limit that was written into the prompt — not the current threshold,
    /// which may already have moved.
    public var offeredLimit: Int
    /// Whether ``ResponseLimitPolicy/nextLimit(state:settings:)`` called this a
    /// probe.
    public var wasProbe: Bool
    /// Whether the turn produced an answer at all.
    public var succeeded: Bool
    /// The length of the longest assistant text the turn delivered.
    public var responseCharacters: Int

    public init(offeredLimit: Int, wasProbe: Bool, succeeded: Bool, responseCharacters: Int) {
        self.offeredLimit = offeredLimit
        self.wasProbe = wasProbe
        self.succeeded = succeeded
        self.responseCharacters = responseCharacters
    }
}

// MARK: - Policy

/// The whole search, as pure functions.
///
/// No clock, no file, no actor. Every decision this makes is a function of the
/// state it is handed and the settings, which is what makes the walk-through in
/// the tests — 500, probe 550, fail at 605, settle at 577 — assertable line by
/// line instead of inferred from a session that happened to run.
///
/// Arithmetic here is deliberately paranoid. Swift traps on integer overflow, so
/// `threshold * jumpPercentage` with a mistyped `jumpPercentage` of 10_000_000
/// against a large threshold is not a wrong answer, it is a dead process in the
/// middle of the user's turn. Every multiplication and addition below is
/// saturating, and every result is clamped into the configured band.
public enum ResponseLimitPolicy {

    /// The placeholder replaced with the decimal limit when a template is
    /// rendered, and matched as one-or-more ASCII digits when a previously
    /// rendered sentence is recognised for removal.
    public static let limitToken = "{limit}"

    /// The settings after the defensive clamping every entry point applies.
    ///
    /// Extracted so the two public functions cannot disagree about what
    /// `minimumThreshold > maximumThreshold` means — an inverted band is the
    /// shape a `clamp` silently gets wrong, returning the *minimum* for every
    /// input and pinning the limit at a value the user asked never to exceed.
    private struct Bounds {
        let minimum: Int
        let maximum: Int
        let jump: Int
        let cadence: Int

        init(_ settings: ResponseLimitSettings) {
            let minimum = max(1, settings.minimumThreshold)
            self.minimum = minimum
            self.maximum = max(minimum, settings.maximumThreshold)
            self.jump = max(0, settings.jumpPercentage)
            self.cadence = max(1, settings.probeEvery)
        }
    }

    // MARK: Choosing a limit

    /// The limit to offer on the next prompt for `state`'s alias.
    ///
    /// Two independent gates have to open before a probe happens. There must be
    /// somewhere to probe *to* — a candidate strictly above the current
    /// threshold — and the cadence has to be due. Either one closed produces an
    /// ordinary prompt at the known-good threshold with the cadence counter
    /// advanced, which is the case that runs almost every turn.
    ///
    /// The candidate itself has two shapes. With no `knownBad` the search has no
    /// upper bound and reaches `jumpPercentage` above the threshold, capped at
    /// `maximumThreshold`. With a `knownBad` it becomes a binary search
    /// downward — the midpoint between what is known to work and what is known
    /// to fail — which converges on the real ceiling and then stops on its own:
    /// once the midpoint rounds down to the threshold itself there is nothing
    /// strictly above it left to ask for, and no probe is offered again until a
    /// success clears the bad point.
    public static func nextLimit(
        state: ResponseLimitState,
        settings: ResponseLimitSettings
    ) -> ResponseLimitDecision {
        let bounds = Bounds(settings)
        let threshold = state.threshold

        let candidate: Int
        if let knownBad = state.knownBad {
            candidate = saturatingAdd(threshold, saturatingSubtract(knownBad, threshold) / 2)
        } else {
            let base = saturatingAdd(threshold, scaled(threshold, by: bounds.jump, over: 100))
            candidate = min(base, bounds.maximum)
        }

        let hasSomewhereToGo = candidate > threshold
        let cadenceDue = saturatingIncrement(state.promptsSinceProbe) >= bounds.cadence

        if hasSomewhereToGo, cadenceDue {
            var next = state
            next.promptsSinceProbe = 0
            return ResponseLimitDecision(
                limit: clamp(candidate, bounds),
                isProbe: true,
                state: next
            )
        }

        var next = state
        next.promptsSinceProbe = saturatingIncrement(state.promptsSinceProbe)
        return ResponseLimitDecision(
            limit: clamp(threshold, bounds),
            isProbe: false,
            state: next
        )
    }

    // MARK: Learning from an outcome

    /// Folds one turn's outcome into the alias' state.
    ///
    /// The case that makes this subtle is a *short successful answer*. A model
    /// asked for 800 characters that replies in 200 has told us nothing about
    /// whether 800 would have survived the gateway — the answer never got near
    /// the ceiling. Treating that as a success that confirms the ceiling would
    /// ratchet the threshold up on evidence that does not exist; treating it as
    /// a failure would ratchet it down on the same non-evidence. It is
    /// inconclusive, and the only thing it settles is that the turn completed,
    /// so the consecutive-failure counter resets and nothing else moves.
    ///
    /// A failure on an ordinary (non-probe) prompt is likewise not immediately
    /// conclusive: gateways time out for reasons that have nothing to do with
    /// length. The second one in a row is treated as the ceiling having moved
    /// underneath us, and the threshold backs off 10% — but never below
    /// `minimumThreshold`, because a limit small enough to be useless is
    /// indistinguishable to the user from a broken model.
    public static func record(
        _ outcome: ResponseLimitOutcome,
        state: ResponseLimitState,
        settings: ResponseLimitSettings
    ) -> ResponseLimitState {
        let bounds = Bounds(settings)
        var next = state

        if outcome.succeeded {
            next.maxObservedSuccess = max(state.maxObservedSuccess, outcome.responseCharacters)
            next.consecutiveFailures = 0
            // Only an answer that actually reached the ceiling is evidence about
            // where the ceiling is.
            if outcome.responseCharacters >= state.threshold, outcome.wasProbe {
                next.threshold = outcome.offeredLimit
                // The probe succeeded at or above the point previously recorded
                // as bad, so that record is stale — a gateway setting changed,
                // or the failure was never about length. Dropping it re-opens
                // the upward search instead of leaving a binary search bounded
                // by a bound that has been disproved.
                if let knownBad = next.knownBad, knownBad <= next.threshold {
                    next.knownBad = nil
                }
            }
        } else {
            next.consecutiveFailures = saturatingIncrement(state.consecutiveFailures)
            if outcome.wasProbe {
                // We asked for more than we knew worked and did not get it.
                // That is exactly what a probe is for; the threshold itself is
                // untouched because it is still the last thing known to work.
                next.knownBad = min(state.knownBad ?? Int.max, outcome.offeredLimit)
            } else if next.consecutiveFailures >= 2 {
                next.knownBad = min(state.knownBad ?? Int.max, state.threshold)
                next.threshold = max(bounds.minimum, scaled(state.threshold, by: 9, over: 10))
                next.consecutiveFailures = 0
            }
        }

        next.threshold = clamp(next.threshold, bounds)
        return next
    }

    // MARK: Rendering the sentence

    /// The template with `{limit}` replaced by the decimal limit.
    ///
    /// A template carrying no token is returned unchanged and still appended:
    /// the sentence is the instruction, and a user who wrote "Keep it short."
    /// meant that instruction on every prompt. Silently dropping it — or
    /// silently bolting a parenthesised character count onto the end of prose
    /// the user wrote deliberately — would both be worse than honouring it
    /// literally.
    public static func limitSentence(limit: Int, template: String) -> String {
        template.replacingOccurrences(of: limitToken, with: "\(limit)")
    }

    /// `text` with the limit sentence appended, replacing one that is already
    /// there.
    ///
    /// The replacement is what makes this safe to apply twice. A prompt restored
    /// from history — or resubmitted after an edit, or replayed out of the
    /// session file — arrives with last turn's sentence already on the end, and
    /// appending a second one would leave the model two limits to choose
    /// between and the transcript a growing tail of them.
    ///
    /// Recognition is a literal scan against the template with `{limit}` matched
    /// as one-or-more ASCII digits, so a *different* limit from a previous turn
    /// is still recognised. It compares only the last non-blank line, which is
    /// the only place this function ever writes one.
    ///
    /// Whitespace-only input yields the sentence alone rather than two blank
    /// lines followed by it: an image-only prompt is a real case, and a stored
    /// user message that opens with an empty line reads as a rendering bug in
    /// every transcript surface that shows it.
    public static func decorated(_ text: String, limit: Int, template: String) -> String {
        let sentence = limitSentence(limit: limit, template: template)
        let body = strippingLimitSentence(from: text, template: template)
        guard !body.isEmpty else { return sentence }
        return body + "\n\n" + sentence
    }

    /// `text` without a trailing rendered limit sentence, and without the blank
    /// lines that separated it.
    static func strippingLimitSentence(from text: String, template: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        dropTrailingBlanks(&lines)
        if let last = lines.last, matchesLimitSentence(last, template: template) {
            lines.removeLast()
            dropTrailingBlanks(&lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func dropTrailingBlanks(_ lines: inout [String]) {
        while let last = lines.last,
            last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            lines.removeLast()
        }
    }

    /// Whether `line` is this template rendered with some limit.
    ///
    /// Hand-rolled rather than a regular expression, and not only because
    /// building one per prompt would be wasteful: the template is user-supplied,
    /// so escaping it into a pattern is a correctness problem with a silent
    /// failure mode — an unescaped `.` or `(` turns the idempotence check into
    /// something that matches text it should not, and the prompt loses a line
    /// the user wrote.
    ///
    /// The scan splits the template on the token and requires the literal
    /// segments in order with at least one ASCII digit between each pair. A
    /// template whose literal segment begins with a digit would confuse the
    /// greedy digit run; nothing sane writes one, and the cost of being wrong is
    /// that a limit line is not recognised and the prompt keeps one extra line.
    static func matchesLimitSentence(_ line: String, template: String) -> Bool {
        let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        let segments = template.components(separatedBy: limitToken)
        guard segments.count > 1 else {
            return candidate == template.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var rest = candidate[...]
        guard rest.hasPrefix(segments[0]) else { return false }
        rest = rest.dropFirst(segments[0].count)
        for segment in segments.dropFirst() {
            var digits = 0
            while let first = rest.first, ("0"..."9").contains(first) {
                rest = rest.dropFirst()
                digits += 1
            }
            guard digits > 0 else { return false }
            guard rest.hasPrefix(segment) else { return false }
            rest = rest.dropFirst(segment.count)
        }
        return rest.isEmpty
    }

    // MARK: Arithmetic that cannot trap

    private static func clamp(_ value: Int, _ bounds: Bounds) -> Int {
        min(max(value, bounds.minimum), bounds.maximum)
    }

    /// `value * numerator / denominator`, saturating instead of trapping.
    ///
    /// The retry when the multiplication overflows divides first, which costs a
    /// little precision and cannot overflow for any `numerator <= denominator`.
    /// For a `numerator` larger than the denominator — a percentage jump in the
    /// millions — even that can overflow, and the saturated result is then
    /// clamped down to `maximumThreshold` by the caller anyway.
    private static func scaled(_ value: Int, by numerator: Int, over denominator: Int) -> Int {
        guard denominator != 0 else { return 0 }
        let (product, productOverflowed) = value.multipliedReportingOverflow(by: numerator)
        if !productOverflowed { return product / denominator }
        let (retry, retryOverflowed) = (value / denominator).multipliedReportingOverflow(by: numerator)
        if !retryOverflowed { return retry }
        return value < 0 ? Int.min : Int.max
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        guard overflowed else { return sum }
        return rhs > 0 ? Int.max : Int.min
    }

    private static func saturatingSubtract(_ lhs: Int, _ rhs: Int) -> Int {
        let (difference, overflowed) = lhs.subtractingReportingOverflow(rhs)
        guard overflowed else { return difference }
        return rhs < 0 ? Int.max : Int.min
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        saturatingAdd(value, 1)
    }
}

// MARK: - Persistence

/// Where learned thresholds live between runs.
///
/// Neither method throws and neither is `async`. That is a deliberate narrowing:
/// this state is an optimisation, and the one thing it must never do is take a
/// turn down with it. A store that cannot read returns an empty document — the
/// harness then re-learns from the seed threshold, which costs a few probes and
/// nothing else. A store that cannot write says nothing.
///
/// ``save(_:)`` **merges**: the given document's entries replace the stored
/// entries for the same aliases, and every alias it does not mention is left
/// alone. Replacement would be the obvious spelling and the wrong one — a second
/// `domo` process working on a different model would have its learning erased by
/// whichever process saved last, using a document it read before that learning
/// existed. There is no delete, so nothing needs replacement semantics.
public protocol ResponseLimitStoring: Sendable {
    /// The stored document, or an empty one for anything unreadable, corrupt, or
    /// written by a version this build does not understand.
    func load() -> ResponseLimitDocument
    /// Merges `document`'s aliases into storage. Best effort; failures are
    /// silent.
    func save(_ document: ResponseLimitDocument)
}

/// A ``ResponseLimitStoring`` backed by one JSON file, mode 0600.
///
/// The file is a record of how the user's gateway behaves, which is closer to a
/// deployment detail than to a secret — but it is keyed by model alias, so it
/// names which models this machine talks to, and 0600 costs nothing.
public struct FileResponseLimitStore: ResponseLimitStoring, Sendable {
    /// The document. Its sidecar `.<name>.lock` guards the read-modify-write.
    public let path: FilePath

    public init(path: FilePath) {
        self.path = path
    }

    public func load() -> ResponseLimitDocument {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path.string)) else {
            // Absent is the ordinary first-run case, not a fault.
            return ResponseLimitDocument()
        }
        guard let document = try? JSONDecoder().decode(ResponseLimitDocument.self, from: data),
            document.version == ResponseLimitDocument.currentVersion
        else {
            // Truncated by a killed writer, hand-edited into invalidity, or
            // written by a future build. All three mean the same thing here:
            // learn it again. Throwing would push a decision about a cache file
            // up into the middle of a turn.
            return ResponseLimitDocument()
        }
        return document
    }

    public func save(_ document: ResponseLimitDocument) {
        let lock = FilePath(FileLock.lockPath(forDocumentAt: path.string))
        let lockDirectory = lock.removingLastComponent().string
        if !lockDirectory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: lockDirectory,
                withIntermediateDirectories: true
            )
        }
        // A sidecar, never the document: `O_CREAT` on the document itself would
        // leave a 0-byte JSON file behind whenever the save that followed did
        // not happen, and `load()` would then quietly report "nothing learned"
        // forever without anything looking wrong.
        guard
            let descriptor = try? FileDescriptor.open(
                lock,
                .writeOnly,
                options: [.create],
                permissions: .ownerReadWrite
            )
        else { return }
        defer { try? descriptor.close() }
        guard Self.acquire(descriptor.rawValue) else { return }
        // Redundant with the close above — `close(2)` drops an `flock` — but
        // stated rather than left as an inference about `defer` ordering.
        defer { _ = flock(descriptor.rawValue, LOCK_UN) }

        var merged = load()
        for (model, state) in document.models {
            merged.models[model] = state
        }
        merged.version = ResponseLimitDocument.currentVersion

        let encoder = JSONEncoder()
        // Sorted keys so two saves of the same content produce the same bytes
        // and the file is reviewable in a diff, matching the trust store.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(merged) else { return }
        // `AtomicFileWrite` rather than `Data.write(options: .atomic)`: the
        // latter re-creates the file at 0644 under the usual umask on every
        // save and replaces a symlink with a regular file.
        try? AtomicFileWrite.replace(
            at: path.string,
            with: String(decoding: data, as: UTF8.self),
            createPermissions: .ownerReadWrite
        )
    }

    /// How long to keep trying for the lock before dropping the save.
    ///
    /// Deliberately short. ``FileLock/withLock(at:timeout:_:)`` waits two
    /// seconds and suspends between attempts, which is right for a settings
    /// write that must not be lost; this one blocks the caller's thread —
    /// ``ResponseLimitStoring`` is synchronous by design, so there is no
    /// suspension available — and what is at stake is one turn's worth of
    /// learning that the next turn will re-derive. Waiting longer would trade
    /// something valuable for something disposable.
    private static let lockTimeout: Duration = .milliseconds(200)

    /// Polls `LOCK_EX|LOCK_NB` until it succeeds or ``lockTimeout`` elapses.
    ///
    /// Never a blocking `LOCK_EX`: a peer that took the lock and then stopped —
    /// suspended, under a debugger — would hang the turn with no way out. This
    /// is ``FileLock`` open-coded for the same reason `TrustStore` open-codes
    /// it, that the caller is synchronous; the deadline is on `ContinuousClock`
    /// so an NTP step cannot extend or truncate the wait.
    private static func acquire(_ descriptor: CInt) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: lockTimeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            if clock.now >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

/// A ``ResponseLimitStoring`` that keeps the document in memory.
///
/// For tests and for any host that would rather not leave a file behind. The
/// `@unchecked` is not hiding anything — the document lives in a `Mutex` — it is
/// there because a class is never implicitly `Sendable`.
public final class InMemoryResponseLimitStore: ResponseLimitStoring, @unchecked Sendable {
    private let storage: Mutex<ResponseLimitDocument>

    public init(_ document: ResponseLimitDocument = ResponseLimitDocument()) {
        self.storage = Mutex(document)
    }

    public func load() -> ResponseLimitDocument {
        storage.withLock { $0 }
    }

    public func save(_ document: ResponseLimitDocument) {
        storage.withLock { stored in
            for (model, state) in document.models {
                stored.models[model] = state
            }
            stored.version = ResponseLimitDocument.currentVersion
        }
    }
}

// MARK: - Controller

/// The seam a harness talks to: hand it a prompt, get back the prompt to send
/// and a ticket to report the outcome against.
///
/// An actor because one process has one gateway. The CLI builds a single
/// controller and passes it to every harness it constructs, including subagent
/// children, so a probe answered by one turn is known to the next turn wherever
/// it runs — and so two concurrent turns cannot each read the same state, each
/// decide it is their turn to probe, and each write the other's cadence away.
public actor ResponseLimitController {
    private let configuredSettings: ResponseLimitSettings
    private let store: any ResponseLimitStoring

    public init(settings: ResponseLimitSettings, store: any ResponseLimitStoring) {
        self.configuredSettings = settings
        self.store = store
    }

    /// The settings this controller was built with.
    public var settings: ResponseLimitSettings { configuredSettings }

    /// What a decorated prompt is owed back once its turn settles.
    ///
    /// It carries the offered limit rather than a reference to the state, so a
    /// turn that takes minutes — and finishes after some other turn has already
    /// moved the threshold — still reports on the number it actually asked for.
    public struct Ticket: Sendable, Hashable {
        public var model: String
        public var limit: Int
        public var isProbe: Bool

        public init(model: String, limit: Int, isProbe: Bool) {
            self.model = model
            self.limit = limit
            self.isProbe = isProbe
        }
    }

    /// The text to send *and store*, plus the ticket to hand back to
    /// ``record(_:succeeded:responseCharacters:)``.
    ///
    /// The limit sentence is part of the stored user message on purpose: the
    /// transcript, the session file and every export then show exactly what the
    /// model was asked, and a resubmitted prompt carries the same instruction
    /// the original did. ``ResponseLimitPolicy/decorated(_:limit:template:)``
    /// makes that safe by replacing an existing sentence rather than stacking a
    /// second one.
    ///
    /// A disabled controller returns the text untouched and a nil ticket, so a
    /// caller needs no second `enabled` check of its own.
    public func decorate(_ text: String, model: String) -> (text: String, ticket: Ticket?) {
        guard configuredSettings.enabled else { return (text, nil) }

        let stored =
            store.load().models[model]
            ?? ResponseLimitState(threshold: configuredSettings.thresholdCharacters)
        let decision = ResponseLimitPolicy.nextLimit(state: stored, settings: configuredSettings)

        // Persisted before the turn runs, not after: the cadence counter has to
        // survive a crash mid-turn, or a process that dies during every probe
        // would probe on every single prompt forever.
        //
        // Only this alias is handed to the store. Writing back the whole loaded
        // document would carry every *other* alias' state as it stood at load
        // time, and a peer that learned something in between would have that
        // learning reverted by a save that never meant to touch it.
        store.save(ResponseLimitDocument(models: [model: decision.state]))

        let decorated = ResponseLimitPolicy.decorated(
            text,
            limit: decision.limit,
            template: configuredSettings.template
        )
        return (
            decorated,
            Ticket(model: model, limit: decision.limit, isProbe: decision.isProbe)
        )
    }

    /// Folds one settled turn into the alias' learned state.
    ///
    /// Callers must not call this for a cancelled turn: a user pressing escape
    /// says nothing about the gateway's ceiling, and recording it as a failure
    /// would walk the threshold down for a reason that has nothing to do with
    /// length.
    public func record(_ ticket: Ticket, succeeded: Bool, responseCharacters: Int) {
        guard configuredSettings.enabled else { return }

        let stored =
            store.load().models[ticket.model]
            ?? ResponseLimitState(threshold: configuredSettings.thresholdCharacters)
        let outcome = ResponseLimitOutcome(
            offeredLimit: ticket.limit,
            wasProbe: ticket.isProbe,
            succeeded: succeeded,
            responseCharacters: responseCharacters
        )
        let learned = ResponseLimitPolicy.record(
            outcome,
            state: stored,
            settings: configuredSettings
        )
        store.save(ResponseLimitDocument(models: [ticket.model: learned]))
    }

    /// The alias' current known-good ceiling, or the seed for one never seen.
    ///
    /// An inspection seam. It reports the stored threshold unclamped, which is
    /// what "what has been learned" means; the clamping happens where a limit is
    /// chosen.
    public func currentThreshold(model: String) -> Int {
        let state =
            store.load().models[model]
            ?? ResponseLimitState(threshold: configuredSettings.thresholdCharacters)
        return state.threshold
    }
}
