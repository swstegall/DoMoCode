import DoMoCore
import DoMoTools
import Foundation
import SystemPackage
import Testing

@Suite("ls")
struct LsToolTests {

    @Test("lists entries alphabetically with directory markers and dotfiles")
    func listsEntries() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("beta.txt", "b")
        try fixture.write("alpha.txt", "a")
        try fixture.makeDirectory("subdir")
        try fixture.write(".hidden", "h")

        let result = try await LsTool().execute([:], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text == ".hidden\nalpha.txt\nbeta.txt\nsubdir/")
    }

    @Test("an empty directory says so")
    func emptyDirectory() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await LsTool().execute([:], in: fixture.context)
        #expect(result.text == "(empty directory)")
    }

    @Test("a missing directory is a clear error")
    func missingDirectory() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }

        let result = try await LsTool().execute(["path": "nope"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Path not found"))
    }

    @Test("listing a file rather than a directory is an error")
    func notADirectory() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("f.txt", "x")

        let result = try await LsTool().execute(["path": "f.txt"], in: fixture.context)
        #expect(result.isError)
        #expect(result.text.contains("Not a directory"))
    }

    @Test("the entry limit is reported with a raise-limit hint")
    func entryLimit() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        for index in 0..<5 { try fixture.write("f\(index).txt", "x") }

        let result = try await LsTool().execute(["path": ".", "limit": 2], in: fixture.context)
        #expect(result.text.contains("2 entries limit reached. Use limit=4 for more"))
    }
}

@Suite("find")
struct FindToolTests {

    @Test("pure-Swift fallback finds by glob when fd is absent")
    func fallbackGlob() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("src/a.swift", "a")
        try fixture.write("src/nested/b.swift", "b")
        try fixture.write("src/c.txt", "c")

        let result = try await FindTool().execute(["pattern": "*.swift"], in: fixture.context)
        #expect(!result.isError)
        let lines = Set(result.text.split(separator: "\n").map(String.init))
        #expect(lines == ["src/a.swift", "src/nested/b.swift"])
    }

    @Test("fallback respects .gitignore")
    func fallbackGitignore() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write(".gitignore", "ignored/\n")
        try fixture.write("keep.txt", "k")
        try fixture.write("ignored/skip.txt", "s")

        let result = try await FindTool().execute(["pattern": "*.txt"], in: fixture.context)
        #expect(result.text.contains("keep.txt"))
        #expect(!result.text.contains("ignored/skip.txt"))
    }

    @Test("an anchored path glob matches the full relative path")
    func anchoredGlob() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("src/x/y.spec.ts", "1")
        try fixture.write("other/y.spec.ts", "2")

        let result = try await FindTool().execute(
            ["pattern": "src/**/*.spec.ts"], in: fixture.context)
        let lines = Set(result.text.split(separator: "\n").map(String.init))
        #expect(lines == ["src/x/y.spec.ts"])
    }

    @Test("no matches is a clear message")
    func noMatches() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "a")

        let result = try await FindTool().execute(["pattern": "*.nomatch"], in: fixture.context)
        #expect(result.text == "No files found matching pattern")
    }

    @Test("uses fd when installed", .enabled(if: ExternalToolLocator.pathSearch.locate("fd") != nil))
    func withFd() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("a.swift", "a")
        try fixture.write("nested/b.swift", "b")
        try fixture.write("c.txt", "c")

        let result = try await FindTool().execute(["pattern": "*.swift"], in: fixture.context)
        #expect(!result.isError)
        let lines = Set(result.text.split(separator: "\n").map(String.init))
        #expect(lines.contains("a.swift"))
        #expect(lines.contains("nested/b.swift"))
        #expect(!lines.contains("c.txt"))
    }
}

@Suite("grep")
struct GrepToolTests {

    @Test("pure-Swift fallback finds matching lines when ripgrep is absent")
    func fallbackMatches() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "needle here\nhaystack\nanother needle\n")
        try fixture.write("b.txt", "nothing\n")

        let result = try await GrepTool().execute(["pattern": "needle"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.contains("a.txt:1: needle here"))
        #expect(result.text.contains("a.txt:3: another needle"))
        #expect(!result.text.contains("b.txt"))
    }

    @Test("fallback honors ignoreCase")
    func fallbackIgnoreCase() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "Hello World\n")

        let sensitive = try await GrepTool().execute(["pattern": "hello"], in: fixture.context)
        #expect(sensitive.text == "No matches found")

        let insensitive = try await GrepTool().execute(
            ["pattern": "hello", "ignoreCase": true], in: fixture.context)
        #expect(insensitive.text.contains("a.txt:1: Hello World"))
    }

    @Test("fallback literal mode treats the pattern as text")
    func fallbackLiteral() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "a+b=c\n")

        let asRegex = try await GrepTool().execute(["pattern": "a+b"], in: fixture.context)
        // `a+b` as a regex matches "ab", which is not present.
        #expect(asRegex.text == "No matches found")

        let asLiteral = try await GrepTool().execute(
            ["pattern": "a+b", "literal": true], in: fixture.context)
        #expect(asLiteral.text.contains("a.txt:1: a+b=c"))
    }

    @Test("fallback context lines surround the match")
    func fallbackContext() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "one\ntwo\nTARGET\nfour\nfive\n")

        let result = try await GrepTool().execute(
            ["pattern": "TARGET", "context": 1], in: fixture.context)
        #expect(result.text.contains("a.txt-2- two"))
        #expect(result.text.contains("a.txt:3: TARGET"))
        #expect(result.text.contains("a.txt-4- four"))
    }

    @Test("fallback glob filters which files are searched")
    func fallbackGlobFilter() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.swift", "match me\n")
        try fixture.write("b.txt", "match me\n")

        let result = try await GrepTool().execute(
            ["pattern": "match", "glob": "*.swift"], in: fixture.context)
        #expect(result.text.contains("a.swift"))
        #expect(!result.text.contains("b.txt"))
    }

    @Test("fallback searches a single file directly")
    func fallbackSingleFile() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("only.txt", "alpha\nfindme\nbeta\n")

        let result = try await GrepTool().execute(
            ["pattern": "findme", "path": "only.txt"], in: fixture.context)
        // For a single file the display path is the basename.
        #expect(result.text.contains("only.txt:2: findme"))
    }

    @Test("an absurd context does not overflow-trap")
    func absurdContextDoesNotTrap() async throws {
        let fixture = try await ToolFixture.make(toolLocator: .unavailable)
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "one\nTARGET\nthree\n")

        // A naive `lineNumber + contextLines` with context == Int.max overflows
        // and traps the process. It must clamp to the file bounds instead.
        let result = try await GrepTool().execute(
            ["pattern": "TARGET", "context": .int(Int.max)], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.contains("a.txt:2: TARGET"))
        #expect(result.text.contains("one"))
        #expect(result.text.contains("three"))
    }

    @Test("uses ripgrep when installed", .enabled(if: ExternalToolLocator.pathSearch.locate("rg") != nil))
    func withRipgrep() async throws {
        let fixture = try await ToolFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("a.txt", "needle here\nhaystack\n")
        try fixture.write("sub/b.txt", "another needle\n")

        let result = try await GrepTool().execute(["pattern": "needle"], in: fixture.context)
        #expect(!result.isError)
        #expect(result.text.contains("a.txt:1: needle here"))
        #expect(result.text.contains("sub/b.txt:1: another needle"))
    }
}
