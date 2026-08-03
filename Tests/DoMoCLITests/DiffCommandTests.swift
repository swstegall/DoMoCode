// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCLI
import Testing

@Suite("Diff command")
struct DiffCommandTests {
    @Test("the JSON flag reaches the subcommand")
    func parsesJSONFlag() throws {
        let command = try DiffCommand.parse(["--json"])
        #expect(command.json)
        #expect(!command.noUntracked)
    }

}
