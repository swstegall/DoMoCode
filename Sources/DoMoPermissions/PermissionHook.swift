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
        let spec = factory.make(toolName: context.toolCall.name, arguments: context.arguments)
        switch await engine.ask(spec, sessionID: sessionID) {
        case .allow:
            return .proceed
        case .deny(let reason):
            return .reject(reason)
        }
    }
}
