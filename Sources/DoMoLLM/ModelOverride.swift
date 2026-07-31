// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Strict numeric text

/// The one place in this module a `Decimal` is recovered from text.
///
/// Strict on purpose, because `Decimal(string:)` alone is a quiet liar in two
/// ways this project has to care about. It *prefix*-parses, so `"1.5x"` comes
/// back as `1.5` and a duplicated HTTP header — which `HTTPField` subscripting
/// comma-joins into `"0.001, 0.001"` — comes back as `0.001`, a plausible number
/// that nobody sent. And it is locale-influenced, so the same settings file read
/// on a Linux box running under a comma-decimal locale would turn `"3.5"` into
/// something else entirely. Requiring the whole string to match a fixed grammar,
/// and parsing under `en_US_POSIX`, removes both.
enum DecimalText {
    /// A locale that cannot be reconfigured out from under a price.
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Parses `raw` only if all of it — after trimming surrounding whitespace —
    /// is `[+-]? digits ( '.' digits )? ( [eE] [+-]? digits )?`.
    ///
    /// Deliberately narrower than `Decimal`'s own grammar: no bare `.5`, no
    /// trailing `5.`, no thousands separators, no `NaN` or `Infinity`. The
    /// exponent form is not optional-in-practice — LiteLLM stringifies a Python
    /// float, so `1e-05` is what a small per-request cost actually looks like on
    /// the wire, and rejecting it would throw away the very values this exists
    /// to read.
    ///
    /// Returns `nil` on overflow too: `Decimal(string:)` answers `nil` rather
    /// than a saturated value for `1e1000`, and a saturated price is worse than
    /// no price.
    static func strict(_ raw: String) -> Decimal? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCanonicalNumber(text) else { return nil }
        return Decimal(string: text, locale: posix)
    }

    private static func isCanonicalNumber(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0

        func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
        func consumeSign() {
            guard offset < bytes.count else { return }
            if bytes[offset] == UInt8(ascii: "+") || bytes[offset] == UInt8(ascii: "-") { offset += 1 }
        }
        func consumeDigits() -> Bool {
            let start = offset
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
            return offset > start
        }

        consumeSign()
        guard consumeDigits() else { return false }

        if offset < bytes.count, bytes[offset] == UInt8(ascii: ".") {
            offset += 1
            guard consumeDigits() else { return false }
        }
        if offset < bytes.count, bytes[offset] == UInt8(ascii: "e") || bytes[offset] == UInt8(ascii: "E") {
            offset += 1
            consumeSign()
            guard consumeDigits() else { return false }
        }
        return offset == bytes.count
    }
}

// MARK: - Per-model overrides

/// What the user knows about one model alias that the gateway will not say.
///
/// LiteLLM's `/models` answers with alias names and nothing else: no context
/// window, no prices. Everything here is therefore operator-supplied truth, and
/// every field is optional because "I did not say" and "I said zero" are
/// different claims. A `nil` ``contextWindow`` means genuinely unknown, and a
/// meter shows `?` rather than a percentage of a guess; `nil` ``rates`` leaves
/// cost at zero, which is the honest answer for a model whose price nobody
/// stated.
public struct ModelOverride: Sendable, Hashable, Codable {
    /// Total tokens the model accepts, prompt plus completion.
    public var contextWindow: Int?

    /// USD-per-million prices, including any request-wide volume tiers.
    public var rates: ModelCostRates?

    /// A per-alias `reasoning_effort`, which outranks any global setting because
    /// it is the more specific statement about this model.
    public var reasoningEffort: ReasoningEffort?

    public init(
        contextWindow: Int? = nil,
        rates: ModelCostRates? = nil,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.contextWindow = contextWindow
        self.rates = rates
        self.reasoningEffort = reasoningEffort
    }
}

// MARK: ModelOverride Codable

private enum OverrideKeys: String, CodingKey {
    case contextWindow
    case rates
    case reasoningEffort
}

/// The rate names, used at two depths: hoisted to the top level in the flat
/// authoring shape, and inside `rates.base` / `rates.tiers[].rates` in the
/// nested one.
private enum RateKeys: String, CodingKey {
    case input
    case output
    case cacheRead
    case cacheWrite
}

private enum NestedRateKeys: String, CodingKey {
    case base
    case tiers
}

private enum TierKeys: String, CodingKey {
    case inputTokensAbove
    case rates
}

/// The flat shape's tier list, read from its own container so the flat and the
/// nested spelling never have to share a key enum.
private enum FlatTierKeys: String, CodingKey {
    case tiers
}

