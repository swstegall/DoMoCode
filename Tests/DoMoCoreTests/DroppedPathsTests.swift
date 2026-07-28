// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

// MARK: - What real terminals send

@Suite("DroppedPaths: real terminal drop formats")
struct DroppedPathsTerminalFormatTests {

    @Test("Terminal.app and iTerm2 backslash-escape spaces and add a trailing space")
    func backslashEscapedSpaces() {
        let drop = #"/Users/x/my\ pic.png "#
        #expect(DroppedPaths.candidates(drop).first == ["/Users/x/my pic.png"])
    }

    @Test("iTerm2 leaves shell metacharacters unescaped; they survive as ordinary bytes")
    func unescapedMetacharacters() {
        // iTerm2 is documented not to escape `$ < > ; | *`.
        let drop = "/Users/x/rate$50.png"
        #expect(DroppedPaths.candidates(drop).first == ["/Users/x/rate$50.png"])
    }

    @Test("WezTerm SpacesOnly multi-file drop splits on the unescaped spaces")
    func multipleFilesSpaceSeparated() {
        let drop = #"/Users/x/a.png /Users/x/b.png"#
        #expect(DroppedPaths.candidates(drop).first == ["/Users/x/a.png", "/Users/x/b.png"])
    }

    @Test("a multi-file drop separated by newlines splits the same way")
    func multipleFilesNewlineSeparated() {
        let drop = "/Users/x/a.png\n/Users/x/b.png\n"
        #expect(DroppedPaths.candidates(drop).first == ["/Users/x/a.png", "/Users/x/b.png"])
    }

    @Test("WezTerm Posix single-quotes and folds an apostrophe the shell way")
    func posixSingleQuoting() {
        let drop = #"'/Users/x/it'\''s.png'"#
        #expect(DroppedPaths.candidates(drop).first == ["/Users/x/it's.png"])
    }

    @Test("a double-quoted path keeps its spaces")
    func doubleQuoted() {
        let drop = #""/Users/x/a b.png""#
        #expect(DroppedPaths.candidates(drop).first == ["/Users/x/a b.png"])
    }

    @Test("GNOME Terminal single-quotes only troublesome names")
    func vteSingleQuoted() {
        #expect(DroppedPaths.candidates("'/home/x/a b.png'").first == ["/home/x/a b.png"])
        #expect(DroppedPaths.candidates("/home/x/a.png").first == ["/home/x/a.png"])
    }

