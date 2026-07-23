import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

/// Exercises the `rg`/`fd` shell-out paths with stub executables that emit the
/// real tools' output formats, so the code is covered even where the binaries
/// are not installed.
@Suite("external tool shell-out")
struct ExternalToolTests {

    @Test("grep parses ripgrep --json output and relativizes paths")
    func ripgrepJSON() async throws {
        // Emits two ripgrep match records rooted at the search path (its last arg).
        let script = """
            #!/bin/bash
            searchpath="${@: -1}"
            printf '{"type":"begin","data":{"path":{"text":"%s/a.txt"}}}\\n' "$searchpath"
            printf '{"type":"match","data":{"path":{"text":"%s/a.txt"},"line_number":1,"lines":{"text":"needle here"}}}\\n' "$searchpath"
            printf '{"type":"match","data":{"path":{"text":"%s/sub/b.txt"},"line_number":3,"lines":{"text":"another needle"}}}\\n' "$searchpath"
            exit 0
            """
        let locator = try fakeToolLocator(["rg": script])
        let fixture = try await ToolFixture.make(toolLocator: locator)
        defer { fixture.removeCleanup() }

        let result = try await GrepTool().execute(["pattern": "needle"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.contains("a.txt:1: needle here"))
        #expect(result.text.contains("sub/b.txt:3: another needle"))
    }

    @Test("grep surfaces a ripgrep hard error")
    func ripgrepError() async throws {
        let script = """
            #!/bin/bash
            echo 'regex parse error' 1>&2
            exit 2
            """
        let locator = try fakeToolLocator(["rg": script])
        let fixture = try await ToolFixture.make(toolLocator: locator)
        defer { fixture.removeCleanup() }

        let result = try await GrepTool().execute(["pattern": "("], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("regex parse error"))
    }

    @Test("grep honors the match limit against ripgrep output")
    func ripgrepLimit() async throws {
        let script = """
            #!/bin/bash
            searchpath="${@: -1}"
            for i in $(seq 1 10); do
              printf '{"type":"match","data":{"path":{"text":"%s/f.txt"},"line_number":%s,"lines":{"text":"hit"}}}\\n' "$searchpath" "$i"
            done
            exit 0
            """
        let locator = try fakeToolLocator(["rg": script])
        let fixture = try await ToolFixture.make(toolLocator: locator)
        defer { fixture.removeCleanup() }

        let result = try await GrepTool().execute(["pattern": "hit", "limit": 3], in: fixture.context)
        #expect(result.text.contains("3 matches limit reached"))
        #expect(result.details["matchLimitReached"]?.intValue == 3)
    }

    @Test("find parses fd output and relativizes paths")
    func fdOutput() async throws {
        let script = """
            #!/bin/bash
            searchpath="${@: -1}"
            printf '%s/x.swift\\n%s/y/z.swift\\n' "$searchpath" "$searchpath"
            exit 0
            """
        let locator = try fakeToolLocator(["fd": script])
        let fixture = try await ToolFixture.make(toolLocator: locator)
        defer { fixture.removeCleanup() }

        let result = try await FindTool().execute(["pattern": "*.swift"], in: fixture.context)
        #expect(!result.isError)
        let lines = Set(result.text.split(separator: "\n").map(String.init))
        #expect(lines == ["x.swift", "y/z.swift"])
    }

    @Test("find surfaces an fd hard error")
    func fdError() async throws {
        let script = """
            #!/bin/bash
            echo 'fd: broken' 1>&2
            exit 1
            """
        let locator = try fakeToolLocator(["fd": script])
        let fixture = try await ToolFixture.make(toolLocator: locator)
        defer { fixture.removeCleanup() }

        let result = try await FindTool().execute(["pattern": "*.swift"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("fd: broken"))
    }
}
