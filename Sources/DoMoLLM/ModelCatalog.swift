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
