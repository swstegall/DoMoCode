// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Where a configuration file went wrong, said precisely enough to fix.
//
// `JSONDecoder` knows the *shape* that failed and nothing about the bytes: for
// `typeMismatch`, `keyNotFound` and `valueNotFound` it hands back a
// `codingPath` and no offset at all, and for `dataCorrupted` it hands back
// English prose ("Unexpected character 't' around line 1, column 4.") whose
// wording is Foundation's business, not ours. Neither is something a user can
// act on when the file is two hundred lines long, and neither can be parsed
// back into a location without betting on that prose. So the location is
// recovered here, from the source bytes, by ``JSONSourceIndex``.

import Foundation

// MARK: - Source location

/// A position in a UTF-8 source file, in the three units that matter.
///
/// Modelled on ``JSONLinesError``, which keeps the byte offset alongside the
/// line number for the same reason: the line number is what a human reads, the
/// byte offset is what a tool seeks to, and neither is recoverable from the
/// other once a line can contain an arbitrarily long tool result or a minified
/// object.
public struct ConfigSourceLocation: Sendable, Hashable {
    /// Byte offset from the start of the file. Always within `0...count`, so it
    /// is safe to slice with.
    public var byteOffset: Int

    /// 1-based physical line number.
    public var line: Int

    /// 1-based column, counted in **Unicode scalars, not bytes**.
    ///
    /// Bytes would be wrong the moment a key contains anything outside ASCII:
    /// `"café"` is five scalars and six bytes, so a byte column puts the caret
    /// one place to the right of the character it is accusing. Scalars are not
    /// perfect either — a scalar of double display width still occupies two
    /// terminal cells — but they are the unit the excerpt is rendered in, so
    /// the caret and the excerpt agree with each other by construction.
    public var column: Int

    public init(byteOffset: Int, line: Int, column: Int) {
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
    }

    /// Converts a byte offset into a line and column.
    ///
    /// `byteOffset` is clamped to `0...bytes.count`: a caller that arrived here
    /// with an offset from someone else's parser (Foundation's
    /// `NSJSONSerializationErrorIndex`, say) must not be able to trap the
    /// process because that parser counted a byte we did not. An offset at or
    /// past the end reports the end-of-file position, which is exactly what a
    /// truncated document should point at.
    ///
    /// A `\r\n` pair is one line terminator: the `CR` is part of it and does
    /// not advance the column, so a CRLF file reports the same columns as the
    /// same file with Unix endings. A lone `CR` is treated as an ordinary
    /// character, not as a line break — classic-Mac line endings are not
    /// something a JSON config arrives with, and guessing would misreport every
    /// escaped `\r`.
    public static func locate(byteOffset: Int, in bytes: [UInt8]) -> ConfigSourceLocation {
        let target = min(max(0, byteOffset), bytes.count)
        var line = 1
        var column = 1
        var index = 0
        while index < target {
            let byte = bytes[index]
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                // Continuation bytes are skipped, so the count is scalars.
                let isCarriageReturnOfCRLF =
                    byte == 0x0D && index + 1 < bytes.count && bytes[index + 1] == 0x0A
                if !isCarriageReturnOfCRLF { column += 1 }
            }
            index += 1
        }
        return ConfigSourceLocation(byteOffset: target, line: line, column: column)
    }
}

// MARK: - Diagnostic

/// A configuration failure with a place to point at.
///
/// Carries the file, the position, the key path *and* the offending source line
/// with a caret under it, because each answers a different question a user
/// actually asks: which file, which line, which setting, and what does the
/// mistake look like.
///
/// > Important: ``description`` is **multi-line** — a header, then the source
/// > excerpt, then the caret. That is deliberate (a caret is worthless without
/// > the line above it) and it is the opposite of ``DoMoError/description``,
/// > which promises to read as one line so that it can be embedded in another
/// > message. Anything that splices a `ConfigDiagnostic` into a single-line
/// > surface — a status bar, a log field, a JSON string — must use
/// > ``headline`` instead.
public struct ConfigDiagnostic: Error, Sendable, Hashable, CustomStringConvertible {
    /// The file the problem is in, as it should be shown to the user. `nil`
    /// when the bytes did not come from a file (a `--config` string, a test).
    public var file: String?

    /// Where in the file. `nil` when no position could be recovered — which is
    /// a real outcome, not a bug: a decoder complaint about a key that is
    /// simply absent from a document has nothing in the bytes to point at.
    public var location: ConfigSourceLocation?

    /// The setting, outermost first. Array elements appear as decimal strings,
    /// matching ``JSONSourceIndex``.
    public var keyPath: [String]

    /// What is wrong, in the imperative-free, lowercase style of the rest of
    /// this package's error text.
    public var problem: String

    /// The offending source line with tabs expanded to spaces, or `nil` when
    /// there is no line to show.
    ///
    /// Tabs are expanded rather than emitted because the caret line beneath is
    /// built from spaces: a tab in the excerpt would be re-expanded by the
    /// terminal to its own tab stop and slide the text out from under the
    /// caret. A long line is windowed around the caret and marked with `…`, so
    /// a minified settings.json cannot dump a hundred kilobytes into a terminal.
    public var excerpt: String?

