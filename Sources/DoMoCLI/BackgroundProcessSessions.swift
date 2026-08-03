// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoExec
import DoMoTools

struct ServerSessionResources: Sendable {
    let todoStore: TodoStore
    let backgroundProcesses: BackgroundProcessManager
}

/// Owns one background-process manager per live server session. The tool context
/// is assembled before a session id is known, so the CLI keeps this small actor as
/// the late-bound resource scope and tears every manager down with the runtime.
actor BackgroundProcessSessions {
    private let sandbox: ProcessSandbox?
    private var resourcesBySession: [String: ServerSessionResources] = [:]

    init(sandbox: ProcessSandbox? = nil) {
        self.sandbox = sandbox
    }

    func resources(for sessionID: String) -> ServerSessionResources {
        if let existing = resourcesBySession[sessionID] { return existing }
        let resources = ServerSessionResources(
            todoStore: TodoStore(),
            backgroundProcesses: BackgroundProcessManager(sandbox: sandbox)
        )
        resourcesBySession[sessionID] = resources
        return resources
    }

    func shutdown() async {
        let current = Array(resourcesBySession.values)
        resourcesBySession.removeAll()
        for resource in current { await resource.backgroundProcesses.shutdown() }
    }
}
