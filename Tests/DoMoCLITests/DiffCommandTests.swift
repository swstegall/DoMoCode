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

    @Test("export content options reach the subcommand")
    func parsesExportOptions() throws {
        let command = try ExportCommand.parse([
            "session.jsonl",
            "--html",
            "--until", "entry-7",
            "--output", "transcript.html",
            "--no-reasoning",
            "--no-tools",
            "--metadata",
        ])
        #expect(command.sessionPath == "session.jsonl")
        #expect(command.html)
        #expect(command.until == "entry-7")
        #expect(command.outputPath == "transcript.html")
        #expect(command.noReasoning)
        #expect(command.noTools)
        #expect(command.metadata)
    }

}