    @Test("a text/uri-list drop is decoded from its file: URL")
    func fileURLPercentDecoded() {
        #expect(
            DroppedPaths.candidates("file:///home/x/a%20b.png").first == ["/home/x/a b.png"]
        )
    }

    @Test("file://localhost and the degenerate file:/ form both resolve")
    func fileURLHostForms() {
        #expect(DroppedPaths.candidates("file://localhost/tmp/a.png").first == ["/tmp/a.png"])
        #expect(DroppedPaths.candidates("file:/tmp/a.png").first == ["/tmp/a.png"])
        #expect(DroppedPaths.candidates("FILE:///tmp/a.png").first == ["/tmp/a.png"])
    }

    @Test("a percent-encoded non-ASCII filename recombines its UTF-8 bytes")
    func fileURLUnicode() {
        // Two escapes, one scalar: decoding per-character instead of per-byte
        // would produce mojibake here.
        #expect(
            DroppedPaths.candidates("file:///Users/x/caf%C3%A9%20noir.png").first
                == ["/Users/x/café noir.png"]
        )
    }

    @Test("kitty and WezTerm None escape nothing, so the whole string is a reading")
    func unescapedSpaceInName() {
        // Tokenizing shreds it — `pic.png` is not path-shaped — so the only
        // reading offered is the whole string as one path.
        let readings = DroppedPaths.candidates("/Users/x/my pic.png")
        #expect(readings == [["/Users/x/my pic.png"]])
    }

    @Test("a filename containing a quote survives only as the verbatim reading")
    func quoteInFilename() {
        let readings = DroppedPaths.candidates(#"/Users/x/say "hi".png"#)
        // Unescaping strips the quotes; the verbatim reading keeps them, and it
        // is the verbatim one that names the file that actually exists.
        #expect(readings.contains([#"/Users/x/say "hi".png"#]))
        #expect(readings.contains(["/Users/x/say hi.png"]))
    }

    @Test("an escaped name that tokenizing shreds is recovered by the whole-string reading")
    func escapedSpacesAcrossWords() {
        let readings = DroppedPaths.candidates(#"/Users/x/my\ pic and\ more.png"#)
        // `and more.png` is not path-shaped, so reading 1 is unavailable.
        #expect(readings.first == ["/Users/x/my pic and more.png"])
    }

    @Test("the kitty macOS percent-encoding bug is the LAST reading, never the first")
    func kittyPercentEncodingIsTriedLast() {
        let readings = DroppedPaths.candidates("/Users/x/my%20pic.png")
        // A file literally named `my%20pic.png` must win; the decoded form is a
        // fallback for kovidgoyal/kitty#10054.
        #expect(readings == [["/Users/x/my%20pic.png"], ["/Users/x/my pic.png"]])
    }

    @Test("a percent-decoded reading is offered for the whole-string form too")
    func percentVariantOfWholeStringReading() {
        let readings = DroppedPaths.candidates("/Users/x/a%20b c.png")
        #expect(readings.first == ["/Users/x/a%20b c.png"])
        #expect(readings.contains(["/Users/x/a b c.png"]))
    }

    @Test("a tilde path is path-shaped; the filesystem expands it later")
    func tildePaths() {
        #expect(DroppedPaths.candidates("~/Pictures/a.png").first == ["~/Pictures/a.png"])
        #expect(DroppedPaths.candidates("~").first == ["~"])
    }

    @Test("sixteen paths is the most one drop may carry")
    func atTheTokenLimit() {
        let drop = (1...16).map { "/tmp/\($0).png" }.joined(separator: " ")
        #expect(DroppedPaths.candidates(drop).first?.count == 16)
    }
}

// MARK: - The safety property

@Suite("DroppedPaths: text that must never be eaten")
struct DroppedPathsSafetyTests {

    @Test(
        "prose is never a drop",
        arguments: [
            "check /tmp/a.png and tell me",
            "notes.png",
            "./notes.png",
            "../a/b.png",
            "",
            "   ",
            "\n\n",
            "~notauser/a.png",
            "'unterminated",
            #""unterminated"#,
            #"/tmp/a.png\"#,  // dangling escape
            "https://example.com/a.png",
            "s3://bucket/a.png",
            "see the diff in src/main.swift",
        ]
    )
    func prosePastesAreNotDrops(_ text: String) {
        #expect(DroppedPaths.candidates(text).isEmpty, "\(text.debugDescription) parsed as a drop")
    }

    @Test("a pasted code block is not a drop, even when a line starts with a slash")
    func pastedCodeBlockIsNotADrop() {
        let block = """
            /Users/x/project/main.swift
            func main() {
                print("hello")
            }
            """
        // Reading 1 fails (`func`, `main()`, … are not path-shaped) and the
        // whole-string readings are suppressed by the newlines.
        #expect(DroppedPaths.candidates(block).isEmpty)
    }

    @Test("a long paste beginning with a slash is not one enormous filename")
    func longPasteIsNotAFilename() {
        let line = String(repeating: "/aaaaaaaaaa", count: 500)  // 5500 bytes, one token
        #expect(line.utf8.count > DroppedPaths.maximumPathBytes)
        #expect(DroppedPaths.candidates(line).isEmpty)
    }

    @Test("seventeen tokens exceeds the drop limit and disables every reading")
    func aboveTheTokenLimit() {
        let drop = (1...17).map { "/tmp/\($0).png" }.joined(separator: " ")
        #expect(DroppedPaths.candidates(drop).isEmpty)
    }

    @Test("a path carrying an escape sequence is refused outright")
    func controlCharactersAreRefused() {
        #expect(DroppedPaths.isPathShaped("/tmp/\u{1b}[31mred.png") == false)
        #expect(DroppedPaths.candidates("/tmp/\u{1b}[2Ja.png").isEmpty)
        #expect(DroppedPaths.isPathShaped("/tmp/a\u{7f}.png") == false)
    }

    @Test("prose that BEGINS with a path is offered only as a single-path reading")
    func proseBeginningWithAPathIsAmbiguous() {
        // This is the one genuinely ambiguous shape: `/tmp/a.png and tell me` is
        // indistinguishable from a kitty drop of a file with spaces in its name.
        // It is offered as ONE path, which the filesystem then refuses, after
        // which the caller re-inserts the raw text verbatim. Tokenizing it as
        // several paths — which would silently eat the words — is NOT offered.
        let readings = DroppedPaths.candidates("/tmp/a.png and tell me")
        #expect(readings == [["/tmp/a.png and tell me"]])
    }
}

// MARK: - Tokenizer

@Suite("DroppedPaths.tokenize")
struct DroppedPathsTokenizeTests {

    @Test("unquoted whitespace splits, runs collapse, edges are ignored")
    func splitting() {
        #expect(DroppedPaths.tokenize("  a\t b \n c  ") == ["a", "b", "c"])
        #expect(DroppedPaths.tokenize("") == [])
    }

    @Test("a backslash outside quotes escapes anything at all")
    func backslashOutsideQuotes() {
        #expect(DroppedPaths.tokenize(#"a\ b"#) == ["a b"])
        #expect(DroppedPaths.tokenize(#"a\'b"#) == ["a'b"])
        #expect(DroppedPaths.tokenize(#"a\\b"#) == [#"a\b"#])
        #expect(DroppedPaths.tokenize(#"\$HOME"#) == ["$HOME"])
    }

    @Test("single quotes are literal end to end")
    func singleQuotes() {
        #expect(DroppedPaths.tokenize(#"'a \b "c" d'"#) == [#"a \b "c" d"#])
        // The shell's `'\''` idiom needs no special case.
        #expect(DroppedPaths.tokenize(#"'it'\''s'"#) == ["it's"])
        // An explicitly empty token is a token.
        #expect(DroppedPaths.tokenize("''") == [""])
    }

    @Test("double quotes unescape only the POSIX four, plus line continuation")
    func doubleQuotes() {
        #expect(DroppedPaths.tokenize(#""a\"b""#) == [#"a"b"#])
        #expect(DroppedPaths.tokenize(#""a\\b""#) == [#"a\b"#])
        #expect(DroppedPaths.tokenize(#""a\$b""#) == ["a$b"])
        // Anything else keeps BOTH characters — a Windows path is not mangled.
        #expect(DroppedPaths.tokenize(#""C:\temp""#) == [#"C:\temp"#])
        #expect(DroppedPaths.tokenize("\"a\\\nb\"") == ["ab"])
    }

    @Test("an unfinished string is not a drop")
    func unterminated() {
        #expect(DroppedPaths.tokenize("'open") == nil)
        #expect(DroppedPaths.tokenize(#""open"#) == nil)
        #expect(DroppedPaths.tokenize(#"trailing\"#) == nil)
        #expect(DroppedPaths.tokenize("\"inner\\") == nil)
    }

    @Test("quoted whitespace does not split")
    func quotedWhitespaceIsKept() {
        #expect(DroppedPaths.tokenize(#""a b" 'c d'"#) == ["a b", "c d"])
    }
}

// MARK: - Shape

@Suite("DroppedPaths.isPathShaped")
struct DroppedPathsShapeTests {

    @Test("absolute, tilde and file: forms are path-shaped")
    func accepted() {
        #expect(DroppedPaths.isPathShaped("/a"))
        #expect(DroppedPaths.isPathShaped("/Users/x/a.png"))
        #expect(DroppedPaths.isPathShaped("~"))
        #expect(DroppedPaths.isPathShaped("~/a.png"))
        #expect(DroppedPaths.isPathShaped("file:///a.png"))
        #expect(DroppedPaths.isPathShaped("File:/a.png"))
    }

    @Test("everything else is left alone")
    func refused() {
        #expect(DroppedPaths.isPathShaped("") == false)
        #expect(DroppedPaths.isPathShaped("a.png") == false)
        #expect(DroppedPaths.isPathShaped("./a.png") == false)
        #expect(DroppedPaths.isPathShaped("~user/a.png") == false)
        #expect(DroppedPaths.isPathShaped("http://x/a.png") == false)
        #expect(DroppedPaths.isPathShaped("file:a.png") == false)
        #expect(DroppedPaths.isPathShaped(String(repeating: "/a", count: 4096)) == false)
    }
}

// MARK: - file: URLs

@Suite("DroppedPaths.decodingFileURL")
struct DroppedPathsFileURLTests {

    @Test("the three accepted spellings all decode to a plain path")
    func spellings() {
        #expect(DroppedPaths.decodingFileURL("file:///a/b.png") == "/a/b.png")
        #expect(DroppedPaths.decodingFileURL("file://localhost/a/b.png") == "/a/b.png")
        #expect(DroppedPaths.decodingFileURL("file://LOCALHOST/a/b.png") == "/a/b.png")
        #expect(DroppedPaths.decodingFileURL("file:/a/b.png") == "/a/b.png")
    }

    @Test("a URL naming another host is left alone — its bytes are not here")
    func remoteHost() {
        let token = "file://fileserver/share/a.png"
        #expect(DroppedPaths.decodingFileURL(token) == token)
        #expect(DroppedPaths.decodingFileURL("file://host") == "file://host")
    }

    @Test("a plain path is returned verbatim, so a literal %20 is never eaten")
    func noDoubleDecoding() {
        #expect(DroppedPaths.decodingFileURL("/a/b%20c.png") == "/a/b%20c.png")
        #expect(DroppedPaths.decodingFileURL("~/b%2520c.png") == "~/b%2520c.png")
        // One decode, not two: `%2520` is the encoding of the literal `%20`.
        #expect(DroppedPaths.decodingFileURL("file:///a/b%2520c.png") == "/a/b%20c.png")
    }

    @Test("malformed escapes are passed through rather than failing")
    func malformedEscapes() {
        #expect(DroppedPaths.decodingFileURL("file:///a/100%25.png") == "/a/100%.png")
        #expect(DroppedPaths.decodingFileURL("file:///a/50%.png") == "/a/50%.png")
        #expect(DroppedPaths.decodingFileURL("file:///a/%ZZ.png") == "/a/%ZZ.png")
        #expect(DroppedPaths.decodingFileURL("file:///a/b%2") == "/a/b%2")
    }

    @Test("percentDecoding is byte-level and leaves clean text untouched")
    func percentDecoding() {
        #expect(DroppedPaths.percentDecoding("/a/b.png") == "/a/b.png")
        #expect(DroppedPaths.percentDecoding("%C3%A9") == "é")
        #expect(DroppedPaths.percentDecoding("%2f") == "/")
        #expect(DroppedPaths.percentDecoding("100%") == "100%")
    }
}
