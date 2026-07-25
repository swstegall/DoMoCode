// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A quote-, escape-, and substitution-aware shell splitter for the permission factory.
// opencode uses a full tree-sitter parse; DoMoCode substitutes a hand-rolled scanner
// that covers the SECURITY-relevant cases: every fragment that a POSIX shell would
// EXECUTE becomes its own checked sub-command, so a `rm *` deny catches the `rm` in a
// chained `echo hi && rm -rf /`, a command substitution `echo $(rm -rf /)` (even
// inside double quotes, where substitution is still active), a backtick, and a
// subshell `( … )` / group `{ …; }`. It deliberately OVER-splits (an extra harmless
// fragment is safe; a missed executable command is not). Splitting respects single
// quotes (which suppress everything) and backslash escapes; it is an approximation of,
// not a replacement for, a real shell parser, and errs toward more checks.

/// The permission-relevant decomposition of a shell command.
public enum ShellCommand {
    /// Every executable command fragment in `command`, including nested command
    /// substitutions and subshells. Splits on top-level `&&`/`||`/`;`/`|`/`&`/newline
    /// (outside all quotes), on `$(`/backtick command substitutions (active outside
    /// single quotes — i.e. also inside double quotes), and on `(`/`)`/`{`/`}`
    /// subshell/group boundaries (outside quotes). Each fragment is trimmed; empties
    /// are dropped.
    public static func split(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escaped = false
        let chars = Array(command)
        var i = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
        }

        while i < chars.count {
            let c = chars[i]

            if escaped {
                current.append(c)
                escaped = false
                i += 1
                continue
            }
            if inSingle {
                current.append(c)
                if c == "'" { inSingle = false }
                i += 1
                continue
            }
            // Outside single quotes a backslash escapes the next character (so `\;`,
            // `\"`, `\\` never desync the scanner or act as a separator).
            if c == "\\" {
                current.append(c)
                escaped = true
                i += 1
                continue
            }
            if inDouble {
                // Command substitution is still active inside double quotes.
                if c == "`" { flush(); i += 1; continue }
                if c == "$", i + 1 < chars.count, chars[i + 1] == "(" { flush(); i += 2; continue }
                current.append(c)
                if c == "\"" { inDouble = false }
                i += 1
                continue
            }
            // Outside all quotes.
            switch c {
            case "'": inSingle = true; current.append(c); i += 1
            case "\"": inDouble = true; current.append(c); i += 1
            case "`": flush(); i += 1
            case "(", ")", "{", "}": flush(); i += 1
            case "$" where i + 1 < chars.count && chars[i + 1] == "(": flush(); i += 2
            case "\n", ";": flush(); i += 1
            case "&": flush(); i += (i + 1 < chars.count && chars[i + 1] == "&") ? 2 : 1
            case "|": flush(); i += (i + 1 < chars.count && chars[i + 1] == "|") ? 2 : 1
            default: current.append(c); i += 1
            }
        }
        flush()
        return segments
    }

    /// Tokenize a single command into whitespace-separated words, respecting quotes
    /// and backslash escapes (a quoted or escaped span is one token, with its quote
    /// characters preserved as opencode keeps them). Used to compute the arity prefix.
    public static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var inSingle = false
        var inDouble = false
        var escaped = false

        func flush() {
            if started { tokens.append(current) }
            current = ""
            started = false
        }

        for c in command {
            if escaped {
                current.append(c)
                escaped = false
                continue
            }
            if inSingle {
                current.append(c)
                if c == "'" { inSingle = false }
                continue
            }
            if c == "\\" {
                current.append(c)
                escaped = true
                started = true
                continue
            }
            if inDouble {
                current.append(c)
                if c == "\"" { inDouble = false }
                continue
            }
            switch c {
            case "'": inSingle = true; started = true; current.append(c)
            case "\"": inDouble = true; started = true; current.append(c)
            case " ", "\t", "\n", "\r":
                flush()
            default:
                started = true
                current.append(c)
            }
        }
        flush()
        return tokens
    }

    /// Drop leading `NAME=value` environment-assignment tokens before the command
    /// name, mirroring opencode's `parts()` (which drops tree-sitter
    /// `variable_assignment` children) — so `FOO=bar rm x` prefixes as `rm`, not `FOO`.
    public static func stripEnvAssignments(_ tokens: [String]) -> [String] {
        var index = 0
        while index < tokens.count, isEnvAssignment(tokens[index]) { index += 1 }
        return Array(tokens[index...])
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
