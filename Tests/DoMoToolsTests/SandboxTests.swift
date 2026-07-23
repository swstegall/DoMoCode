import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

@Suite("sandbox")
struct SandboxTests {

    @Test("reading an absolute path outside the root is refused")
    func readAbsoluteOutside() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let outside = try makeOutsideFile("secret.txt", "top secret")

        let result = try await ReadTool().execute(["path": .string(outside)], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("outside"))
    }

    @Test("writing above the root via .. is refused")
    func writeParentEscape() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await WriteTool().execute(
            ["path": "../escaped.txt", "content": "nope"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("outside"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.string + "/../escaped.txt"))
    }

    @Test("a symlink pointing outside the root is refused when read through")
    func symlinkEscape() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let outside = try makeOutsideFile("target.txt", "escaped content")
        try fixture.symlink("link", to: outside)

        let result = try await ReadTool().execute(["path": "link"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("outside"))
    }

    @Test("ls of the parent directory is refused")
    func lsParentEscape() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await LsTool().execute(["path": ".."], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("outside"))
    }

    @Test("grep of an absolute outside path is refused")
    func grepOutsideEscape() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        let outsideDir = (try makeOutsideFile("x.txt", "findme") as NSString).deletingLastPathComponent

        let result = try await GrepTool().execute(
            ["pattern": "findme", "path": .string(outsideDir)], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("outside"))
    }

    @Test("a legitimate .. that stays inside the root is allowed")
    func innerDotDotAllowed() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("top.txt", "at the top")
        try fixture.makeDirectory("sub")

        let result = try await ReadTool().execute(["path": "sub/../top.txt"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == "at the top")
    }
}
