// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import ArgumentParser
import Testing
@testable import DoMoCLI

@Suite("Mini mode")
struct MiniModeTests {
    @Test("The root command exposes the split-footer selector")
    func parsesMiniMode() throws {
        let command = try DoMoCodeCommand.parse(["--mini"])
        #expect(command.mini)
        #expect(!command.inline)
    }
}
