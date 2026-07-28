// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// The shapes a terminal produces when a file is dropped onto it.
///
/// Dragging a file onto a terminal does not deliver a file. It makes the
/// terminal *type* — usually *paste* — the path, and every terminal spells that
/// differently:
///
/// | Terminal | What lands in the buffer |
/// |---|---|
/// | Terminal.app, iTerm2 | `/Users/x/my\ pic.png ` — backslash-escaped spaces, trailing space |
/// | WezTerm (`quote_dropped_files = "SpacesOnly"`, the non-Windows default) | as above |
/// | WezTerm (`"Posix"`) | `'/Users/x/it'\''s.png'` — single-quoted, `'` folded the shell way |
/// | WezTerm (`"None"`), kitty | `/Users/x/my pic.png` — no escaping at all |
/// | kitty on macOS (kovidgoyal/kitty#10054) | `/Users/x/my%20pic.png` — percent-encoded |
/// | GNOME Terminal / VTE | `/home/x/a.png`, or `'/home/x/a b.png'` when the name is troublesome |
/// | anything consuming `text/uri-list` | `file:///home/x/a%20b.png` |
/// | any of them, multi-file drop | the above, joined by spaces or newlines |
///
/// So a drop cannot be parsed; it can only be *guessed at*, several ways, and
/// the guesses ranked. ``candidates(_:)`` returns every plausible reading, most
/// likely first, and the caller resolves them against the filesystem in order —
/// the parser proposes, the disk disposes.
///
/// ## The safety property
///
/// A token that is not *path-shaped* (``isPathShaped(_:)``) makes the whole
/// reading it belongs to unavailable. That is what stops ordinary prose — "check
/// /tmp/a.png and tell me" — and pasted code from being swallowed as an
/// attachment. When ``candidates(_:)`` returns an empty array the caller must
/// treat the paste as ordinary text and insert it verbatim.
///
/// ## Not `ShellCommand.tokenize`
///
/// `DoMoPermissions.ShellCommand.tokenize` deliberately *preserves* quotes and
/// backslashes, because a permission rule has to match the command the user
/// wrote. This needs the exact opposite — a path with the escaping removed — so
/// it is a separate state machine rather than a shared one with a flag.
public enum DroppedPaths {

    /// The most tokens one drop may contribute.
    ///
    /// A drop of a whole folder selection is a paste, not an attachment gesture,
    /// and a paste of a 40-line shell transcript must never be mistaken for 40
    /// dropped files. Exceeding this makes *every* reading unavailable, including
    /// the whole-string ones — a string that splits into seventeen pieces is not
    /// one filename either.
    public static let maximumTokens = 16

    /// The longest a token may be and still be considered a path.
    ///
    /// `PATH_MAX` is 1024 on Darwin and 4096 on Linux; the larger is used so a
    /// legitimate deep path on either is never refused. Its real job is to stop a
    /// multi-kilobyte paste that happens to begin with `/` from being offered as
    /// a filename.
    public static let maximumPathBytes = 4096

    // MARK: Candidates

