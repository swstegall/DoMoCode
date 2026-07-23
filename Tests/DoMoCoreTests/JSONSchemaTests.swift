// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Testing

import DoMoCore

@Suite("JSONSchema")
struct JSONSchemaTests {

    /// The canonical path: through `JSONValue`, which is how a schema reaches a
    /// request body.
    private func encoded(_ schema: JSONSchema) throws -> String {
        try schema.encodedString()
    }

    /// The `Codable` path, which is a different code path entirely and must agree
    /// with the canonical one.
    private func viaCodable(_ schema: JSONSchema) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(schema), as: UTF8.self)
    }

    private func decoded(_ json: String) throws -> JSONSchema {
        try JSONDecoder().decode(JSONSchema.self, from: Data(json.utf8))
    }

    // MARK: - required

    @Test("An object with no required properties omits `required` entirely")
    func emptyRequiredIsOmitted() throws {
        let schema = JSONSchema.object(.optional("path", .string()))
        #expect(try encoded(schema) == #"{"properties":{"path":{"type":"string"}},"type":"object"}"#)
    }

    /// A tool that takes no arguments still needs `properties: {}` — pi's
    /// Anthropic converter substitutes `{}` when it is missing, so emitting it
    /// keeps the two paths byte-identical.
    @Test("A no-argument object keeps an empty `properties` but no `required`")
    func emptyObjectKeepsProperties() throws {
        #expect(try encoded(JSONSchema.object()) == #"{"properties":{},"type":"object"}"#)
    }

    @Test("`required` keeps declaration order, not alphabetical order")
    func requiredKeepsDeclarationOrder() throws {
        let schema = JSONSchema.object(
            .required("zulu", .string()),
            .required("alpha", .string())
        )
        #expect(schema.required == ["zulu", "alpha"])
        #expect(try encoded(schema).contains(#""required":["zulu","alpha"]"#))
    }

    @Test("A schema with an empty `required` equals one that never had the key")
    func emptyRequiredEqualsAbsent() throws {
        #expect(try decoded(#"{"type":"object","properties":{}}"#) == JSONSchema.object())
    }

    /// `required` may name a property that has no `properties` entry. It is legal
    /// and a decoded foreign schema must survive it, which is why requiredness is
    /// stored as a list rather than derived from the property set.
    @Test("A required name with no matching property survives a round trip")
    func danglingRequiredSurvives() throws {
        let json = #"{"properties":{},"required":["ghost"],"type":"object"}"#
        #expect(try encoded(decoded(json)) == json)
    }

    // MARK: - Property ordering

    /// Declaration order is unrecoverable — `JSONValue.object` is a `Dictionary`
    /// and so is `JSONEncoder`'s keyed storage — so the contract is sorted keys,
    /// which is at least the same in every process.
    @Test("Properties encode in sorted order regardless of declaration order")
    func propertiesEncodeSorted() throws {
        let schema = JSONSchema.object(
            .required("zulu", .string()),
            .required("mike", .string()),
            .required("alpha", .string())
        )
        let expected = """
            {"properties":{"alpha":{"type":"string"},"mike":{"type":"string"},\
            "zulu":{"type":"string"}},"required":["zulu","mike","alpha"],"type":"object"}
            """
        #expect(try encoded(schema) == expected)
    }

    // MARK: - additionalProperties

    @Test(
        "additionalProperties encodes as a boolean or a schema",
        arguments: [
            (JSONSchema.AdditionalProperties.denied, "false"),
            (.allowed, "true"),
            (.schema(.string()), #"{"type":"string"}"#),
        ])
    func additionalPropertiesEncoding(
        value: JSONSchema.AdditionalProperties,
        expected: String
    ) throws {
        var schema = JSONSchema.object()
        schema.additionalProperties = value
        #expect(try encoded(schema).contains(#""additionalProperties":"# + expected))
        #expect(try decoded(encoded(schema)).additionalProperties == value)
    }

    // MARK: - Types

    @Test("nullable() widens to the `type` array spelling rather than anyOf")
    func nullableUsesTypeArray() throws {
        let schema = JSONSchema.string(description: "branch").nullable()
        #expect(schema.type == .union([.string, .null]))
        #expect(try encoded(schema).contains(#""type":["string","null"]"#))
    }

    @Test("nullable() is idempotent and leaves an untyped schema alone")
    func nullableIdempotent() {
        let once = JSONSchema.integer().nullable()
        #expect(once.nullable() == once)
        #expect(JSONSchema().nullable() == JSONSchema())
        #expect(JSONSchema.null().nullable() == JSONSchema.null())
    }

    @Test("A `type` array decodes to a union and re-encodes as an array")
    func typeArrayRoundTrips() throws {
        let json = #"{"type":["integer","null"]}"#
        #expect(try decoded(json).type == .union([.integer, .null]))
        #expect(try encoded(decoded(json)) == json)
    }

    /// A single-element `type` array is not normalized to the scalar spelling:
    /// re-encoding a foreign schema must not change bytes the provider already
    /// accepted.
    @Test("A single-element type array stays an array")
    func singleElementTypeArrayIsPreserved() throws {
        #expect(try encoded(decoded(#"{"type":["string"]}"#)) == #"{"type":["string"]}"#)
    }

    @Test("An unrecognized type name fails decoding")
    func unknownTypeNameThrows() {
        #expect(throws: DecodingError.self) { try decoded(#"{"type":"str"}"#) }
        #expect(throws: DecodingError.self) { try decoded(#"{"type":["string","str"]}"#) }
    }

    // MARK: - Values

    @Test("enum, const and default carry JSON values, not just strings")
    func valueKeywords() throws {
        var schema = JSONSchema.integer()
        schema.enumValues = [1, 2, 3]
        schema.constValue = 2
        schema.defaultValue = 2
        #expect(try encoded(schema) == #"{"const":2,"default":2,"enum":[1,2,3],"type":"integer"}"#)
    }

    /// `.some(.null)` and `.none` both look like "no value" to a careless
    /// encoder, and `"default": null` is a meaningful thing for a nullable
    /// parameter to say.
    @Test("An explicit null default is emitted, an absent one is not")
    func explicitNullDefault() throws {
        var schema = JSONSchema.string().nullable()
        schema.defaultValue = .null
        #expect(try encoded(schema).contains(#""default":null"#))
        #expect(try decoded(encoded(schema)).defaultValue == JSONValue.null)
        #expect(try decoded(#"{"type":"string"}"#).defaultValue == nil)
    }

    @Test("An integer default stays an integer on the wire")
    func integerDefaultKeepsIdentity() throws {
        #expect(try encoded(.integer(default: 3)) == #"{"default":3,"type":"integer"}"#)
    }

    @Test("enumeration() produces a constrained string schema")
    func enumerationShorthand() throws {
        let schema = JSONSchema.enumeration(["deny", "allow"], default: "deny")
        #expect(
            try encoded(schema)
                == #"{"default":"deny","enum":["deny","allow"],"type":"string"}"#)
    }

    @Test("String constraints encode under their JSON Schema names")
    func stringConstraints() throws {
        let schema = JSONSchema.string(
            pattern: "^[a-z]+$", format: "uri", minLength: 1, maxLength: 64)
        #expect(
            try encoded(schema)
                == #"{"format":"uri","maxLength":64,"minLength":1,"pattern":"^[a-z]+$","type":"string"}"#)
    }

    // MARK: - Unmodeled keywords

    /// pi strips `$schema`, `$id`, `$comment`, `$defs` and `definitions` before
    /// handing a tool schema to Gemini's OpenAPI dialect, which is only necessary
    /// because foreign schemas arrive carrying them. Dropping them here would
    /// silently change what reaches the provider.
    @Test("Unmodeled keywords survive a decode and re-encode, nested included")
    func passthroughKeywords() throws {
        let json = """
            {"$defs":{"cmd":{"type":"string"}},"$schema":"draft-07",\
            "properties":{"command":{"exclusiveMinimum":0,"x-vendor":true}},\
            "required":["command"],"type":"object"}
            """
        let schema = try decoded(json)
        #expect(schema.additionalKeywords["$schema"] == .string("draft-07"))
        #expect(schema.properties?["command"]?.additionalKeywords["x-vendor"] == true)
        #expect(try encoded(schema) == json)
        #expect(try viaCodable(schema) == json)
    }

    @Test("A modeled keyword wins over a colliding passthrough entry")
    func modeledKeywordsWinOverPassthrough() throws {
        var schema = JSONSchema.string()
        schema.additionalKeywords["type"] = .string("number")
        #expect(try encoded(schema) == #"{"type":"string"}"#)
        #expect(try viaCodable(schema) == #"{"type":"string"}"#)
    }

    /// The nil case is the one that can diverge: with nothing to overwrite it,
    /// a passthrough entry named after a modeled keyword would otherwise reach
    /// the wire through one serializer and not the other.
    @Test("A passthrough entry cannot resurrect a modeled keyword that is unset")
    func passthroughCannotForgeModeledKeywords() throws {
        var schema = JSONSchema()
        schema.additionalKeywords["required"] = .array(["ghost"])
        #expect(try encoded(schema) == "{}")
        #expect(try viaCodable(schema) == "{}")
    }

    // MARK: - Boolean schemas

    /// `true` and `false` are complete schemas from draft 2019-09 on, and
    /// `{"properties": {"x": true}}` is the ordinary way to say "anything
    /// goes". A keyed decode throws on them, so a foreign schema carrying one
    /// used to fail entirely instead of reaching the passthrough bag.
    @Test("A boolean subschema decodes and re-encodes as the same bytes")
    func booleanSubschemaRoundTrips() throws {
        let json = #"{"properties":{"x":true,"y":false},"type":"object"}"#
        let schema = try decoded(json)
        #expect(schema.properties?["x"]?.booleanSchema == true)
        #expect(schema.properties?["y"]?.booleanSchema == false)
        #expect(try encoded(schema) == json)
        #expect(try viaCodable(schema) == json)
    }

    @Test("A schema that is nothing but a boolean decodes at the top level")
    func topLevelBooleanSchema() throws {
        #expect(try decoded("true") == .acceptsAnything)
        #expect(try decoded("false") == .acceptsNothing)
        #expect(try encoded(.acceptsAnything) == "true")
        #expect(try viaCodable(.acceptsNothing) == "false")
        #expect(JSONSchema.acceptsAnything.jsonValue == .bool(true))
        #expect(try JSONSchema(jsonValue: .bool(false)) == .acceptsNothing)
    }

    /// A validator sees no difference between `true` and `{}`; a provider sees
    /// different bytes. Decoding a foreign schema exists to send it back out
    /// unchanged, so neither may be normalized into the other.
    @Test("`true` is not normalized to `{}`, nor `{}` to `true`")
    func booleanSchemaIsNotNormalized() throws {
        #expect(JSONSchema.acceptsAnything != JSONSchema())
        #expect(try encoded(decoded("{}")) == "{}")
        #expect(try encoded(decoded("true")) == "true")
    }

    /// The boolean form has nowhere to carry keywords, so assigning it drops
    /// them — otherwise two schemas that encode to identical bytes would
    /// compare unequal.
    @Test("Setting booleanSchema clears the keywords it cannot encode")
    func booleanSchemaClearsKeywords() throws {
        var schema = JSONSchema.string(description: "branch")
        schema.booleanSchema = false
        #expect(schema == .acceptsNothing)
        #expect(try encoded(schema) == "false")

        schema.booleanSchema = nil
        #expect(schema == JSONSchema())
    }

    @Test("Boolean schemas nest in every position that holds a schema")
    func booleanSchemaInEveryPosition() throws {
        let json = #"{"anyOf":[true,{"type":"string"}],"items":false,"type":"array"}"#
        let schema = try decoded(json)
        #expect(schema.items == JSONSchema.acceptsNothing)
        #expect(schema.anyOf?.first == JSONSchema.acceptsAnything)
        #expect(try encoded(schema) == json)
        #expect(try viaCodable(schema) == json)
    }

    /// `additionalProperties` had the boolean form all along, and it keeps its
    /// own spelling of it rather than routing through ``JSONSchema``.
    @Test("A boolean additionalProperties still decodes to the enum, not a subschema")
    func booleanAdditionalPropertiesUnchanged() throws {
        #expect(try decoded(#"{"additionalProperties":false}"#).additionalProperties == .denied)
    }

    // MARK: - items forms

    /// Draft-07 tuple `items`, where position *n* is constrained by element
    /// *n*. This used to fail the whole decode.
    @Test("Tuple-form items round-trips as a tuple, not as one schema")
    func tupleItemsRoundTrips() throws {
        let json = #"{"items":[{"type":"string"},{"type":"number"}],"type":"array"}"#
        let schema = try decoded(json)
        #expect(schema.tupleItems?.count == 2)
        #expect(schema.items == nil)
        #expect(try encoded(schema) == json)
        #expect(try viaCodable(schema) == json)
        #expect(try JSONSchema(jsonValue: schema.jsonValue) == schema)
    }

    @Test("An empty tuple keeps the keyword")
    func emptyTupleItems() throws {
        #expect(try decoded(#"{"items":[]}"#).tupleItems == [])
        #expect(try encoded(decoded(#"{"items":[]}"#)) == #"{"items":[]}"#)
    }

    @Test("A tuple may hold boolean schemas")
    func tupleOfBooleanSchemas() throws {
        let json = #"{"items":[true,false],"type":"array"}"#
        #expect(try encoded(decoded(json)) == json)
        #expect(try decoded(json).tupleItems?.last == .acceptsNothing)
    }

    /// One keyword, two spellings, so one storage: assigning either form has to
    /// evict the other, or the encoder would have to pick a winner.
    @Test("items and tupleItems are two views of one keyword")
    func itemsAndTupleItemsShareStorage() throws {
        var schema = JSONSchema.array(of: .string())
        schema.tupleItems = [.string(), .number()]
        #expect(schema.items == nil)

        schema.items = .boolean()
        #expect(schema.tupleItems == nil)

        schema.tupleItems = nil
        #expect(try encoded(schema) == #"{"type":"array"}"#)
    }

    /// 2020-12's spelling, where `items` keeps its single-schema meaning and
    /// governs everything past the prefix.
    @Test("prefixItems is modeled and coexists with a rest-schema items")
    func prefixItemsCoexistsWithItems() throws {
        let json = #"{"items":false,"prefixItems":[{"type":"string"},true],"type":"array"}"#
        let schema = try decoded(json)
        #expect(schema.prefixItems?.count == 2)
        #expect(schema.items == JSONSchema.acceptsNothing)
        #expect(try encoded(schema) == json)
        #expect(try viaCodable(schema) == json)
    }

    /// Upgrading the draft-07 spelling would be a different schema under a
    /// different draft, changing bytes the provider already accepted.
    @Test("Tuple items is never rewritten as prefixItems")
    func tupleItemsIsNotUpgraded() throws {
        let schema = try decoded(#"{"items":[{"type":"string"}]}"#)
        #expect(schema.prefixItems == nil)
        #expect(try encoded(schema).contains("prefixItems") == false)
    }

    /// The form is chosen from the JSON's shape, so a bad element inside a
    /// tuple reports itself rather than being retried as an object and blamed
    /// for not being one.
    @Test("A malformed items value still fails, and says why")
    func malformedItems() {
        #expect(throws: DecodingError.self) { try decoded(#"{"items":[{"type":"str"}]}"#) }
        #expect(throws: DecodingError.self) { try decoded(#"{"items":3}"#) }
    }

    @Test("A null items is absent, as it was before the tuple form existed")
    func nullItemsIsAbsent() throws {
        #expect(try decoded(#"{"items":null}"#) == JSONSchema())
    }

    @Test("Tuple nesting is depth-limited like every other schema position")
    func tupleNestingIsDepthLimited() {
        let deep =
            String(repeating: #"{"items":["#, count: 300) + "{}"
            + String(repeating: "]}", count: 300)
        #expect(throws: DecodingError.self) { try decoded(deep) }
    }

    // MARK: - JSONValue interoperation

    /// Two independent serializers for one type is how a schema starts going out
    /// differently depending on which one a caller happened to reach for.
    @Test("The JSONValue path and the Codable path produce identical bytes")
    func jsonValueMatchesCodable() throws {
        for schema in Fixtures.allTools {
            #expect(try encoded(schema) == viaCodable(schema))
        }
    }

    @Test("A schema round-trips through JSONValue")
    func jsonValueRoundTrip() throws {
        for schema in Fixtures.allTools {
            #expect(try JSONSchema(jsonValue: schema.jsonValue) == schema)
        }
    }

    @Test("Decoding a JSONValue that is not an object fails rather than yielding {}")
    func jsonValueMustBeAnObject() {
        #expect(throws: (any Error).self) {
            try JSONSchema(jsonValue: .array(["string"]))
        }
    }

    // MARK: - Nesting

    @Test("Nested objects inside arrays round-trip")
    func nestedArrayOfObjects() throws {
        #expect(try decoded(encoded(Fixtures.edit)) == Fixtures.edit)
        #expect(Fixtures.edit.properties?["edits"]?.items?.required == ["oldText", "newText"])
    }

    @Test("Clearing items removes the keyword")
    func itemsCanBeCleared() throws {
        var schema = JSONSchema.array(of: .string())
        schema.items = nil
        #expect(try encoded(schema) == #"{"type":"array"}"#)
    }

    @Test("anyOf holds schemas, not raw values")
    func anyOfNesting() throws {
        let schema = JSONSchema.anyOf([.number(), .string()], description: "price")
        #expect(
            try encoded(schema)
                == #"{"anyOf":[{"type":"number"},{"type":"string"}],"description":"price"}"#)
        #expect(try decoded(encoded(schema)).anyOf?.count == 2)
    }

    @Test("Deep nesting does not lose the innermost schema")
    func deepNesting() throws {
        var schema = JSONSchema.string(description: "leaf")
        for _ in 0..<20 {
            schema = .object(.required("child", .array(of: schema)))
        }
        var walked = try decoded(encoded(schema))
        for _ in 0..<20 {
            walked = try #require(walked.properties?["child"]?.items)
        }
        #expect(walked == .string(description: "leaf"))
    }

    // MARK: - Construction

    @Test("A repeated property name keeps the last schema and one required entry")
    func duplicatePropertyNames() {
        let schema = JSONSchema.object(
            .required("path", .string(description: "first")),
            .required("path", .string(description: "second"))
        )
        #expect(schema.required == ["path"])
        #expect(schema.properties?["path"]?.description == "second")
    }

    /// The last declaration of a name has to win *entirely*. Overriding a
    /// property by appending to the array overload's input — the obvious way to
    /// specialize a shared property list — otherwise leaves the name in
    /// `required` while its declaration says optional.
    @Test("A repeated name takes its requiredness from the last declaration")
    func duplicatePropertyRequirednessFollowsLastDeclaration() throws {
        let relaxed = JSONSchema.object(
            .required("path", .string()),
            .optional("path", .string(description: "now optional"))
        )
        #expect(relaxed.required.isEmpty)
        #expect(try encoded(relaxed).contains(#""required""#) == false)

        let tightened = JSONSchema.object(
            .optional("path", .string()),
            .required("path", .string())
        )
        #expect(tightened.required == ["path"])

        // A name keeps the position of its first declaration, so overriding one
        // property does not reshuffle `required`.
        let reordered = JSONSchema.object(
            .required("alpha", .string()),
            .required("zulu", .string()),
            .required("alpha", .string(description: "override"))
        )
        #expect(reordered.required == ["alpha", "zulu"])
    }

    /// `JSONValue` canonicalizes an integral number to `.int`, so a `Double`-typed
    /// default of `30` would decode back as `.int(30)` and compare unequal to the
    /// schema that produced those very bytes.
    @Test("An integral number default survives its own round trip")
    func integralNumberDefaultRoundTrips() throws {
        let schema = JSONSchema.number(description: "Timeout in seconds", default: 30)
        #expect(try encoded(schema).contains(#""default":30"#))
        #expect(try decoded(encoded(schema)) == schema)
        #expect(try JSONSchema(jsonValue: schema.jsonValue) == schema)

        let fractional = JSONSchema.number(default: 30.5)
        #expect(fractional.defaultValue == .double(30.5))
        #expect(try decoded(encoded(fractional)) == fractional)
    }

    /// Decoding is recursive and so is everything downstream of it. Foundation's
    /// own 512-level guard is calibrated for the main thread's 8 MB stack; on a
    /// concurrency thread's 512 KB one, a schema nested past roughly 140 levels
    /// overflowed the stack and killed the process before that guard was reached.
    /// Tool schemas come from extensions and MCP servers, so that is untrusted
    /// input crashing the agent.
    @Test("A schema nested past the depth limit is rejected, not fatal")
    func excessiveNestingIsRejected() throws {
        func nested(_ depth: Int) -> String {
            String(repeating: #"{"items":"#, count: depth) + "{}"
                + String(repeating: "}", count: depth)
        }

        #expect(throws: DecodingError.self) { try decoded(nested(300)) }
        #expect(throws: DecodingError.self) {
            try decoded(nested(JSONSchema.maximumNestingDepth + 1))
        }
        // The limit itself still decodes, and re-encodes to the same bytes.
        let atLimit = nested(JSONSchema.maximumNestingDepth)
        #expect(try encoded(decoded(atLimit)) == atLimit)
    }

    @Test("Properties assembled at runtime take the array overload")
    func runtimeAssembledProperties() {
        let names = ["a", "b"]
        let schema = JSONSchema.object(
            properties: names.map { .optional($0, .boolean()) },
            additionalProperties: .denied
        )
        #expect(schema.properties?.keys.sorted() == names)
        #expect(schema.required.isEmpty)
        #expect(schema.additionalProperties == .denied)
    }

    // MARK: - pi's built-in tools

    /// The exact bytes pi's `read` tool puts on the wire, transcribed from
    /// `packages/coding-agent/src/core/tools/read.ts`.
    @Test("The read tool schema matches upstream")
    func readToolBytes() throws {
        let expected = """
            {"properties":{\
            "limit":{"description":"Maximum number of lines to read","type":"number"},\
            "offset":{"description":"Line number to start reading from (1-indexed)","type":"number"},\
            "path":{"description":"Path to the file to read (relative or absolute)","type":"string"}\
            },"required":["path"],"type":"object"}
            """
        #expect(try encoded(Fixtures.read) == expected)
    }

    @Test("The edit tool schema nests an array of objects")
    func editToolBytes() throws {
        let expected = """
            {"properties":{\
            "edits":{"description":"One or more targeted replacements.",\
            "items":{"properties":{\
            "newText":{"description":"Replacement text for this targeted edit.","type":"string"},\
            "oldText":{"description":"Exact text for one targeted replacement.","type":"string"}\
            },"required":["oldText","newText"],"type":"object"},"type":"array"},\
            "path":{"description":"Path to the file to edit (relative or absolute)","type":"string"}\
            },"required":["path","edits"],"type":"object"}
            """
        #expect(try encoded(Fixtures.edit) == expected)
    }

    @Test("Every built-in tool schema round-trips through Codable")
    func allToolSchemasRoundTrip() throws {
        for schema in Fixtures.allTools {
            #expect(try decoded(encoded(schema)) == schema)
        }
    }
}

// MARK: - Fixtures

/// The parameter schemas of pi's seven built-in tools, transcribed from
/// `packages/coding-agent/src/core/tools/*.ts`. Descriptions are shortened where
/// only the shape is under test.
private enum Fixtures {
    static let read = JSONSchema.object(
        .required("path", .string(description: "Path to the file to read (relative or absolute)")),
        .optional("offset", .number(description: "Line number to start reading from (1-indexed)")),
        .optional("limit", .number(description: "Maximum number of lines to read"))
    )

    static let edit = JSONSchema.object(
        .required("path", .string(description: "Path to the file to edit (relative or absolute)")),
        .required(
            "edits",
            .array(
                of: .object(
                    .required(
                        "oldText", .string(description: "Exact text for one targeted replacement.")),
                    .required(
                        "newText", .string(description: "Replacement text for this targeted edit."))
                ),
                description: "One or more targeted replacements."
            ))
    )

    static let bash = JSONSchema.object(
        .required("command", .string(description: "Bash command to execute")),
        .optional("timeout", .number(description: "Timeout in seconds"))
    )

    static let write = JSONSchema.object(
        .required("path", .string(description: "Path to the file to write")),
        .required("content", .string(description: "Content to write to the file"))
    )

    static let ls = JSONSchema.object(
        .optional("path", .string(description: "Directory to list (default: current directory)")),
        .optional("limit", .number(description: "Maximum number of entries to return"))
    )

    static let find = JSONSchema.object(
        .required("pattern", .string(description: "Glob pattern to match")),
        .optional("path", .string(description: "Directory to search in")),
        .optional("limit", .number(description: "Maximum number of results"))
    )

    static let grep = JSONSchema.object(
        .required("pattern", .string(description: "Search pattern (regex or literal string)")),
        .optional("path", .string(description: "Directory or file to search")),
        .optional("glob", .string(description: "Filter files by glob pattern")),
        .optional("ignoreCase", .boolean(description: "Case-insensitive search")),
        .optional("literal", .boolean(description: "Treat pattern as a literal string")),
        .optional("context", .number(description: "Lines of context around each match")),
        .optional("limit", .number(description: "Maximum number of matches to return"))
    )

    static let allTools: [JSONSchema] = [read, edit, bash, write, ls, find, grep]
}
