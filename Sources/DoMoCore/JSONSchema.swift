// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// A JSON Schema, as tool definitions use it.
///
/// This is a *representation*, not a validator. Its only job is to land in
/// `tools[].function.parameters` of an OpenAI-compatible request as exactly the
/// bytes the provider expects. Validating arguments that come back is a separate
/// concern, handled in DoMoTools by swift-json-schema; DoMoCore takes no
/// dependencies, so nothing here interprets a schema.
///
/// Upstream pi writes tool parameters with TypeBox (`Type.Object({ path:
/// Type.String(...), offset: Type.Optional(...) })`) and hands the resulting
/// object straight to the provider — see
/// `packages/coding-agent/src/core/tools/read.ts` and
/// `packages/ai/src/api/openai-completions.ts`. The keyword subset modeled here
/// is what TypeBox emits for those seven tools, plus the composition keywords
/// pi's own config schemas reach for.
///
/// The shape is a bag of keywords rather than an enum of kinds because JSON
/// Schema keywords are additive, not alternative: one schema carries `type`,
/// `description`, `enum`, and `default` at once, and `"type": ["string",
/// "null"]` has no single kind to be. An enum would force every construction
/// site through an escape hatch within a day.
///
/// Two legal forms are not objects at all, and a keyed decode throws outright on
/// them, so both are modeled here rather than left to fail: the boolean schemas
/// `true` and `false` (``booleanSchema``) and draft-07 tuple `items`
/// (``tupleItems``).
///
/// Keywords with no field of their own land in ``additionalKeywords`` as opaque
/// values and are re-emitted with their structure and values intact — `$defs`,
/// `allOf`, `not`, `patternProperties` and the rest survive a round trip. The
/// bytes are not always identical: encoding goes through `JSONEncoder`, which
/// escapes `/` as `\/`, so a `$schema` URL comes back re-escaped though it
/// parses to the same string. What passthrough values do not get is
/// interpretation: a schema nested inside one is a ``JSONValue``, not a
/// ``JSONSchema``, so nothing walks it and ``maximumNestingDepth`` does not
/// apply to it.
///
/// What cannot round-trip, deliberately: key order within an object, which is
/// sorted on the way out (see ``jsonValue``); duplicate keys in the source
/// bytes, where the last wins; and a modeled keyword carrying a shape this type
/// rejects — `"type": "str"` or `"items": 3` fail the decode instead of passing
/// through, because forwarding them would trade a local error for a provider
/// 400 nobody can trace.
public struct JSONSchema: Sendable, Hashable {

    // MARK: Common

    /// `nil` means the keyword is absent, which in JSON Schema means "any type" —
    /// not "null". Providers treat an untyped property as unconstrained.
    public var type: TypeConstraint?

    /// The model reads this. It is the single highest-leverage field in a tool
    /// definition and the only one that is nearly always set.
    public var description: String?

    /// Encodes as `enum`. Values are `JSONValue` rather than `[String]` because
    /// numeric and boolean enums are legal and appear in hand-written schemas;
    /// ``enumeration(_:description:default:)`` covers the string case.
    public var enumValues: [JSONValue]?

    /// Encodes as `const`.
    public var constValue: JSONValue?

    /// Encodes as `default`. Note that pi's built-in tools document defaults in
    /// prose inside `description` instead ("(default: false)"), because models
    /// read descriptions far more reliably than they honor this keyword.
    public var defaultValue: JSONValue?

    // MARK: Object

    /// Present-but-empty and absent are different on the wire: the Anthropic
    /// converter in pi substitutes `{}` when a tool schema has no `properties`,
    /// so an object schema keeps an empty dictionary rather than `nil`.
    public var properties: [String: JSONSchema]?

    /// Never encoded when empty — see ``encode(to:)``.
    public var required: [String]

    public var additionalProperties: AdditionalProperties?

    // MARK: Array

    /// The single-schema form of `items`: every element must match this.
    ///
    /// Shares storage with ``tupleItems`` because they are two spellings of one
    /// keyword and only one of them can be on the wire. Assigning a schema here
    /// therefore discards any tuple, and assigning `nil` removes `items`
    /// entirely, whichever form was there.
    public var items: JSONSchema? {
        get {
            if case .some(.single(let schema)) = itemsStorage { return schema }
            return nil
        }
        set { itemsStorage = newValue.map(Items.single) }
    }

