// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation

// MARK: - Entries

/// One model alias as the proxy advertises it on `GET /models`.
///
/// Decoded leniently: `id` is the only field a caller needs, and `owned_by` is
/// deliberately *not* a provider discriminator — LiteLLM hardcodes it to
/// `"openai"` for every model regardless of the true upstream, so branching on it
/// would be branching on a constant.
public struct ModelEntry: Sendable, Hashable, Codable {
    public var id: String
    public var object: String?
    public var created: Int?
    public var ownedBy: String?

    public init(id: String, object: String? = nil, created: Int? = nil, ownedBy: String? = nil) {
        self.id = id
        self.object = object
        self.created = created
        self.ownedBy = ownedBy
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        created = try container.decodeIfPresent(Int.self, forKey: .created)
        ownedBy = try container.decodeIfPresent(String.self, forKey: .ownedBy)
    }
}

/// The `GET /models` envelope. `data` is the only field that matters.
struct ModelListResponse: Sendable, Codable {
    var data: [ModelEntry]

    enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A single malformed entry must not blank the whole catalog: the list is
        // advisory, so undecodable rows are dropped rather than fatal.
        let lenient = try container.decodeIfPresent([FailableEntry].self, forKey: .data) ?? []
        data = lenient.compactMap(\.value)
    }

    /// Decodes to `nil` instead of throwing, so one bad row does not sink the array.
    private struct FailableEntry: Decodable {
        let value: ModelEntry?
        init(from decoder: any Decoder) throws {
            value = try? ModelEntry(from: decoder)
        }
    }
}

// MARK: - Catalog

/// The proxy's advertised model aliases.
///
/// The list is treated as advisory, never authoritative. A LiteLLM deployment
/// with wildcard model configs answers `GET /models` with a *non-exhaustive*
/// list — the wildcards do not enumerate — so a model id absent from ``models``
/// is not a model the proxy will reject. ``permits(_:)`` therefore always returns
/// true, and ``contains(_:)`` answers the narrower question of whether the proxy
/// named the model explicitly, which is all a completion list should promise.
public struct ModelCatalog: Sendable, Hashable {
    public let models: [ModelEntry]

    public init(models: [ModelEntry]) {
        self.models = models
    }

    public var ids: [String] { models.map(\.id) }

    /// Whether the proxy explicitly advertised this id. Useful for suggestions;
    /// never a gate, because the list may be incomplete.
    public func contains(_ id: String) -> Bool {
        models.contains { $0.id == id }
    }

    /// Always true. A free-typed model id is always allowed to reach the proxy,
    /// which is the only component that can actually decide whether it resolves.
    public func permits(_ id: String) -> Bool { true }
}

// MARK: - Pricing catalog

/// Pricing metadata returned by LiteLLM's `GET /model/info` endpoint.
///
/// LiteLLM calls these rows "model info" even though the useful portion for a
/// client is a price table. The gateway may omit a row, omit individual prices,
/// or add provider-specific fields; an absent rate therefore remains `nil` and
/// is rendered as unknown by the session meter rather than being mistaken for a
/// free model.
public struct ModelPricingEntry: Sendable, Hashable, Codable {
    public var modelName: String
    public var rates: ModelCostRates?
    public var contextWindow: Int?

    public init(modelName: String, rates: ModelCostRates? = nil, contextWindow: Int? = nil) {
        self.modelName = modelName
        self.rates = rates
        self.contextWindow = contextWindow
    }
}

/// The startup snapshot of LiteLLM model pricing.
///
/// Lookup is exact first. A response model is deliberately checked separately
/// by callers, because an alias can be answered by a concrete fallback model and
/// the concrete row is the better price when LiteLLM exposes one.
public struct ModelPricingCatalog: Sendable, Hashable, Codable {
    public var entries: [ModelPricingEntry]

    public init(entries: [ModelPricingEntry] = []) {
        self.entries = entries
    }

    public static let empty = ModelPricingCatalog()

