import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

@Suite("bash")
struct BashToolTests {

    @Test("runs a command and returns stdout")
    func stdout() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(["command": "echo hello"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == "hello\n")
        #expect(result.details["exitCode"]?.intValue == 0)
    }

    @Test("runs in the sandbox root")
    func runsInRoot() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("marker.txt", "x")

        let result = try await BashTool().execute(["command": "ls"], in: fixture.context)
        #expect(result.text.contains("marker.txt"))
    }

    @Test("captures stderr")
    func stderr() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(
            ["command": "echo oops 1>&2"], in: fixture.context)
        #expect(result.text.contains("oops"))
    }

    @Test("a non-zero exit is an error result with the code")
    func nonZeroExit() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(["command": "exit 3"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Command exited with code 3"))
        #expect(result.details["exitCode"]?.intValue == 3)
    }

    @Test("no output yields a placeholder")
    func noOutput() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(["command": "true"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == "(no output)")
    }

    @Test("a timeout terminates the command and is reported")
    func timeout() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(
            ["command": "sleep 10", "timeout": 1], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("timed out after 1 seconds"))
        #expect(result.details["timedOut"]?.boolValue == true)
    }

    @Test("an invalid timeout is rejected before running")
    func invalidTimeout() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(
            ["command": "echo hi", "timeout": 0], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Invalid timeout"))
    }

    @Test("shell features like pipes work")
    func pipes() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(
            ["command": "printf 'a\\nb\\nc\\n' | grep b"], in: fixture.context)
        #expect(result.text == "b\n")
    }
}