/// Reads one price, accepting a JSON number *or* a JSON string.
///
/// The string spelling is not decoration. A price authored as a bare JSON number
/// reaches `Decimal` through whatever the active `JSONDecoder` does with it, and
/// a decoder that routes through `Double` turns `3.00003` into
/// `3.000030000000000512` — a number that then accumulates across every turn of
/// a session. Quoting the price makes the exact digits the author typed the
/// digits that are stored, with no dependency on a decoder detail no reader can
/// see.
private func decodeRate(_ container: KeyedDecodingContainer<RateKeys>, _ key: RateKeys) throws -> Decimal? {
    guard container.contains(key) else { return nil }
    if try container.decodeNil(forKey: key) { return nil }

    let value: Decimal
    if let text = try? container.decode(String.self, forKey: key) {
        guard let parsed = DecimalText.strict(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) is not a number: \"\(text)\""
            )
        }
        value = parsed
    } else {
        value = try container.decode(Decimal.self, forKey: key)
    }

    // A negative price is never a typo worth honoring: it makes a session's
    // running total fall as it burns money, which is the exact failure this
    // phase exists to stop.
    guard value >= 0 else {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "\(key.stringValue) must not be negative; got \(value)"
        )
    }
    return value
}

/// Builds a ``TokenRates`` from whichever of the four prices were stated, or
/// `nil` when none were — so an override that only sets `contextWindow` does not
/// silently claim the model is free.
private func decodeTokenRates(_ container: KeyedDecodingContainer<RateKeys>) throws -> TokenRates? {
    let input = try decodeRate(container, .input)
    let output = try decodeRate(container, .output)
    let cacheRead = try decodeRate(container, .cacheRead)
    let cacheWrite = try decodeRate(container, .cacheWrite)
    guard input != nil || output != nil || cacheRead != nil || cacheWrite != nil else { return nil }
    return TokenRates(
        input: input ?? 0,
        output: output ?? 0,
        cacheRead: cacheRead ?? 0,
        cacheWrite: cacheWrite ?? 0
    )
}

private struct TierShape: Decodable {
    let tier: ModelCostRates.Tier

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TierKeys.self)
        let threshold = try container.decode(Int.self, forKey: .inputTokensAbove)
        let rateContainer = try container.nestedContainer(keyedBy: RateKeys.self, forKey: .rates)
        tier = ModelCostRates.Tier(
            inputTokensAbove: threshold,
            rates: try decodeTokenRates(rateContainer) ?? .free
        )
    }
}

extension ModelOverride {
    /// Hand-written because there are two spellings a human plausibly writes and
    /// both have to work.
    ///
    /// The flat one puts the four prices at the top level next to
    /// `contextWindow`, which is what anyone converting a price table by hand
    /// reaches for. The nested one mirrors ``ModelCostRates`` exactly, which is
    /// what this type *emits*, so a settings file that was written back out
    /// keeps decoding. Encoding always produces the nested form: one shape on
    /// disk, and no question about which spelling round-tripped.
    ///
    /// Writing both at once throws rather than picking a winner. Silently
    /// ignoring half of a stated price table is precisely the kind of quiet
    /// wrongness a cost display cannot afford.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OverrideKeys.self)

        let window = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        if let window, window <= 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .contextWindow,
                in: container,
                debugDescription: "contextWindow must be greater than zero; got \(window)"
            )
        }

        // The flat shape is read off sibling containers over the same object.
        // Resolved eagerly and by VALUE rather than by key presence, so an
        // explicit `"input": null` counts as "unstated" exactly the way a
        // missing key does — otherwise a null would quietly produce a free
        // model instead of an unpriced one.
        let flatRates = try decoder.container(keyedBy: RateKeys.self)
        let flatTiers = try decoder.container(keyedBy: FlatTierKeys.self)
        let flatBase = try decodeTokenRates(flatRates)
        let flatTierList = try flatTiers.decodeIfPresent([TierShape].self, forKey: .tiers)
        let hasFlat = flatBase != nil || flatTierList != nil

        // Likewise `"rates": null`.
        let hasNested = try container.contains(.rates) && !container.decodeNil(forKey: .rates)

        let resolved: ModelCostRates?
        if hasNested {
            guard !hasFlat else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rates,
                    in: container,
                    debugDescription:
                        "Model override states prices both under \"rates\" and at the top level; use one or the other"
                )
            }
            let nested = try container.nestedContainer(keyedBy: NestedRateKeys.self, forKey: .rates)
            let base: TokenRates
            if nested.contains(.base) {
                base = try decodeTokenRates(nested.nestedContainer(keyedBy: RateKeys.self, forKey: .base)) ?? .free
            } else {
                base = .free
            }
            let tiers = try nested.decodeIfPresent([TierShape].self, forKey: .tiers) ?? []
            resolved = ModelCostRates(base: base, tiers: tiers.map(\.tier))
        } else if hasFlat {
            resolved = ModelCostRates(base: flatBase ?? .free, tiers: (flatTierList ?? []).map(\.tier))
        } else {
            resolved = nil
        }

        self.init(
            contextWindow: window,
            rates: resolved,
            reasoningEffort: try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: OverrideKeys.self)
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encodeIfPresent(rates, forKey: .rates)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    }
}
