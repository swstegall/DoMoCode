// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Synchronization

/// Late-bound bridge from a tool context to the server session that owns it.
///
/// Tool contexts are assembled before a session id exists, while a server may
/// host several sessions at once. The CLI installs a per-session tool context
/// handler that calls this broker; `ServerRuntime` installs the handler that
/// parks the matching session and broadcasts its wire request.
public final class QuestionBroker: Sendable {
    public typealias Handler = @Sendable (
        _ sessionID: String,
        _ questions: [ServerQuestionPrompt]
    ) async -> [ServerQuestionAnswer]?

    private let handler = Mutex<Handler?>(nil)

    public init() {}

    /// Replace the late-bound owner. Passing `nil` makes the broker fail closed,
    /// which is the safe behavior during server teardown or in a headless host.
    public func setHandler(_ newHandler: Handler?) {
        handler.withLock { $0 = newHandler }
    }

    public func ask(
        sessionID: String,
        questions: [ServerQuestionPrompt]
    ) async -> [ServerQuestionAnswer]? {
        let current = handler.withLock { $0 }
        return await current?(sessionID, questions)
    }
}
