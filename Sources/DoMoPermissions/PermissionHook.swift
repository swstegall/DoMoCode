// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The seam between the pure agent loop and the permission engine. Builds the
// `BeforeToolCallHook` the loop already awaits (in `ToolDispatch.prepare`, before any
// side effect): each call becomes a spec, the engine decides, and an `allow` proceeds
// while a `deny` rejects with a model-visible reason. One hook covers every surface —
// the surface only differs in the prompter the engine was built with.

import DoMoAgent
import DoMoCore

/// A `BeforeToolCallHook` that gates every tool call through `engine`.
public func permissionHook(
    engine: PermissionEngine,
    factory: PermissionRequestFactory,
    sessionID: String
) -> BeforeToolCallHook {
    { context in
        // The loop re-checks cancellation after the hook returns, but bailing here
        // avoids prompting for a call that is already being aborted.
        if Task.isCancelled { return .reject("The tool call was aborted.") }
        for spec in factory.makeAll(toolName: context.toolCall.name, arguments: context.arguments) {
            switch await engine.ask(spec, sessionID: sessionID) {
            case .allow:
                continue
            case .deny(let reason):
                return .reject(reason)
            }
        }
        return .proceed
    }
}

/// A no-progress hook backed by the same permission engine as tool calls.
///
/// The agent loop deliberately knows nothing about permission policy. When its
/// repeated-work guard fires, this hook presents the repeated tool names under
/// the reserved `doom_loop` permission and returns whether the run may have
/// another guard window.
public func doomLoopHook(
    engine: PermissionEngine,
    sessionID: String
) -> @Sendable (TurnResult) async -> Bool {
    { turn in
        let toolCalls = turn.message.toolCalls
        guard !toolCalls.isEmpty else { return false }

        var names: [String] = []
        for call in toolCalls where !names.contains(call.name) {
            names.append(call.name)
        }
        let first = toolCalls[0]
        let spec = PermissionRequestSpec(
            permission: "doom_loop",
            patterns: names,
            always: names,
            metadata: [
                "tool": .string(first.name),
                "input": first.arguments,
            ]
        )
        if case .allow = await engine.ask(spec, sessionID: sessionID) {
            return true
        }
        return false
    }
}
