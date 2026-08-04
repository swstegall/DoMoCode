// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The bridge from an MCP server tool to an `AgentTool` the loop can dispatch. Unlike
// the built-in tools, an McpTool runs no local code — `execute` issues a `tools/call`
// over the server's stdio and maps the result: text blocks become the model-visible
// output, image blocks become `ImageBlock`s, and a tool-execution error (`isError`) is
// returned as an error result, never thrown (only a cancellation throws). Names are
// namespaced by server so they can't collide with the built-ins.

import DoMoAgent
import DoMoCore
import DoMoLLM
import Foundation

struct McpTool: AgentTool {
    private let client: MCPClient
    private let rawName: String
    private let namespacedName: String
    private let serverName: String
    private let toolDescription: String
    private let parameters: JSONSchema
    private let adapterKind: MCPAdapterKind?
    private let transport: MCPTransport

    /// `nameOverride` lets the manager substitute a de-collided name when two servers'
    /// tools namespace to the same string (otherwise the default `namespaced` name is used).
    /// `parameters` is the pre-validated schema (see ``makeParameters``) — the manager
    /// builds it first so it can DROP a tool whose schema won't convert rather than
    /// advertise a misleading parameterless tool.
    init(
        client: MCPClient,
        serverName: String,
        info: MCPClient.ToolInfo,
        nameOverride: String? = nil,
        parameters: JSONSchema,
        adapterKind: MCPAdapterKind? = nil,
        transport: MCPTransport = .stdio
    ) {
        self.client = client
        self.rawName = info.name
        self.namespacedName = nameOverride ?? McpTool.namespaced(server: serverName, tool: info.name)
        self.serverName = serverName
        self.toolDescription = info.description
        self.parameters = parameters
        self.adapterKind = adapterKind
        self.transport = transport
    }

    /// Convert an MCP tool's (untrusted) input schema into a `JSONSchema`. Throws when the
    /// schema can't convert (an unknown type keyword, nesting past the depth cap, etc.) so
    /// the manager can skip the tool with a log line instead of the old silent fallback to
    /// an empty object schema — which advertised a real tool as taking no arguments and
    /// guaranteed the model would call it wrong.
    static func makeParameters(_ inputSchema: JSONValue) throws -> JSONSchema {
        try JSONSchema(jsonValue: normalizeSchema(inputSchema))
    }

    var definition: ToolDefinition {
        ToolDefinition(name: namespacedName, description: toolDescription, parameters: parameters)
    }

    var catalogSource: ToolCatalogSource { adapterKind == nil ? .mcp : .adapter }

    var catalogMetadata: [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "mcpServer": .string(serverName),
            "mcpTransport": .string(transport.rawValue),
        ]
        if let adapterKind {
            metadata["adapterKind"] = .string(adapterKind.rawValue)
        }
        return metadata
    }

    func execute(_ arguments: JSONValue) async throws(DoMoError) -> AgentToolResult {
        let result: MCPClient.CallResult
        do {
            result = try await client.callTool(name: rawName, arguments: arguments)
        } catch is CancellationError {
            throw DoMoError(.cancelled, "The MCP tool call was aborted.")
        } catch {
            // Transport/protocol failure (server crashed, unknown tool, timeout) — a
            // model-visible error, so it can adapt, not a throw.
            return AgentToolResult(output: "MCP tool \(namespacedName) failed: \(error)", isError: true)
        }
        return McpTool.mapResult(result)
    }

    // MARK: Mapping

    /// Map an MCP `CallToolResult` into an `AgentToolResult`: concatenate text blocks,
    /// decode image blocks, placeholder the rest; fall back to `structuredContent`.
    static func mapResult(_ result: MCPClient.CallResult) -> AgentToolResult {
        var texts: [String] = []
        var images: [ImageBlock] = []
        for block in result.content {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue { texts.append(text) }
            case "image":
                if let base64 = block["data"]?.stringValue,
                   let mimeType = block["mimeType"]?.stringValue,
                   let data = Data(base64Encoded: base64) {
                    images.append(ImageBlock(mediaType: mimeType, data: data))
                }
            case let other?:
                texts.append("[\(other) content]")   // resource/resource_link/audio — placeholder
            case nil:
                break
            }
        }
        var output = texts.joined(separator: "\n\n")
        // Content-less result with structured output: synthesize a JSON text block.
        if output.isEmpty, images.isEmpty, let structured = result.structuredContent, !structured.isNull {
            output = (try? structured.encodedString()) ?? ""
        }
        if result.isError, output.isEmpty { output = "The MCP tool returned an error." }
        return AgentToolResult(output: output, isError: result.isError, images: images)
    }

    // MARK: Naming

    /// `sanitize(server)_sanitize(tool)` — keeps `[A-Za-z0-9_-]`, everything else `_`,
    /// so a tool name is always a valid function name and never collides with a built-in.
    static func namespaced(server: String, tool: String) -> String {
        sanitize(server) + "_" + sanitize(tool)
    }

    static func sanitize(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-": result.unicodeScalars.append(scalar)
            default: result.append("_")
            }
        }
        return result
    }

    /// Force `type:"object"` and default `properties:{}` so the model always sees a
    /// well-formed object schema. `additionalProperties:false` is defaulted only when the
    /// server didn't specify it — a server that legitimately declares a free-form map
    /// (`additionalProperties: true` or a schema) keeps its own contract, otherwise the
    /// model would be shown a schema that forbids the very keys the tool requires.
    static func normalizeSchema(_ schema: JSONValue) -> JSONValue {
        var object = schema.objectValue ?? [:]
        object["type"] = .string("object")
        if object["properties"] == nil { object["properties"] = .object([:]) }
        if object["additionalProperties"] == nil { object["additionalProperties"] = .bool(false) }
        return .object(object)
    }
}