    /// The draft-07 tuple form, `"items": [{...}, {...}]`, where position *n* is
    /// constrained by element *n*.
    ///
    /// Draft 2020-12 renamed this to ``prefixItems`` and gave `items` back its
    /// single-schema meaning, but draft-07 is still what most hand-written and
    /// MCP-supplied schemas are, so the old spelling has to survive contact with
    /// this type. Reading a tuple and writing it back produces the same bytes;
    /// it is never upgraded to `prefixItems`, which would be a different schema
    /// under a different draft.
    ///
    /// Shares storage with ``items`` — see there.
    public var tupleItems: [JSONSchema]? {
        get {
            if case .some(.tuple(let schemas)) = itemsStorage { return schemas }
            return nil
        }
        set { itemsStorage = newValue.map(Items.tuple) }
    }

    /// Draft 2020-12's positional constraints, which coexist with an `items`
    /// that then applies to everything past the prefix.
    ///
    /// Modeled rather than left to ``additionalKeywords`` — where it would
    /// already round-trip — so that the two spellings of one idea behave the
    /// same: as a passthrough value its elements would be ``JSONValue``s, not
    /// schemas, and could not be walked, compared, or depth-limited the way
    /// ``tupleItems`` can.
    public var prefixItems: [JSONSchema]?

    public var minItems: Int?
    public var maxItems: Int?

    // MARK: String

    public var minLength: Int?
    public var maxLength: Int?
    public var pattern: String?
    public var format: String?

    // MARK: Composition

    public var anyOf: [JSONSchema]?

    // MARK: Boolean schema

    /// Non-`nil` when the schema is the literal `true` or `false` rather than an
    /// object of keywords.
    ///
    /// Draft 2019-09 made both legal anywhere a schema is expected — `true`
    /// accepts every instance, `false` accepts none — and foreign schemas use
    /// them freely: `{"properties": {"x": true}}` is the shortest way to say
    /// that `x` may be anything. A validator sees no difference between `true`
    /// and `{}`, but a provider sees different bytes, so the two are kept
    /// distinct and neither is normalized into the other.
    ///
    /// While this is set the schema *is* that boolean: every other keyword is
    /// ignored by ``jsonValue`` and ``encode(to:)``, since the form has nowhere
    /// to carry them. Assigning through this property discards the rest, so the
    /// common construction order leaves no stranded keywords behind.
    ///
    /// That is a convenience, not an invariant, and the difference matters if
    /// you are relying on it: setting the boolean *first* and other keywords
    /// after leaves those keywords in place, unencodable but still counted by
    /// `Equatable`. Two such values encode to identical bytes yet compare
    /// unequal. Decoding never produces one — ``init(from:)`` returns as soon
    /// as it sees a boolean — so this is reachable only by hand-construction.
    /// Compare encoded output rather than values when byte equality is what
    /// you actually mean.
    public var booleanSchema: Bool? {
        get { booleanStorage }
        set {
            guard let newValue else {
                booleanStorage = nil
                return
            }
            self = .booleanSchema(newValue)
        }
    }

    // MARK: Passthrough

    /// Keywords this type does not model, preserved verbatim across a decode and
    /// re-encode.
    ///
    /// Foreign schemas really do carry them: pi has to strip `$schema`, `$id`,
    /// `$comment`, `$defs`, and `definitions` before handing a tool schema to
    /// Gemini's OpenAPI dialect (`packages/ai/src/api/google-shared.ts`), which
    /// is only necessary because they arrive in the first place. Dropping them on
    /// decode would silently change what gets sent to the provider.
    ///
    /// Modeled keywords always win over an entry here; decoding never files a
    /// modeled keyword into this dictionary.
    public var additionalKeywords: [String: JSONValue]

    // MARK: Storage

    /// `items` holds either one schema or a list of them, and a struct cannot
    /// store an `Optional` of itself, so the single case is boxed.
    private enum Items: Sendable, Hashable {
        indirect case single(JSONSchema)
        case tuple([JSONSchema])
    }

    private var itemsStorage: Items?
    private var booleanStorage: Bool?