    public func entry(for model: String) -> ModelPricingEntry? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return entries.first { $0.modelName == trimmed }
            ?? entries.first { $0.modelName.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public func rates(for model: String) -> ModelCostRates? {
        entry(for: model)?.rates
    }

    public func contextWindow(for model: String) -> Int? {
        entry(for: model)?.contextWindow
    }
}

/// The lenient `GET /model/info` response. LiteLLM has added fields to this
/// envelope over time, so the row is kept as a JSON object and only known price
/// keys are interpreted.
struct ModelInfoResponse: Sendable {
    var rows: [ModelPricingEntry]

    init(data: Data) throws {
        let root = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let values = root["data"]?.arrayValue ?? []
        rows = values.compactMap(Self.entry(from:))
    }

    private static func entry(from value: JSONValue) -> ModelPricingEntry? {
        guard let row = value.objectValue else { return nil }
        let modelName = row["model_name"]?.stringValue
            ?? row["modelName"]?.stringValue
            ?? row["id"]?.stringValue
            ?? row["model"]?.stringValue
        guard let modelName, !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let info = row["model_info"]?.objectValue ?? row
        let rates = rates(from: info)
        let contextWindow = firstInt(
            info,
            keys: ["context_window", "contextWindow", "max_input_tokens", "max_tokens"]
        )
        return ModelPricingEntry(modelName: modelName, rates: rates, contextWindow: contextWindow)
    }

    private static func rates(from info: [String: JSONValue]) -> ModelCostRates? {
        let base = tokenRates(from: info)
        let tiers = (info["tiers"]?.arrayValue ?? info["pricing_tiers"]?.arrayValue ?? [])
            .compactMap(tier(from:))
        guard base != nil || !tiers.isEmpty else { return nil }
        return ModelCostRates(base: base ?? .free, tiers: tiers)
    }

    private static func tokenRates(from object: [String: JSONValue]) -> TokenRates? {
        let input = decimalPerToken(object, keys: ["input_cost_per_token", "inputCostPerToken"])
        let output = decimalPerToken(object, keys: ["output_cost_per_token", "outputCostPerToken"])
        let cacheRead = decimalPerToken(object, keys: [
            "cache_read_input_token_cost", "cacheReadInputTokenCost",
            "cache_read_input_cost", "cacheReadInputCost",
        ])
        let cacheWrite = decimalPerToken(object, keys: [
            "cache_creation_input_token_cost", "cacheCreationInputTokenCost",
            "cache_write_input_token_cost", "cacheWriteInputTokenCost",
            "cache_write_input_cost", "cacheWriteInputCost",
        ])
        guard input != nil || output != nil || cacheRead != nil || cacheWrite != nil else { return nil }
        let million = Decimal(1_000_000)
        return TokenRates(
            input: (input ?? 0) * million,
            output: (output ?? 0) * million,
            cacheRead: (cacheRead ?? 0) * million,
            cacheWrite: (cacheWrite ?? 0) * million
        )
    }

    private static func tier(from value: JSONValue) -> ModelCostRates.Tier? {
        guard let object = value.objectValue else { return nil }
        let threshold = firstInt(object, keys: [
            "input_tokens_above", "inputTokensAbove", "input_tokens", "threshold"
        ])
        guard let threshold, threshold >= 0, let rates = tokenRates(from: object) else { return nil }
        return ModelCostRates.Tier(inputTokensAbove: threshold, rates: rates)
    }

    private static func decimalPerToken(
        _ object: [String: JSONValue],
        keys: [String]
    ) -> Decimal? {
        for key in keys {
            guard let value = object[key] else { continue }
            let decimal: Decimal?
            switch value {
            case .int(let number): decimal = Decimal(number)
            case .double(let number): decimal = DecimalText.strict(String(number))
            case .string(let text): decimal = DecimalText.strict(text)
            default: decimal = nil
            }
            if let decimal, decimal >= 0 { return decimal }
        }
        return nil
    }

    private static func firstInt(_ object: [String: JSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key]?.intValue, value > 0 { return value }
        }
        return nil
    }
}
