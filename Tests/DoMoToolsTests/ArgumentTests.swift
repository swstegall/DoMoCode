import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

/// A bad argument must become an error result the model can read and correct —
/// never a thrown Swift error that ends the turn.
@Suite("argument decoding")
struct ArgumentTests {

    @Test("a missing required field is an error result, not a throw")
    func missingRequired() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await ReadTool().execute([:], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("missing required string argument"))
    }

    @Test("a wrong-typed field is an error result")
    func wrongType() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await ReadTool().execute(["path": 42], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("path must be a string"))
    }

    @Test("arguments that are not an object are an error result")
    func notAnObject() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await ReadTool().execute(.array([.string("path")]), in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("must be a JSON object"))
    }

    @Test("extra unknown fields are ignored")
    func extraFieldsIgnored() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "hi")

        let args: JSONValue = .object([
            "path": .string("a.txt"),
            "unexpected": .int(1),
            "another": .bool(true),
        ])
        let result = try await ReadTool().execute(args, in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == "hi")
    }

    @Test("a numeric field sent as a string is coerced")
    func numericStringCoerced() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("f.txt", (1...10).map { "line \($0)" }.joined(separator: "\n"))

        let result = try await ReadTool().execute(
            ["path": "f.txt", "offset": "5", "limit": "2"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("line 5\nline 6"))
    }

    @Test("a boolean field sent as a string is coerced")
    func boolStringCoerced() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "Hello\n")

        let result = try await GrepTool().execute(
            ["pattern": "hello", "ignoreCase": "true"], in: fixture.context)
        #expect(result.text.contains("a.txt:1: Hello"))
    }

    @Test("a non-numeric timeout is an error the model can correct")
    func badTimeout() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await BashTool().execute(
            ["command": "echo hi", "timeout": "soon"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("timeout must be a number"))
    }

    @Test("edit with no edits is an error result")
    func editNoEdits() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "x")

        let result = try await EditTool().execute(["path": "a.txt"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("must contain at least one replacement"))
    }
}