    /// The unconstrained schema, `{}`. Every factory below starts here.
    public init() {
        self.required = []
        self.additionalKeywords = [:]
        self.itemsStorage = nil
        self.booleanStorage = nil
    }
}

// MARK: - Type constraint

extension JSONSchema {
    /// The seven JSON Schema primitive types. `integer` is not a JSON type but is
    /// a JSON Schema one, and providers honor it for tool arguments — pi's tools
    /// use `Type.Number()` for line offsets and limits, which is looser than it
    /// needs to be.
    public enum PrimitiveType: String, Sendable, Hashable, Codable, CaseIterable {
        case string
        case number
        case integer
        case boolean
        case array
        case object
        case null
    }

    /// `type` is either a name or a list of names. Both spellings are common
    /// enough in tool schemas that collapsing to one loses round-trip fidelity.
    public enum TypeConstraint: Sendable, Hashable {
        case single(PrimitiveType)
        case union([PrimitiveType])
    }
}

extension JSONSchema.TypeConstraint: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Decoded as `String`/`[String]` first so an unrecognized type name
        // reports itself, rather than surfacing as "expected an array".
        if let name = try? container.decode(String.self) {
            self = .single(try Self.primitive(named: name, in: container))
        } else {
            let names = try container.decode([String].self)
            self = .union(try names.map { try Self.primitive(named: $0, in: container) })
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let type): try container.encode(type.rawValue)
        case .union(let types): try container.encode(types.map(\.rawValue))
        }
    }

    private static func primitive(
        named name: String,
        in container: any SingleValueDecodingContainer
    ) throws -> JSONSchema.PrimitiveType {
        guard let type = JSONSchema.PrimitiveType(rawValue: name) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown JSON Schema type \"\(name)\""
            )
        }
        return type
    }
}

extension JSONSchema.TypeConstraint {
    public var jsonValue: JSONValue {
        switch self {
        case .single(let type): .string(type.rawValue)
        case .union(let types): .array(types.map { .string($0.rawValue) })
        }
    }
}

// MARK: - Additional properties

extension JSONSchema {
    /// `additionalProperties` is a boolean or a schema. The boolean form is the
    /// one that matters: OpenAI structured outputs and several strict-mode
    /// gateways reject an object schema that does not say `false` explicitly.
    public enum AdditionalProperties: Sendable, Hashable {
        case allowed
        case denied
        /// Every unlisted property must match this schema — the `Record<String,
        /// T>` shape.
        indirect case schema(JSONSchema)
    }
}

extension JSONSchema.AdditionalProperties: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = flag ? .allowed : .denied
        } else {
            self = .schema(try container.decode(JSONSchema.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .allowed: try container.encode(true)
        case .denied: try container.encode(false)
        case .schema(let schema): try container.encode(schema)
        }
    }
}

extension JSONSchema.AdditionalProperties {
    public var jsonValue: JSONValue {
        switch self {
        case .allowed: .bool(true)
        case .denied: .bool(false)
        case .schema(let schema): schema.jsonValue
        }
    }
}

// MARK: - Properties

extension JSONSchema {
    /// One entry of an object schema's `properties`, carrying its own
    /// requiredness.
    ///
    /// Requiredness lives on the property rather than in a parallel `[String]`
    /// the author maintains by hand, mirroring TypeBox's `Type.Optional(...)`
    /// wrapper — the two cannot drift apart if they are the same declaration.
    /// The assembled ``JSONSchema`` still stores `required` as a plain list,
    /// because JSON Schema permits naming a required property that has no
    /// `properties` entry and a decoded schema must survive that.
    public struct Property: Sendable, Hashable {
        public var name: String
        public var schema: JSONSchema
        public var isRequired: Bool

        public init(name: String, schema: JSONSchema, isRequired: Bool = true) {
            self.name = name
            self.schema = schema
            self.isRequired = isRequired
        }

        public static func required(_ name: String, _ schema: JSONSchema) -> Property {
            Property(name: name, schema: schema, isRequired: true)
        }

        public static func optional(_ name: String, _ schema: JSONSchema) -> Property {
            Property(name: name, schema: schema, isRequired: false)
        }
    }
}