    /// 1-based column *within ``excerpt``*, after tab expansion and windowing.
    /// Not interchangeable with ``ConfigSourceLocation/column``.
    public var caretColumn: Int?

    public init(
        file: String?,
        location: ConfigSourceLocation?,
        keyPath: [String],
        problem: String,
        excerpt: String?,
        caretColumn: Int?
    ) {
        self.file = file
        self.location = location
        self.keyPath = keyPath
        self.problem = problem
        self.excerpt = excerpt
        self.caretColumn = caretColumn
    }

    /// Builds a diagnostic from raw source, deriving the location, the excerpt
    /// and the caret column together so they cannot disagree.
    ///
    /// This is the initializer producers of diagnostics should reach for; the
    /// memberwise one exists for callers that genuinely have no bytes.
    public init(
        file: String?,
        source: [UInt8],
        byteOffset: Int?,
        keyPath: [String],
        problem: String
    ) {
        let location = byteOffset.map { ConfigSourceLocation.locate(byteOffset: $0, in: source) }
        let rendered = location.flatMap { Self.renderExcerpt(of: source, at: $0) }
        self.init(
            file: file,
            location: location,
            keyPath: keyPath,
            problem: problem,
            excerpt: rendered?.text,
            caretColumn: rendered?.caretColumn
        )
    }

    /// The first line of ``description``: position, setting, problem.
    ///
    /// Follows the `file:line:column: message` convention every compiler and
    /// editor already knows how to jump to.
    public var headline: String {
        var text = ""
        if let file {
            text += file
            if let location {
                text += ":\(location.line):\(location.column)"
            }
            text += ": "
        } else if let location {
            text += "\(location.line):\(location.column): "
        }
        if !keyPath.isEmpty {
            text += keyPath.joined(separator: ".") + " — "
        }
        text += problem
        return text
    }

