// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A late-bound question handler. Interactive surfaces build their tool context
// before their coordinator owns a terminal, so the UI callback is installed once
// the surface is ready. Until then, a question is cancelled rather than parked
// forever — the same fail-closed rule as the permission prompter.

import Synchronization

/// Holds the interactive surface's ``QuestionHandler``.
public final class QuestionBox: Sendable {
    private let stored = Mutex<QuestionHandler?>(nil)

    public init() {}

    /// Install the handler once the surface's input and renderer exist.
    public func set(_ handler: @escaping QuestionHandler) {
        stored.withLock { $0 = handler }
    }

    /// Forward a question batch, or cancel it when no surface is listening.
    public func ask(_ questions: [QuestionPrompt]) async -> [QuestionAnswer]? {
        guard let handler = stored.withLock({ $0 }) else { return nil }
        return await handler(questions)
    }
}
