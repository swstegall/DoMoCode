import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

@Suite("read")
struct ReadToolTests {

    @Test("reads a whole file")
    func readWhole() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("hello.txt", "line one\nline two\nline three\n")

        let result = try await ReadTool().execute(["path": "hello.txt"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == "line one\nline two\nline three\n")
    }

    @Test("offset and limit select a line window and report continuation")
    func offsetLimit() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("f.txt", (1...10).map { "line \($0)" }.joined(separator: "\n"))

        let result = try await ReadTool().execute(
            ["path": "f.txt", "offset": 3, "limit": 2], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("line 3\nline 4"))
        #expect(result.text.contains("more lines in file. Use offset=5 to continue."))
    }

    @Test("offset beyond end of file is an error")
    func offsetBeyondEnd() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("f.txt", "only one line\n")

        let result = try await ReadTool().execute(["path": "f.txt", "offset": 99], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("beyond end of file"))
    }

    @Test("a huge file truncates at the line limit with a continuation notice")
    func hugeFileTruncates() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        let content = (1...3000).map { "line \($0)" }.joined(separator: "\n")
        try fixture.write("big.txt", content)

        let result = try await ReadTool().execute(["path": "big.txt"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.contains("Showing lines 1-2000 of 3000"))
        #expect(result.text.contains("Use offset=2001 to continue."))
        // Structured truncation metadata for the renderer.
        #expect(result.details["truncated"]?.boolValue == true)
        #expect(result.details["totalLines"]?.intValue == 3000)
    }

    @Test("a byte-heavy file truncates by bytes")
    func byteTruncation() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        // 100 lines of 1000 bytes each = ~100KB, well past the 50KB budget but
        // under the 2000-line limit, so bytes win.
        let line = String(repeating: "x", count: 1000)
        try fixture.write("wide.txt", (1...100).map { _ in line }.joined(separator: "\n"))

        let result = try await ReadTool().execute(["path": "wide.txt"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.contains("50.0KB limit"))
        #expect(result.details["truncatedBy"]?.stringValue == "bytes")
    }

    @Test("a binary file is refused, not dumped")
    func binaryRefused() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.writeBytes("obj.bin", Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x02, 0x00, 0x03]))

        let result = try await ReadTool().execute(["path": "obj.bin"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("binary"))
    }

    @Test("a missing file is a clear error")
    func missingFile() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await ReadTool().execute(["path": "nope.txt"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("No such file"))
    }

    @Test("an absurd limit is clamped, not an overflow trap")
    func absurdLimitDoesNotTrap() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("f.txt", "l1\nl2\nl3\n")

        // offset >= 2 makes startLine >= 1, so a naive `startLine + limit` with
        // limit == Int.max overflows and traps the whole process. A malformed
        // model argument must be a plain result, never a crash.
        let result = try await ReadTool().execute(
            ["path": "f.txt", "offset": 2, "limit": .int(Int.max)], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("l2\nl3"))
    }

    @Test("an Int.min offset does not trap")
    func minOffsetDoesNotTrap() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("f.txt", "l1\nl2\nl3\n")

        // A negative offset resolves to the top of the file; `offset - 1` with
        // offset == Int.min must not overflow.
        let result = try await ReadTool().execute(
            ["path": "f.txt", "offset": .int(Int.min)], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("l1"))
    }
}

@Suite("write")
struct WriteToolTests {

    @Test("writes a new file and round-trips through read")
    func writeThenRead() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let written = try await WriteTool().execute(
            ["path": "sub/dir/out.txt", "content": "hello world"], in: fixture.context)
        #expect(!written.isError)
        #expect(written.text == "Successfully wrote 11 bytes to sub/dir/out.txt")

        let read = try await ReadTool().execute(["path": "sub/dir/out.txt"], in: fixture.context)
        #expect(read.text == "hello world")
    }

    @Test("overwrites an existing file")
    func overwrite() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "old")

        _ = try await WriteTool().execute(["path": "a.txt", "content": "new"], in: fixture.context)
        let read = try await ReadTool().execute(["path": "a.txt"], in: fixture.context)
        #expect(read.text == "new")
    }
}

@Suite("edit")
struct EditToolTests {

    private func editArgs(_ path: String, _ pairs: [(String, String)]) -> JSONValue {
        .object([
            "path": .string(path),
            "edits": .array(pairs.map { .object(["oldText": .string($0.0), "newText": .string($0.1)]) }),
        ])
    }

    @Test("replaces a unique block")
    func uniqueReplace() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("code.txt", "func greet() {\n    print(\"hi\")\n}\n")

