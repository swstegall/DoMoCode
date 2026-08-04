// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoMCP
import DoMoHarness
import DoMoTools

/// Adapts the actor-owned MCP manager to the dependency-neutral DoMoTools seam.
/// Keeping this bridge in the CLI target avoids a DoMoTools -> DoMoMCP cycle and
/// gives server, interactive, and print surfaces one identical policy path.
func makeMCPResourceProvider(_ manager: MCPManager) -> MCPResourceProvider {
    { query in
        switch query.action {
        case .list:
            let resources = await manager.resources(server: query.server)
            return .resources(resources.map { resource in
                MCPResourceDescriptor(
                    server: resource.server,
                    uri: resource.uri,
                    name: resource.name,
                    description: resource.description,
                    mimeType: resource.mimeType
                )
            })
        case .templates:
            let templates = await manager.resourceTemplates(server: query.server)
            return .templates(templates.map { template in
                MCPResourceTemplateDescriptor(
                    server: template.server,
                    uriTemplate: template.uriTemplate,
                    name: template.name,
                    description: template.description,
                    mimeType: template.mimeType
                )
            })
        case .read:
            guard let server = query.server, let uri = query.uri else {
                throw MCPManager.MCPManagerError.serverNotConnected("read requires a server and URI")
            }
            let resource = try await manager.readResource(server: server, uri: uri)
            return .contents(
                MCPResourceContents(
                    server: resource.server,
                    uri: resource.uri,
                    contents: resource.contents
                )
            )
        case .health:
            let health = await manager.health(server: query.server)
            return .health(health.map { MCPServerHealth(server: $0.server, healthy: $0.healthy) })
        }
    }
}

/// Captures only the inert skill values from a trusted prompt workspace. The
/// provider does not reread arbitrary paths or execute a resource.
func makeSkillProvider(_ workspace: PromptWorkspace) -> SkillProvider {
    let skills = workspace.skills.map { skill in
        TrustedSkillResource(
            name: skill.name,
            description: skill.description,
            body: skill.body,
            source: skill.source.rawValue
        )
    }
    return { requestedName in
        skills.first {
            $0.name.caseInsensitiveCompare(requestedName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }
}
