// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoCore

/// Errors from the role adapter are transport/configuration failures. They do
/// not imply that the host's permission decision was granted.
public enum MCPExternalCapabilityAdapterError: Error, Sendable, Equatable {
    case serverNotConnected(String)
    case toolNotFound(String)
}

/// An explicit browser, notebook, or remote-search view over an already
/// connected MCP server. This keeps the first-party surface small: the
/// external service owns browser automation, kernel execution, or search
/// credentials, while DoMoCode owns discovery, permissions, redaction, and
/// lifecycle.
public actor MCPExternalCapabilityAdapter: DoMoExternalCapabilityAdapter {
    public nonisolated let descriptor: AdapterDescriptor
    public nonisolated let capabilityDescriptor: ExternalCapabilityDescriptor

    private let manager: MCPManager
    private let server: String

    public init(
        manager: MCPManager,
        descriptor: ExternalCapabilityDescriptor,
        server: String
    ) {
        self.manager = manager
        self.capabilityDescriptor = descriptor
        self.server = server
        self.descriptor = AdapterDescriptor(
            id: descriptor.id,
            displayName: descriptor.displayName,
            capabilities: [
                "mcp",
                descriptor.transport.rawValue,
                descriptor.kind.rawValue,
            ]
        )
    }

    /// The manager owns the connection. Starting an adapter view therefore
    /// verifies the selected server rather than spawning a second client.
    public func start() async throws {
        guard await manager.isConnected(server: server) else {
            throw MCPExternalCapabilityAdapterError.serverNotConnected(server)
        }
    }

    /// Stopping a view must not tear down sibling adapters. The run owner calls
    /// `MCPManager.shutdown()` once for the shared transport lifecycle.
    public func stop() async {}

    public func catalogEntries(for context: ToolCatalogContext) async throws -> [ToolCatalogEntry] {
        try await start()
        let tools = await manager.tools(server: server)
        return tools.map { tool in
            var metadata = tool.catalogMetadata
            metadata["adapterID"] = .string(capabilityDescriptor.id)
            metadata["capabilityKind"] = .string(capabilityDescriptor.kind.rawValue)
            metadata["transport"] = .string(capabilityDescriptor.transport.rawValue)
            if let sessionID = context.sessionID {
                metadata["sessionID"] = .string(sessionID)
            }
            return ToolCatalogEntry(
                name: tool.definition.name,
                description: tool.definition.description,
                source: .adapter,
                inputSchema: tool.definition.parameters.jsonValue,
                permission: .requiresApproval,
                metadata: metadata
            )
        }
    }

    public func execute(toolNamed name: String, arguments: JSONValue) async throws -> JSONValue {
        try await start()
        guard let tool = await manager.tools(server: server).first(where: {
            $0.definition.name == name
        }) else {
            throw MCPExternalCapabilityAdapterError.toolNotFound(name)
        }
        let result = try await tool.execute(arguments)
        var value: [String: JSONValue] = [
            "output": .string(result.output),
            "isError": .bool(result.isError),
            "terminate": .bool(result.terminate),
        ]
        if !result.details.isNull { value["details"] = result.details }
        return .object(value)
    }
}