    /// The headline, then the offending line, then a caret under the offending
    /// character. **Multi-line** — see the type's note.
    public var description: String {
        var lines = [headline]
        if let excerpt {
            lines.append(excerpt)
            if let caretColumn {
                lines.append(String(repeating: " ", count: max(0, caretColumn - 1)) + "^")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension ConfigDiagnostic: LocalizedError {
    /// `LocalizedError` is conformed to so that `localizedDescription` says
    /// something useful instead of Foundation's "The operation couldn't be
    /// completed", which is what an un-conformed `Error` produces the moment it
    /// crosses a Cocoa API.
    public var errorDescription: String? { description }
}

// MARK: - Excerpt rendering

extension ConfigDiagnostic {
    /// How far a tab advances in an excerpt.
    ///
    /// Four rather than eight, and fixed rather than read from the terminal:
    /// the excerpt is emitted with the tabs already turned into spaces, so no
    /// terminal ever gets a say. The number only has to be consistent between
    /// the text and the caret, which it is by construction below.
    static let tabWidth = 4

    /// Longest excerpt emitted before it is windowed around the caret.
    ///
    /// A settings.json written by a tool can be a single 100 KB line. Without a
    /// bound, one syntax error in it would print that whole line to a terminal
    /// followed by a caret line of equal length.
    static let maximumExcerptScalars = 200

    /// Scalars kept either side of the caret when windowing.
    static let excerptContextScalars = 80

    static func renderExcerpt(
        of bytes: [UInt8],
        at location: ConfigSourceLocation
    ) -> (text: String, caretColumn: Int)? {
        let anchor = min(max(0, location.byteOffset), bytes.count)

        var start = anchor
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = anchor
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        // Drop the CR of a CRLF pair: it is part of the terminator, and left in
        // place it would move the cursor back to column one and paint the caret
        // line over the excerpt.
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
        guard start < end else { return nil }

        let line = String(decoding: bytes[start..<end], as: UTF8.self)
        let tab: Unicode.Scalar = "\t"
        let space: Unicode.Scalar = " "

        var expanded: [Unicode.Scalar] = []
        var caret: Int?
        var column = 1
        for scalar in line.unicodeScalars {
            if column == location.column { caret = expanded.count + 1 }
            if scalar == tab {
                let advance = tabWidth - (expanded.count % tabWidth)
                expanded.append(contentsOf: repeatElement(space, count: advance))
            } else {
                expanded.append(scalar)
            }
            column += 1
        }
        // A caret one past the last scalar is the normal way to say "the thing
        // that should be here is missing", so it is a position, not an error.
        var caretColumn = caret ?? (expanded.count + 1)

        if expanded.count > maximumExcerptScalars {
            let ellipsis: Unicode.Scalar = "…"
            let caretIndex = caretColumn - 1
            let windowStart = max(0, caretIndex - excerptContextScalars)
            let windowEnd = min(expanded.count, caretIndex + excerptContextScalars)
            var window = Array(expanded[windowStart..<windowEnd])
            caretColumn = caretIndex - windowStart + 1
            if windowStart > 0 {
                window.insert(ellipsis, at: 0)
                caretColumn += 1
            }
            if windowEnd < expanded.count {
                window.append(ellipsis)
            }
            expanded = window
        }

        var view = String.UnicodeScalarView()
        view.append(contentsOf: expanded)
        return (String(view), caretColumn)
    }
}

// MARK: - Bridging a decoding failure

extension ConfigDiagnostic {
    /// Turns whatever `JSONDecoder` threw into something that points at a byte.
    ///
    /// The order of preference is the point of this initializer:
    ///
    /// 1. If `source` is not well-formed JSON at all, the syntax error wins.
    ///    ``JSONSourceIndex`` is stricter than Foundation's parser — it rejects
    ///    the trailing comma Foundation quietly accepts — and it produces an
    ///    offset for cases Foundation produces nothing for, an unterminated
    ///    string being the one that matters in practice.
    /// 2. Otherwise the document parses, so the complaint is about shape, and
    ///    the key path can be looked up in the index for an exact byte range.
    /// 3. Only if both fail is Foundation's `NSJSONSerializationErrorIndex`
    ///    consulted — a machine-readable byte index it attaches to
    ///    `dataCorrupted`. Its *prose* is never parsed: "around line 1, column
    ///    4" is English by construction and there is no promise it stays that
    ///    way, nor that the key is present at all on Linux.
    public init(decoding error: any Error, source: [UInt8], file: String?) {
        // Idempotent: a diagnostic that has already been built (by the scanner,
        // or by config interpolation) only needs its file filled in.
        if let existing = error as? ConfigDiagnostic {
            var copy = existing
            if copy.file == nil { copy.file = file }
            self = copy
            return
        }

        let index: [[String]: JSONSourceIndex.Entry]
        do {
            index = try JSONSourceIndex.index(source)
        } catch {
            var syntax = error
            if syntax.file == nil { syntax.file = file }
            self = syntax
            return
        }

        guard let decodingError = error as? DecodingError else {
            self.init(
                file: file,
                source: source,
                byteOffset: nil,
                keyPath: [],
                problem: String(describing: error)
            )
            return
        }

        let keyPath: [String]
        let problem: String
        // Where to point. For a missing key that is the enclosing container —
        // the key itself is by definition nowhere in the bytes — and for
        // everything else it is the offending value.
        let lookupPath: [String]

        switch decodingError {
        case .keyNotFound(let key, let context):
            let parent = Self.pathComponents(context.codingPath)
            keyPath = parent + [Self.name(of: key)]
            problem = "missing required key \"\(Self.name(of: key))\""
            lookupPath = parent

        case .typeMismatch(let type, let context):
            keyPath = Self.pathComponents(context.codingPath)
            problem = "expected a value of type \(type)"
            lookupPath = keyPath

        case .valueNotFound(let type, let context):
            keyPath = Self.pathComponents(context.codingPath)
            problem = "expected a value of type \(type), found null"
            lookupPath = keyPath

        case .dataCorrupted(let context):
            keyPath = Self.pathComponents(context.codingPath)
            // The document already scanned clean, so this is a `Decodable`
            // rejecting its own input — "contextWindow must be positive" — and
            // that text is ours, written in English on purpose.
            problem =
                context.debugDescription.isEmpty
                ? "the value is not valid here" : context.debugDescription
            lookupPath = keyPath

        @unknown default:
            keyPath = []
            problem = String(describing: decodingError)
            lookupPath = []
        }

        let byteOffset =
            index[lookupPath]?.valueRange.lowerBound ?? Self.foundationByteIndex(decodingError)

        self.init(
            file: file,
            source: source,
            byteOffset: byteOffset,
            keyPath: keyPath,
            problem: problem
        )
    }

    /// `[any CodingKey]` flattened the same way ``JSONSourceIndex`` builds its
    /// keys, so a coding path can be used as a lookup key directly: an array
    /// index is a decimal string, everything else is its name.
    static func pathComponents(_ codingPath: [any CodingKey]) -> [String] {
        codingPath.map { name(of: $0) }
    }

    static func name(of key: any CodingKey) -> String {
        if let index = key.intValue { return String(index) }
        return key.stringValue
    }

    /// The byte index Foundation attaches to a JSON syntax error, if it is
    /// there.
    ///
    /// Every step is optional on purpose. The key is undocumented, it is absent
    /// for some malformations even on macOS (an unterminated string yields no
    /// index at all), and none of this was verified on Linux — so a missing key,
    /// a missing `underlyingError` or a value of the wrong type all have to mean
    /// "no location", never a crash.
    static func foundationByteIndex(_ error: DecodingError) -> Int? {
        guard case .dataCorrupted(let context) = error else { return nil }
        guard let underlying = context.underlyingError else { return nil }
        let userInfo = (underlying as NSError).userInfo
        guard let raw = userInfo["NSJSONSerializationErrorIndex"] else { return nil }
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }
}
