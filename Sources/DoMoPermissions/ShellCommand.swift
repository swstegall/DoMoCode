// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A minimal, quote-aware shell splitter for the permission factory. opencode uses a
// full tree-sitter parse; DoMoCode substitutes a hand-rolled scanner that covers the
// security-relevant cases: it splits a compound command into its top-level
// sub-commands (so a chained `echo hi && rm -rf /` is gated per-command, not as one
// opaque string that a `rm *` deny rule would miss), and tokenizes each into words
// with quotes respected. It does NOT recurse into `$(…)`/backticks or model
// redirections precisely — those stay part of the command text (still matchable by a
// glob rule), which is a deliberate, documented v1 limitation.

/// The permission-relevant decomposition of a shell command.
public enum ShellCommand {
    /// Split a compound command into its top-level sub-commands on `&&`, `||`, `;`,
    /// `|`, `&`, and newlines — but never inside single or double quotes. Each result
    /// is trimmed; empty segments are dropped. A command with no operators returns
    /// itself (trimmed) as a single element.
    public static func split(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        let chars = Array(command)
        var i = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
        }

        while i < chars.count {
            let c = chars[i]
            if inSingle {
                current.append(c)
                if c == "'" { inSingle = false }
                i += 1
                continue
            }
            if inDouble {
                current.append(c)
                if c == "\"" { inDouble = false }
                i += 1
                continue
            }
            switch c {
            case "'": inSingle = true; current.append(c); i += 1
            case "\"": inDouble = true; current.append(c); i += 1
            case "\n": flush(); i += 1
            case ";": flush(); i += 1
            case "&":
                flush()
                i += (i + 1 < chars.count && chars[i + 1] == "&") ? 2 : 1
            case "|":
                flush()
                i += (i + 1 < chars.count && chars[i + 1] == "|") ? 2 : 1
            default:
                current.append(c)
                i += 1
            }
        }
        flush()
        return segments
    }

    /// Tokenize a single command into whitespace-separated words, respecting quotes
    /// (a quoted span is one token, with its quote characters preserved as opencode
    /// keeps them). Used to compute the bash arity prefix.
    public static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var inSingle = false
        var inDouble = false

        func flush() {
            if started { tokens.append(current) }
            current = ""
            started = false
        }

        for c in command {
            if inSingle {
                current.append(c)
                if c == "'" { inSingle = false }
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
}