        let result = try await EditTool().execute(
            editArgs("code.txt", [("print(\"hi\")", "print(\"hello\")")]), in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == "Successfully replaced 1 block(s) in code.txt.")

        let read = try await ReadTool().execute(["path": "code.txt"], in: fixture.context)
        #expect(read.text.contains("print(\"hello\")"))
    }

    @Test("applies multiple disjoint edits in one call")
    func multipleEdits() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("m.txt", "alpha\nbeta\ngamma\n")

        let result = try await EditTool().execute(
            editArgs("m.txt", [("alpha", "ALPHA"), ("gamma", "GAMMA")]), in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == "Successfully replaced 2 block(s) in m.txt.")

        let read = try await ReadTool().execute(["path": "m.txt"], in: fixture.context)
        #expect(read.text == "ALPHA\nbeta\nGAMMA\n")
    }

    @Test("an ambiguous oldText fails with an occurrence count")
    func ambiguousEdit() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("dup.txt", "foo\nfoo\nfoo\n")

        let result = try await EditTool().execute(
            editArgs("dup.txt", [("foo", "bar")]), in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Found 3 occurrences"))
        #expect(result.text.contains("must be unique"))
    }

    @Test("an absent oldText fails clearly")
    func absentEdit() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "hello\n")

        let result = try await EditTool().execute(
            editArgs("a.txt", [("goodbye", "hi")]), in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Could not find the exact text"))
    }

    @Test("overlapping edits are rejected")
    func overlappingEdits() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("o.txt", "abcdef\n")

        let result = try await EditTool().execute(
            editArgs("o.txt", [("abcd", "X"), ("cdef", "Y")]), in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("overlap"))
    }

    @Test("a no-op replacement is rejected")
    func noChange() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("n.txt", "same\n")

        let result = try await EditTool().execute(
            editArgs("n.txt", [("same", "same")]), in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("No changes made"))
    }

    @Test("an empty oldText is rejected")
    func emptyOldText() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("e.txt", "content\n")

        let result = try await EditTool().execute(
            editArgs("e.txt", [("", "x")]), in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("must not be empty"))
    }

    @Test("fuzzy match folds smart quotes and preserves untouched lines")
    func fuzzyMatch() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        // Line 1 uses curly double quotes; the model's oldText uses straight
        // quotes, so exact match misses and fuzzy match lands. Line 2 has trailing
        // spaces and is untouched — it must keep its original bytes.
        try fixture.write("fz.txt", "let a = \u{201C}x\u{201D}\nlet b = 2  \n")

        let result = try await EditTool().execute(
            editArgs("fz.txt", [("let a = \"x\"", "let a = \"y\"")]), in: fixture.context)
        #expect(!result.isError)

        let read = try await ReadTool().execute(["path": "fz.txt"], in: fixture.context)
        // The edited line is rewritten from the normalized (straight-quote) base;
        // the untouched line keeps its trailing spaces.
        #expect(read.text == "let a = \"y\"\nlet b = 2  \n")
    }

    @Test("editing a missing file reports it cannot")
    func editMissing() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await EditTool().execute(
            editArgs("missing.txt", [("a", "b")]), in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Could not edit file"))
    }

    @Test("edits sent as a JSON string are still honored")
    func editsAsJSONString() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("s.txt", "one\n")

        let args: JSONValue = .object([
            "path": .string("s.txt"),
            "edits": .string(#"[{"oldText":"one","newText":"two"}]"#),
        ])
        let result = try await EditTool().execute(args, in: fixture.context)
        #expect(!result.isError)
        let read = try await ReadTool().execute(["path": "s.txt"], in: fixture.context)
        #expect(read.text == "two\n")
    }

    @Test("legacy top-level oldText/newText is accepted")
    func legacyShape() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("l.txt", "keep\n")

        let args: JSONValue = .object([
            "path": .string("l.txt"),
            "oldText": .string("keep"),
            "newText": .string("kept"),
        ])
        let result = try await EditTool().execute(args, in: fixture.context)
        #expect(!result.isError)
        let read = try await ReadTool().execute(["path": "l.txt"], in: fixture.context)
        #expect(read.text == "kept\n")
    }

    @Test("edit preserves CRLF line endings")
    func preservesCRLF() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.writeBytes("crlf.txt", Data("a\r\nb\r\nc\r\n".utf8))

        let result = try await EditTool().execute(
            editArgs("crlf.txt", [("b", "B")]), in: fixture.context)
        #expect(!result.isError)

        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture.path("crlf.txt")))
        #expect(bytes == Data("a\r\nB\r\nc\r\n".utf8))
    }
}
