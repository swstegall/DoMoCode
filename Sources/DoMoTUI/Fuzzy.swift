// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/fuzzy.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. The subsequence scoring —
// consecutive-run reward, gap penalty, word-boundary bonus, later-match penalty,
// exact-match bonus, and the letters/digits swap fallback — is ported verbatim.
// One deliberate addition over pi: the match records the grapheme indices it
// consumed so a caller can highlight them, which pi never needed. See ``FuzzyMatch``.

// MARK: - Match result

/// The outcome of matching one query against one candidate string.
///
/// pi returns only `{ matches, score }`; the harness needs to *underline* the
/// characters that matched in a completion popup, so ``positions`` records which
/// grapheme indices of the candidate were consumed. Positions are indices into
/// the candidate's `Character` view — never UTF-16 offsets — because a Swift
/// `Character` is a whole grapheme cluster and the editor addresses text the same
/// way; this keeps highlight math from ever splitting an emoji or a combined
/// glyph. `score` is a `Double` because pi's later-match term (`i * 0.1`) is
/// fractional; **lower is a better match**, matching pi's convention.
public nonisolated struct FuzzyMatch: Sendable, Equatable {
    public var matches: Bool
    public var score: Double
    /// Grapheme indices in the candidate consumed by the query, ascending and
    /// de-duplicated. Empty for an empty query or a non-match.
    public var positions: [Int]

    public init(matches: Bool, score: Double, positions: [Int] = []) {
        self.matches = matches
        self.score = score
        self.positions = positions
    }
}

// MARK: - Single match

/// Match if every character of `query` appears in `text` in order (not
/// necessarily contiguously), scoring the quality of that subsequence.
///
/// The score rewards contiguous runs and word-boundary hits and penalizes gaps
/// and late matches, so `"foo"` scores a leading contiguous `"foobar"` far below
/// (better than) a scattered `"flavor of oregano"`. When the primary pass fails,
/// pi retries once with the query's letter and digit halves swapped (so `"2fa"`
/// can find `"fa2"`); that fallback is preserved and its score carries pi's `+5`
/// penalty so a swapped hit ranks below a direct one.
///
/// Pure and `nonisolated`: it touches no actor state and is safe to call while
/// ranking a large candidate list off the main actor.
public nonisolated func fuzzyMatch(_ query: String, _ text: String) -> FuzzyMatch {
    let queryLower = Array(query.lowercased())
    let textLower = Array(text.lowercased())

    let primary = matchSubsequence(query: queryLower, text: textLower)
    if primary.matches {
        return primary
    }

    guard let swapped = swappedAlphaNumericQuery(queryLower) else {
        return primary
    }
    let swappedMatch = matchSubsequence(query: swapped, text: textLower)
    guard swappedMatch.matches else {
        return primary
    }
    // pi adds 5 so a swapped hit always sorts after an equivalent direct hit.
    return FuzzyMatch(matches: true, score: swappedMatch.score + 5, positions: swappedMatch.positions)
}

/// The core subsequence walk, operating on already-lowercased grapheme arrays.
///
/// Kept separate so the letters/digits fallback can reuse it with a rewritten
/// query without re-lowercasing the (unchanged) candidate.
private nonisolated func matchSubsequence(query: [Character], text: [Character]) -> FuzzyMatch {
    if query.isEmpty {
        return FuzzyMatch(matches: true, score: 0)
    }
    if query.count > text.count {
        return FuzzyMatch(matches: false, score: 0)
    }

    var queryIndex = 0
    var score = 0.0
    var lastMatchIndex = -1
    var consecutiveMatches = 0
    var positions: [Int] = []

    var i = 0
    while i < text.count, queryIndex < query.count {
        if text[i] == query[queryIndex] {
            let isWordBoundary = i == 0 || isBoundaryCharacter(text[i - 1])

            // Reward a contiguous run; otherwise penalize the gap just crossed.
            if lastMatchIndex == i - 1 {
                consecutiveMatches += 1
                score -= Double(consecutiveMatches) * 5
            } else {
                consecutiveMatches = 0
                if lastMatchIndex >= 0 {
                    score += Double(i - lastMatchIndex - 1) * 2
                }
            }

            if isWordBoundary {
                score -= 10
            }

            // Slight penalty for matches deeper into the candidate.
            score += Double(i) * 0.1

            positions.append(i)
            lastMatchIndex = i
            queryIndex += 1
        }
        i += 1
    }

    if queryIndex < query.count {
        return FuzzyMatch(matches: false, score: 0)
    }

    // Exact whole-string equality is the strongest signal pi has.
    if query == text {
        score -= 100
    }

    return FuzzyMatch(matches: true, score: score, positions: positions)
}