    /// Every plausible reading of `text` as a list of dropped file paths, most
    /// likely first, or an empty array when it cannot be a drop at all.
    ///
    /// The readings, in the order they are produced:
    ///
    /// 1. `text` tokenized on unquoted whitespace with each token unescaped —
    ///    Terminal.app, iTerm2, WezTerm `SpacesOnly`/`Posix`, VTE, and every
    ///    multi-file drop. Produced only when *every* token is path-shaped.
    /// 2. the whole trimmed string as ONE path, unescaped — a name containing a
    ///    space that (1) shredded, e.g. `/Users/x/my\ pic and\ more.png`.
    /// 3. the whole trimmed string as ONE path, VERBATIM — WezTerm `None` and
    ///    kitty, which escape nothing, so a filename containing a literal quote
    ///    (`/Users/x/say "hi".png`) is mangled by (2) and only survives here.
    ///    Identical to (2) whenever the text carries no escapes, in which case it
    ///    is not produced twice.
    /// 4. any of the above with `%XX` sequences percent-decoded, for the kitty
    ///    macOS bug. Deliberately last, so a file legitimately named `a%20b.png`
    ///    is found first and a decoded near-miss can never displace it.
    ///
    /// Readings (2) and (3) are suppressed when the text contains a newline: a
    /// multi-line paste beginning with `/` is a code block, not a filename.
    ///
    /// A `file:` URL token is decoded to a plain path in every reading, so the
    /// caller never has to know the scheme existed.
    public static func candidates(_ text: String) -> [[String]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // A drop that will not tokenize — an unterminated quote, a dangling
        // backslash — is a half-typed string, not a drop. A drop that tokenizes
        // into more pieces than `maximumTokens` is a paste.
        guard let tokens = tokenize(trimmed), !tokens.isEmpty, tokens.count <= maximumTokens
        else { return [] }

        var raw: [[String]] = []
        func offer(_ reading: [String]) {
            guard reading.allSatisfy(isPathShaped), !raw.contains(reading) else { return }
            raw.append(reading)
        }

        offer(tokens)
        if !trimmed.contains(where: \.isNewline) {
            if let whole = unescapingWholeString(trimmed) { offer([whole]) }
            offer([trimmed])
        }

        var readings: [[String]] = []
        for reading in raw {
            let resolved = reading.map(decodingFileURL)
            if !readings.contains(resolved) { readings.append(resolved) }
        }

        // The percent-decoded variants come last, and are derived from the RAW
        // tokens so a `file:` URL — already decoded once by `decodingFileURL` —
        // is never decoded a second time.
        var decoded: [[String]] = []
        for reading in raw {
            guard reading.contains(where: { !isFileURL($0) && containsPercentEscape($0) })
            else { continue }
            let variant = reading.map { isFileURL($0) ? decodingFileURL($0) : percentDecoding($0) }
            guard variant.allSatisfy(isPathShaped) else { continue }
            if !readings.contains(variant), !decoded.contains(variant) { decoded.append(variant) }
        }

        return readings + decoded
    }

    // MARK: Tokenizing

    /// Split on unquoted whitespace, UNESCAPING as it goes.
    ///
    /// The rules are the shell's, because they are the rules the terminals are
    /// imitating when they escape a dropped path:
    ///
    /// - outside quotes, `\x` yields `x` for any `x` — this is what WezTerm's
    ///   `SpacesOnly` and `Posix` modes, Terminal.app and iTerm2 all produce;
    /// - `'…'` is literal end to end. The shell's `'\''` idiom needs no special
    ///   case: it is a closed quote, an escaped `'`, and a reopened quote, which
    ///   the machine already folds to one `'`;
    /// - `"…"` unescapes `\"`, `\\`, `\$` and ``\` `` only, and removes a
    ///   `\`-newline pair, per POSIX double-quote rules. Every other backslash
    ///   inside double quotes stays literal — `"C:\temp"` keeps its backslash.
    ///
    /// Returns `nil` when a quote is left open or the text ends on a dangling
    /// backslash. Both mean the text is incomplete, and an incomplete string is
    /// never a drop.
    public static func tokenize(_ text: String) -> [String]? {
        scan(text, splittingOnWhitespace: true)
    }

    /// The whole string as a single token, with escaping removed but whitespace
    /// kept — reading (2) of ``candidates(_:)``.
    ///
    /// Same machine as ``tokenize(_:)`` with the separator set empty, so the two
    /// can never disagree about what `\ ` or `'…'` means.
    private static func unescapingWholeString(_ text: String) -> String? {
        scan(text, splittingOnWhitespace: false)?.first
    }

    private enum QuoteState {
        case none, single, double
    }

    private static func scan(_ text: String, splittingOnWhitespace: Bool) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var started = false
        var quote: QuoteState = .none
        let characters = Array(text)
        var index = 0

        func flush() {
            if started { tokens.append(current) }
            current = ""
            started = false
        }

