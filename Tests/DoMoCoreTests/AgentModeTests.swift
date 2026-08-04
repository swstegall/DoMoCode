// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@Suite("agent modes")
struct AgentModeTests {
    @Test("the interactive mode cycle covers every policy and wraps")
    func modeCycle() {
        let cycle = Array(
            sequence(first: AgentMode.build) { mode in
                mode == .review ? nil : mode.next
            }
        )

        #expect(cycle == [.build, .plan, .ask, .debug, .review])
        #expect(AgentMode.review.next == .build)
        #expect(Set(cycle) == Set(AgentMode.allCases))
    }
}