/// True for pi's word-boundary set — whitespace, `-`, `_`, `.`, `/`, `:` — so a
/// match right after one earns the boundary bonus.
private nonisolated func isBoundaryCharacter(_ character: Character) -> Bool {
    switch character {
    case " ", "\t", "\n", "\r", "-", "_", ".", "/", ":":
        return true
    default:
        return false
    }
}

/// pi's `letters+digits` ⇄ `digits+letters` fallback query, or `nil` when the
/// query is not a clean alpha/numeric split. Input is already lowercased.
private nonisolated func swappedAlphaNumericQuery(_ query: [Character]) -> [Character]? {
    guard !query.isEmpty else { return nil }

    func isLetter(_ character: Character) -> Bool { character >= "a" && character <= "z" }
    func isDigit(_ character: Character) -> Bool { character >= "0" && character <= "9" }

    // ^[a-z]+[0-9]+$  ->  digits + letters
    if isLetter(query[0]) {
        var split = 0
        while split < query.count, isLetter(query[split]) { split += 1 }
        if split > 0, split < query.count, query[split...].allSatisfy(isDigit) {
            return Array(query[split...]) + Array(query[..<split])
        }
        return nil
    }

    // ^[0-9]+[a-z]+$  ->  letters + digits
    if isDigit(query[0]) {
        var split = 0
        while split < query.count, isDigit(query[split]) { split += 1 }
        if split > 0, split < query.count, query[split...].allSatisfy(isLetter) {
            return Array(query[split...]) + Array(query[..<split])
        }
        return nil
    }

    return nil
}

// MARK: - Ranked filter

/// One survivor of ``fuzzyFilter(_:query:getText:)``: the item, its summed score
/// across all query tokens (lower is better), and the grapheme positions matched
/// by the *first* token, for highlighting.
public nonisolated struct FuzzyFilterResult<Item>: Sendable where Item: Sendable {
    public var item: Item
    public var score: Double
    public var positions: [Int]

    public init(item: Item, score: Double, positions: [Int]) {
        self.item = item
        self.score = score
        self.positions = positions
    }
}

/// Filter `items` to those matching every whitespace/slash-separated token of
/// `query`, best (lowest total score) first.
///
/// A blank query keeps every item in input order. Otherwise the query is split
/// on runs of whitespace and `/`, and an item survives only if *all* tokens fuzzy-
/// match its text; the per-token scores are summed. Ties keep input order — the
/// sort is Swift's guaranteed-stable `sorted(by:)` with a strict comparator — so
/// the rank is deterministic, which pi's `Array.sort` only accidentally is.
public nonisolated func fuzzyFilter<Item>(
    _ items: [Item],
    query: String,
    getText: (Item) -> String
) -> [FuzzyFilterResult<Item>] where Item: Sendable {
    let tokens = query
        .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "/" })
        .map(String.init)
        .filter { !$0.isEmpty }

    if tokens.isEmpty {
        return items.map { FuzzyFilterResult(item: $0, score: 0, positions: []) }
    }

    var results: [FuzzyFilterResult<Item>] = []
    for item in items {
        let text = getText(item)
        var totalScore = 0.0
        var firstPositions: [Int] = []
        var allMatch = true

        for (index, token) in tokens.enumerated() {
            let match = fuzzyMatch(token, text)
            if match.matches {
                totalScore += match.score
                if index == 0 { firstPositions = match.positions }
            } else {
                allMatch = false
                break
            }
        }

        if allMatch {
            results.append(FuzzyFilterResult(item: item, score: totalScore, positions: firstPositions))
        }
    }

    // Stable: equal scores retain their relative input order.
    return results.sorted { $0.score < $1.score }
}
