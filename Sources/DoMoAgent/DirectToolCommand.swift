// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation

/// A slash command that has been resolved against the live tool schema.
public struct ParsedDirectToolCommand: Sendable, Hashable {
    public let name: String
    public let arguments: JSONValue

    public init(name: String, arguments: JSONValue) {
        self.name = name
        self.arguments = arguments
    }
}

/// Converts a prompt such as /read foo.txt into the object-shaped arguments
/// expected by the selected tool. The live schema remains authoritative: quoted
/// paths, named flags, numbers, booleans, and an explicit JSON object all use the
/// same path the model-facing tool call uses.
public enum DirectToolCommandParser {
    public static func parse(
        _ command: String,
        tools: [any AgentTool]
    ) throws(DoMoError) -> ParsedDirectToolCommand {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else {
            throw invalid(tool: "command", reason: "a direct tool command must start with /")
        }

        let rest = String(trimmed.dropFirst())
        guard let boundary = rest.firstIndex(where: \.isWhitespace) else {
            return try resolve(name: rest, argumentText: "", tools: tools)
        }
        let name = String(rest[..<boundary])
        let arguments = String(rest[rest.index(after: boundary)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try resolve(name: name, argumentText: arguments, tools: tools)
    }

    private static func resolve(
        name: String,
        argumentText: String,
        tools: [any AgentTool]
    ) throws(DoMoError) -> ParsedDirectToolCommand {
        guard !name.isEmpty else {
            throw invalid(tool: "command", reason: "the tool name is empty")
        }
        guard let tool = tools.first(where: { $0.definition.name == name }) else {
            throw invalid(tool: name, reason: "tool is not available in the current session")
        }
        let arguments = try arguments(for: argumentText, schema: tool.definition.parameters, tool: name)
        return ParsedDirectToolCommand(name: name, arguments: arguments)
    }

    private static func arguments(
        for text: String,
        schema: JSONSchema,
        tool: String
    ) throws(DoMoError) -> JSONValue {
        guard !text.isEmpty else { return .object([:]) }
        if text.first == "{" || text.first == "[" {
            guard let parsed = try? JSONValue(parsing: text),
                  case .object = parsed
            else {
                throw invalid(tool: tool, reason: "JSON arguments must be an object")
            }
            return parsed
        }

        guard let tokens = DroppedPaths.tokenize(text) else {
            throw invalid(tool: tool, reason: "arguments contain an unfinished quote or escape")
        }
        let properties = schema.properties ?? [:]
        let orderedNames = schema.required + properties.keys.filter { !schema.required.contains($0) }.sorted()
        var output: [String: JSONValue] = [:]
        var positionalIndex = 0
        var tokenIndex = 0
        var positionalOnly = false

        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex]
            tokenIndex += 1
            if token == "--" {
                positionalOnly = true
                continue
            }
            if !positionalOnly, token.hasPrefix("--"), token.count > 2 {
                let assignment = parseFlag(String(token.dropFirst(2)))
                let key = canonicalProperty(assignment.key, properties: properties)
                guard let propertySchema = properties[key] else {
                    throw invalid(tool: tool, reason: "unknown argument --\(assignment.key)")
                }
                let value: String
                if let inline = assignment.inlineValue {
                    value = inline
                } else if propertyIsBoolean(propertySchema) && (tokenIndex == tokens.count || tokens[tokenIndex].hasPrefix("--")) {
                    output[key] = .bool(true)
                    continue
                } else {
                    guard tokenIndex < tokens.count else {
                        throw invalid(tool: tool, reason: "missing value for --\(assignment.key)")
                    }
                    value = tokens[tokenIndex]
                    tokenIndex += 1
                }
                output[key] = try convert(value, schema: propertySchema, tool: tool, property: key)
                continue
            }

            if !positionalOnly, let equals = token.firstIndex(of: "=") {
                let candidate = String(token[..<equals])
                let key = canonicalProperty(candidate, properties: properties)
                if let propertySchema = properties[key] {
                    let value = String(token[token.index(after: equals)...])
                    output[key] = try convert(value, schema: propertySchema, tool: tool, property: key)
                    continue
                }
            }

            guard positionalIndex < orderedNames.count else {
                throw invalid(tool: tool, reason: "too many positional arguments")
            }
            let key = orderedNames[positionalIndex]
            positionalIndex += 1
            guard let propertySchema = properties[key] else { continue }
            output[key] = try convert(token, schema: propertySchema, tool: tool, property: key)
        }
        return .object(output)
    }

    private static func parseFlag(_ raw: String) -> (key: String, inlineValue: String?) {
        guard let equals = raw.firstIndex(of: "=") else {
            return (raw, nil)
        }
        return (
            String(raw[..<equals]),
            String(raw[raw.index(after: equals)...])
        )
    }

    private static func canonicalProperty(_ candidate: String, properties: [String: JSONSchema]) -> String {
        if properties[candidate] != nil { return candidate }
        let underscored = candidate.replacingOccurrences(of: "-", with: "_")
        return properties[underscored] == nil ? candidate : underscored
    }

    private static func propertyIsBoolean(_ schema: JSONSchema) -> Bool {
        guard case .single(let type) = schema.type else { return false }
        return type == .boolean
    }

    private static func convert(
        _ value: String,
        schema: JSONSchema,
        tool: String,
        property: String
    ) throws(DoMoError) -> JSONValue {
        let primitive: JSONSchema.PrimitiveType?
        switch schema.type {
        case .single(let type): primitive = type
        case .union(let types): primitive = types.first { $0 != .null }
        case nil: primitive = nil
        }
        switch primitive {
        case .boolean:
            switch value.lowercased() {
            case "true", "yes", "on", "1": return .bool(true)
            case "false", "no", "off", "0": return .bool(false)
            default: break
            }
        case .integer:
            if let integer = Int(value) { return .int(integer) }
        case .number:
            if let integer = Int(value) { return .int(integer) }
            if let number = Double(value) { return .double(number) }
        case .array:
            if let parsed = try? JSONValue(parsing: value), case .array = parsed { return parsed }
        case .object:
            if let parsed = try? JSONValue(parsing: value), case .object = parsed { return parsed }
        case .null:
            if value.lowercased() == "null" { return .null }
        case .string, nil:
            return .string(value)
        }
        throw invalid(tool: tool, reason: "\(property) has an invalid value")
    }

    private static func invalid(tool: String, reason: String) -> DoMoError {
        DoMoError(.toolExecution(tool: tool), "Direct command /\(tool): \(reason)")
    }
}

/// The result of one tool selected directly from the client catalog.
public struct DirectToolInvocation: Sendable {
    public let toolName: String
    public let result: AgentToolResult

    public init(toolName: String, result: AgentToolResult) {
        self.toolName = toolName
        self.result = result
    }
}