extension JSONValue {
    /// A `Double` as the ``JSONValue`` case it will come back as.
    ///
    /// `JSONValue` canonicalizes an integral number to `.int` on decode — `1.0`
    /// and `1` are the same JSON number — so storing `.double(30)` in a schema
    /// builds a value that is not equal to itself after a round trip even though
    /// the bytes never change. Numbers that enter through a `Double`-typed API go
    /// through here so the in-memory form matches the decoded one.
    fileprivate static func canonicalNumber(_ value: Double) -> JSONValue {
        JSONValue.double(value).intValue.map(JSONValue.int) ?? .double(value)
    }
}

// MARK: - Factories

extension JSONSchema {
    public static func string(
        description: String? = nil,
        enumValues: [String]? = nil,
        pattern: String? = nil,
        format: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        default defaultValue: String? = nil
    ) -> JSONSchema {
        var schema = JSONSchema()
        schema.type = .single(.string)
        schema.description = description
        schema.enumValues = enumValues.map { $0.map(JSONValue.string) }
        schema.pattern = pattern
        schema.format = format
        schema.minLength = minLength
        schema.maxLength = maxLength
        schema.defaultValue = defaultValue.map(JSONValue.string)
        return schema
    }

    public static func number(
        description: String? = nil,
        default defaultValue: Double? = nil
    ) -> JSONSchema {
        var schema = JSONSchema()
        schema.type = .single(.number)
        schema.description = description
        schema.defaultValue = defaultValue.map(JSONValue.canonicalNumber)
        return schema
    }

    public static func integer(
        description: String? = nil,
        default defaultValue: Int? = nil
    ) -> JSONSchema {
        var schema = JSONSchema()
        schema.type = .single(.integer)
        schema.description = description
        schema.defaultValue = defaultValue.map(JSONValue.int)
        return schema
    }

    public static func boolean(
        description: String? = nil,
        default defaultValue: Bool? = nil
    ) -> JSONSchema {
        var schema = JSONSchema()
        schema.type = .single(.boolean)
        schema.description = description
        schema.defaultValue = defaultValue.map(JSONValue.bool)
        return schema
    }

    public static func null(description: String? = nil) -> JSONSchema {
        var schema = JSONSchema()
        schema.type = .single(.null)
        schema.description = description
        return schema
    }