        while index < characters.count {
            let character = characters[index]
            index += 1

            switch quote {
            case .none:
                if character == "\\" {
                    guard index < characters.count else { return nil }
                    current.append(characters[index])
                    index += 1
                    started = true
                } else if character == "'" {
                    quote = .single
                    started = true
                } else if character == "\"" {
                    quote = .double
                    started = true
                } else if splittingOnWhitespace, character.isWhitespace {
                    flush()
                } else {
                    current.append(character)
                    started = true
                }

            case .single:
                if character == "'" {
                    quote = .none
                } else {
                    current.append(character)
                }

            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\" {
                    guard index < characters.count else { return nil }
                    let next = characters[index]
                    index += 1
                    switch next {
                    case "\"", "\\", "$", "`":
                        current.append(next)
                    case "\n":
                        break  // line continuation: both characters vanish
                    default:
                        current.append(character)
                        current.append(next)
                    }
                } else {
                    current.append(character)
                }
            }
        }

        guard quote == .none else { return nil }
        flush()
        return tokens
    }

    // MARK: Shape

    /// Whether one already-unescaped token can be a dropped path.
    ///
    /// It must begin with `/`, `~/`, be `~` alone, or begin with `file:/`.
    ///
    /// A RELATIVE path is deliberately refused. A bare `notes.png` is
    /// indistinguishable from a word, and eating it would break the rule this
    /// whole file exists to keep: never silently swallow text the user meant as
    /// text. No terminal drops a relative path anyway — a drag carries a URL.
    ///
    /// Control characters are refused as well. A real filename may legally
    /// contain them, but a *dropped* one will not, and a path carrying an escape
    /// sequence is a terminal-injection vector the moment it is echoed into a
    /// chip label.
    public static func isPathShaped(_ token: String) -> Bool {
        guard !token.isEmpty, token.utf8.count <= maximumPathBytes else { return false }
        let hasControl = token.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        guard !hasControl else { return false }
        if token.hasPrefix("/") { return true }
        if token == "~" || token.hasPrefix("~/") { return true }
        return isFileURL(token)
    }

    // MARK: file: URLs

    /// Whether the token carries a `file:` scheme, which is spelled in any case.
    private static func isFileURL(_ token: String) -> Bool {
        token.count >= 6 && token.prefix(6).lowercased() == "file:/"
    }

    /// Decode a `file:` URL token to a plain filesystem path, percent-decoding
    /// exactly once.
    ///
    /// Accepts `file:///a/b`, `file://localhost/a/b` and the degenerate
    /// `file:/a/b`. A URL naming some *other* host is left alone: its bytes are
    /// not on this machine, so pretending its path is local would attach the
    /// wrong file.
    ///
    /// A token that is not a `file:` URL is returned VERBATIM — never decoded —
    /// so an ordinary path containing a literal `%20` survives intact. The
    /// percent-decoded reading of such a path is a separate candidate, tried
    /// last (see ``candidates(_:)``).
    public static func decodingFileURL(_ token: String) -> String {
        guard isFileURL(token) else { return token }
        var rest = String(token.dropFirst(5))  // drop "file:", keep the leading "/"

        if rest.hasPrefix("//") {
            rest = String(rest.dropFirst(2))
            guard let slash = rest.firstIndex(of: "/") else { return token }
            let authority = rest[rest.startIndex..<slash]
            guard authority.isEmpty || authority.lowercased() == "localhost" else { return token }
            rest = String(rest[slash...])
        }

        guard rest.hasPrefix("/") else { return token }
        return percentDecoding(rest)
    }

    /// Percent-decode `%XX` byte escapes, leaving anything malformed alone.
    ///
    /// Decoding at the BYTE level, not the character level, is what makes a
    /// percent-encoded non-ASCII filename (`caf%C3%A9.png`) come back as
    /// `café.png` — the two escapes are one UTF-8 scalar and must be recombined
    /// before decoding. A lone `%` or a `%ZZ` is passed through unchanged rather
    /// than failing, so a filename containing a bare percent sign survives.
    public static func percentDecoding(_ text: String) -> String {
        guard containsPercentEscape(text) else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count,
                let high = hexDigit(bytes[index + 1]), let low = hexDigit(bytes[index + 2])
            {
                out.append(high << 4 | low)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func containsPercentEscape(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0x25, hexDigit(bytes[index + 1]) != nil,
                hexDigit(bytes[index + 2]) != nil
            {
                return true
            }
            index += 1
        }
        return false
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