    public static func array(
        of items: JSONSchema,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> JSONSchema {
        var schema = JSONSchema()
        schema.type = .single(.array)
        schema.description = description
        schema.items = items
        schema.minItems = minItems
        schema.maxItems = maxItems
        return schema
    }

    /// Builds an object schema from declarations that carry their own
    /// requiredness:
    ///
    /// ```swift
    /// JSONSchema.object(
    ///     .required("path", .string(description: "Path to the file to read")),
    ///     .optional("offset", .number(description: "Line to start from (1-indexed)"))
    /// )
    /// ```
    ///
    /// Variadic rather than a result builder on purpose. In a builder closure the
    /// properties would have to be written `JSONSchema.Property.required(...)` on
    /// every line: a leading `.` at the start of a new line parses as a
    /// continuation of the previous expression, so consecutive `.required(...)`
    /// statements become one member chain and fail to compile. Commas keep the
    /// leading-dot shorthand working, which is the whole point of the API.
    ///
    /// Repeating a name keeps the last schema and one `required` entry, matching
    /// what a JSON object literal would do.
    public static func object(
        _ properties: Property...,
        description: String? = nil,
        additionalProperties: AdditionalProperties? = nil
    ) -> JSONSchema {
        object(
            properties: properties,
            description: description,
            additionalProperties: additionalProperties
        )
    }

    /// The escape hatch for schemas assembled at runtime, where the property set
    /// is not known at the call site.
    public static func object(
        properties: [Property],
        description: String? = nil,
        additionalProperties: AdditionalProperties? = nil
    ) -> JSONSchema {
        var schemas: [String: JSONSchema] = [:]
        var isRequired: [String: Bool] = [:]
        var order: [String] = []

        // The last declaration of a name wins *entirely* — schema and
        // requiredness both. Letting the schema be overridden while requiredness
        // accumulated would make `.required("path", …)` followed by
        // `.optional("path", …)` produce an optional-looking property that is
        // still listed in `required`, which is exactly the drift the `Property`
        // design exists to prevent. The name keeps the position of its first
        // declaration so appending an override does not reshuffle `required`.
        for property in properties {
            if schemas.updateValue(property.schema, forKey: property.name) == nil {
                order.append(property.name)
            }
            isRequired[property.name] = property.isRequired
        }

        let required = order.filter { isRequired[$0] == true }

        var schema = JSONSchema()
        schema.type = .single(.object)
        schema.description = description
        schema.properties = schemas
        schema.required = required
        schema.additionalProperties = additionalProperties
        return schema
    }

    /// A string schema restricted to a fixed set of values.
    public static func enumeration(
        _ values: [String],
        description: String? = nil,
        default defaultValue: String? = nil
    ) -> JSONSchema {
        .string(description: description, enumValues: values, default: defaultValue)
    }

    public static func constant(_ value: JSONValue, description: String? = nil) -> JSONSchema {
        var schema = JSONSchema()
        schema.constValue = value
        schema.description = description
        return schema
    }

    /// The schema `true` or `false` itself — not `{"type": "boolean"}`, which is
    /// ``boolean(description:default:)`` and constrains an *instance* to be a
    /// boolean. See ``booleanSchema``.
    public static func booleanSchema(_ accepts: Bool) -> JSONSchema {
        var schema = JSONSchema()
        schema.booleanStorage = accepts
        return schema
    }

    /// `true`: accepts every instance. Distinct from `{}` on the wire.
    public static let acceptsAnything = JSONSchema.booleanSchema(true)

    /// `false`: accepts no instance. In `additionalProperties` position prefer
    /// ``AdditionalProperties/denied``, which produces the same bytes.
    public static let acceptsNothing = JSONSchema.booleanSchema(false)

    /// A union of dissimilar schemas. For a union of primitive types alone,
    /// prefer `type: .union([...])` — it is the spelling strict-mode providers
    /// accept in more positions.
    public static func anyOf(_ schemas: [JSONSchema], description: String? = nil) -> JSONSchema {
        var schema = JSONSchema()
        schema.anyOf = schemas
        schema.description = description
        return schema
    }
}

// MARK: - Modifiers

extension JSONSchema {
    /// Widens the schema to also accept `null`.
    ///
    /// This produces `"type": ["string", "null"]`, which diverges from TypeBox —
    /// `Type.Union([Type.String(), Type.Null()])` emits `anyOf`. The `type` array
    /// is understood by every provider that accepts JSON Schema at all, whereas
    /// `anyOf` inside a property is rejected by OpenAI strict mode and flattened
    /// unpredictably by Gemini's OpenAPI dialect.
    ///
    /// An untyped schema already permits null, so this leaves it alone.
    public func nullable() -> JSONSchema {
        var schema = self
        switch type {
        case .single(let type) where type != .null:
            schema.type = .union([type, .null])
        case .union(let types) where !types.contains(.null):
            schema.type = .union(types + [.null])
        case .single, .union, nil:
            break
        }
        return schema
    }

    public func with(description: String) -> JSONSchema {
        var schema = self
        schema.description = description
        return schema
    }

    public func with(default value: JSONValue) -> JSONSchema {
        var schema = self
        schema.defaultValue = value
        return schema
    }
}

// MARK: - Codable

extension JSONSchema: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type
        case description
        case enumValues = "enum"
        case constValue = "const"
        case defaultValue = "default"
        case properties
        case required
        case additionalProperties
        case items
        case prefixItems
        case minItems
        case maxItems
        case minLength
        case maxLength
        case pattern
        case format
        case anyOf
    }

    private struct PassthroughKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let modeledKeywords = Set(CodingKeys.allCases.map(\.rawValue))

    /// How deep a decoded schema may nest before decoding fails.
    ///
    /// Decoding is recursive, and so is everything downstream of it
    /// (``jsonValue``, `==`, `hash(into:)`). Foundation's decoder has its own
    /// 512-level guard, but that number is calibrated for an 8 MB main-thread
    /// stack: on a Swift concurrency thread, whose stack is 512 KB, a schema
    /// nested past roughly 140 levels overflows the stack and takes the process
    /// down with `SIGBUS` — measured, and reached long before Foundation objects.
    /// Tool schemas arrive from extensions and MCP servers, so that is untrusted
    /// input crashing the agent.
    ///
    /// 64 is far past anything a real tool parameter schema needs; the deepest
    /// of pi's built-ins is 4.
    public static let maximumNestingDepth = 64

    public init(from decoder: any Decoder) throws {
        self.init()

        // `codingPath` counts container levels, so it is an undercount of true
        // nesting depth in exactly the safe direction: an object property costs
        // two entries per level ("properties", name) and `items` costs one.
        guard decoder.codingPath.count <= Self.maximumNestingDepth else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "JSON Schema nested deeper than \(Self.maximumNestingDepth) levels"
                )
            )
        }

        // Settled before a keyed container is asked for, because `true` and
        // `false` are whole schemas and asking would throw a type mismatch on
        // them — which is how a foreign schema carrying one used to take the
        // entire decode down with it.
        if let single = try? decoder.singleValueContainer(),
            let flag = try? single.decode(Bool.self)
        {
            booleanStorage = flag
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try container.decodeIfPresent(TypeConstraint.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        enumValues = try container.decodeIfPresent([JSONValue].self, forKey: .enumValues)

        // `decodeIfPresent` reports a JSON `null` as absent, which is wrong for a
        // keyword whose value may legitimately *be* null: `"default": null` on a
        // nullable parameter says something, and losing it changes the schema.
        constValue = try container.decodeIfContains(JSONValue.self, forKey: .constValue)
        defaultValue = try container.decodeIfContains(JSONValue.self, forKey: .defaultValue)

        properties = try container.decodeIfPresent([String: JSONSchema].self, forKey: .properties)
        required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
        additionalProperties = try container.decodeIfPresent(
            AdditionalProperties.self, forKey: .additionalProperties)
        itemsStorage = try Self.decodeItems(from: container)
        prefixItems = try container.decodeIfPresent([JSONSchema].self, forKey: .prefixItems)
        minItems = try container.decodeIfPresent(Int.self, forKey: .minItems)
        maxItems = try container.decodeIfPresent(Int.self, forKey: .maxItems)
        minLength = try container.decodeIfPresent(Int.self, forKey: .minLength)
        maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        anyOf = try container.decodeIfPresent([JSONSchema].self, forKey: .anyOf)

        let passthrough = try decoder.container(keyedBy: PassthroughKey.self)
        for key in passthrough.allKeys where !Self.modeledKeywords.contains(key.stringValue) {
            additionalKeywords[key.stringValue] = try passthrough.decode(JSONValue.self, forKey: key)
        }
    }

    /// Picks the `items` form from the JSON's shape rather than by trying one
    /// and falling back.
    ///
    /// A fallback would report a bad tuple element ("unknown type \"str\"") as
    /// the far less useful "expected a dictionary, found an array", because the
    /// retry is what fails last.
    private static func decodeItems(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Items? {
        guard container.contains(.items), try !container.decodeNil(forKey: .items) else {
            return nil
        }
        if (try? container.nestedUnkeyedContainer(forKey: .items)) != nil {
            return .tuple(try container.decode([JSONSchema].self, forKey: .items))
        }
        return .single(try container.decode(JSONSchema.self, forKey: .items))
    }

    public func encode(to encoder: any Encoder) throws {
        if let booleanStorage {
            var container = encoder.singleValueContainer()
            try container.encode(booleanStorage)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(enumValues, forKey: .enumValues)
        try container.encodeIfPresent(constValue, forKey: .constValue)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)

        try container.encodeIfPresent(properties, forKey: .properties)

        // `required: []` is not the same as an absent `required` to a strict
        // validator, and TypeBox — which upstream pi's tool schemas are written
        // against — omits it. Omitting keeps the wire bytes identical to pi's.
        if !required.isEmpty {
            try container.encode(required, forKey: .required)
        }

        try container.encodeIfPresent(additionalProperties, forKey: .additionalProperties)
        switch itemsStorage {
        case .single(let schema): try container.encode(schema, forKey: .items)
        case .tuple(let schemas): try container.encode(schemas, forKey: .items)
        case nil: break
        }

        try container.encodeIfPresent(prefixItems, forKey: .prefixItems)
        try container.encodeIfPresent(minItems, forKey: .minItems)
        try container.encodeIfPresent(maxItems, forKey: .maxItems)
        try container.encodeIfPresent(minLength, forKey: .minLength)
        try container.encodeIfPresent(maxLength, forKey: .maxLength)
        try container.encodeIfPresent(pattern, forKey: .pattern)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(anyOf, forKey: .anyOf)

        if !additionalKeywords.isEmpty {
            var passthrough = encoder.container(keyedBy: PassthroughKey.self)
            for (name, value) in additionalKeywords where !Self.modeledKeywords.contains(name) {
                try passthrough.encode(value, forKey: PassthroughKey(name))
            }
        }
    }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent`, except that a present-but-null value decodes rather
    /// than being reported as absent.
    fileprivate func decodeIfContains<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        contains(key) ? try decode(type, forKey: key) : nil
    }
}

// MARK: - JSONValue interoperation

extension JSONSchema {
    /// The schema as a ``JSONValue``, for splicing into a request body that is
    /// assembled as JSON.
    ///
    /// This is the canonical path to the wire, and it is where key ordering is
    /// settled. Declaration order cannot survive: `JSONValue.object` wraps an
    /// unordered `Dictionary`, and neither can a `Codable` type impose an order
    /// on its own output — the serialization order of a keyed container is the
    /// encoder's choice, and Foundation's `JSONEncoder` emits hash order unless
    /// told otherwise. So the canonical order is sorted-by-key, produced by
    /// ``encoded(prettyPrinted:)`` and by `JSONValue.encoded()`. Sorted is the
    /// only order that is the same in every process; raw `Dictionary` order is
    /// not stable across runs, and a tool schema that changes bytes between runs
    /// breaks prompt caching.
    public var jsonValue: JSONValue {
        if let booleanStorage { return .bool(booleanStorage) }

        // The bag is filtered rather than merely overwritten, so that a passthrough
        // entry named after a modeled keyword cannot leak through when that
        // keyword happens to be nil. `encode(to:)` drops the same entries.
        var object = additionalKeywords.filter { !Self.modeledKeywords.contains($0.key) }

        if let type { object["type"] = type.jsonValue }
        if let description { object["description"] = .string(description) }
        if let enumValues { object["enum"] = .array(enumValues) }
        if let constValue { object["const"] = constValue }
        if let defaultValue { object["default"] = defaultValue }
        if let properties { object["properties"] = .object(properties.mapValues(\.jsonValue)) }
        if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
        if let additionalProperties {
            object["additionalProperties"] = additionalProperties.jsonValue
        }
        switch itemsStorage {
        case .single(let schema): object["items"] = schema.jsonValue
        case .tuple(let schemas): object["items"] = .array(schemas.map(\.jsonValue))
        case nil: break
        }
        if let prefixItems { object["prefixItems"] = .array(prefixItems.map(\.jsonValue)) }
        if let minItems { object["minItems"] = .int(minItems) }
        if let maxItems { object["maxItems"] = .int(maxItems) }
        if let minLength { object["minLength"] = .int(minLength) }
        if let maxLength { object["maxLength"] = .int(maxLength) }
        if let pattern { object["pattern"] = .string(pattern) }
        if let format { object["format"] = .string(format) }
        if let anyOf { object["anyOf"] = .array(anyOf.map(\.jsonValue)) }

        return .object(object)
    }

    /// Reads a schema back out of a ``JSONValue`` — an extension-supplied tool
    /// definition, or a session file.
    ///
    /// Routed through `Codable` rather than walked by hand: the decoder is the
    /// only place the keyword-to-field mapping is written down, and a second copy
    /// of it here would be the copy that rots.
    public init(jsonValue: JSONValue) throws {
        self = try JSONDecoder().decode(JSONSchema.self, from: jsonValue.encoded())
    }

    /// Encodes to UTF-8 JSON with sorted keys, matching `JSONValue.encoded()`.
    ///
    /// Prefer this over handing a schema to a bare `JSONEncoder`, which sorts
    /// nothing by default.
    public func encoded(prettyPrinted: Bool = false) throws -> Data {
        try jsonValue.encoded(prettyPrinted: prettyPrinted)
    }

    /// Encodes to a UTF-8 JSON string with sorted keys.
    public func encodedString(prettyPrinted: Bool = false) throws -> String {
        try jsonValue.encodedString(prettyPrinted: prettyPrinted)
    }
}
