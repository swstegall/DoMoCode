// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/terminal.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Terminal-native control sequences used by the interactive surfaces. Keeping
// these builders and parsers pure makes the wire contract testable without a
// tty; `TerminalLifecycle` is the only type that writes the resulting bytes.

import Foundation

/// The terminal progress states understood by OSC 9;4.
public enum TerminalProgress: Sendable, Equatable, Hashable {
    /// Remove the progress indicator.
    case clear
    /// Show an indeterminate in-progress indicator.
    case indeterminate
    /// Show a determinate progress value in the inclusive range 0...100.
    case percent(Int)
}

/// The two notification wire formats supported by the terminal-native client.
public enum TerminalNotificationProtocol: Sendable, Equatable, Hashable {
    /// iTerm2/VTE's OSC 777 notification extension.
    case osc777
    /// Kitty's OSC 99 notification extension.
    case kittyOSC99
}

/// The semantic prompt/command boundaries understood by terminals that
/// implement OSC 133. The mini renderer emits prompt boundaries with each
/// frame and the interactive coordinator emits command boundaries around a
/// submitted turn.
public enum TerminalPromptMark: Sendable, Equatable, Hashable {
    /// Start of the prompt text.
    case promptStart
    /// End of the prompt text, immediately before operator input.
    case promptEnd
    /// Start of a submitted command/turn.
    case commandStart
    /// End of a submitted command/turn. The exit code is optional because an
    /// interrupted turn has no meaningful process-style status.
    case commandEnd(exitCode: Int?)
}

/// A response to the Kitty keyboard protocol query.
public enum TerminalKeyboardProtocolResponse: Sendable, Equatable, Hashable {
    /// Kitty answered with its active flag bitset. A value of zero means Kitty
    /// keyboard reporting is unavailable or disabled.
    case kitty(flags: Int)
    /// The terminal answered the device-attributes sentinel. This is the
    /// fallback signal when a terminal ignores the Kitty query.
    case deviceAttributes
}

/// Pure terminal-native sequence builders and response parsers.
public enum TerminalNativeSequence {
    /// The requested Kitty keyboard flags: disambiguate escape, report event
    /// types, and report alternate key representations.
    public static let desiredKittyKeyboardFlags = 7

    /// Ask for Kitty keyboard flags, the current Kitty flags, and a device
    /// attributes response. The final response is a useful fallback boundary
    /// for terminals that do not understand the first two queries.
    public static func keyboardProtocolQuery(
        flags: Int = desiredKittyKeyboardFlags
    ) -> [UInt8] {
        let requested = max(0, flags)
        return bytes("\u{1b}[>\(requested)u\u{1b}[?u\u{1b}[c")
    }

    /// Pop the Kitty keyboard protocol mode.
    public static func disableKittyKeyboardProtocol() -> [UInt8] {
        bytes("\u{1b}[<u")
    }

    /// Enable or disable xterm's `modifyOtherKeys` mode 2 fallback.
    public static func modifyOtherKeysSequence(enabled: Bool) -> [UInt8] {
        bytes(enabled ? "\u{1b}[>4;2m" : "\u{1b}[>4;0m")
    }

    /// Enable or disable terminal focus-in/focus-out reports.
    public static func focusReportingSequence(enabled: Bool) -> [UInt8] {
        bytes(enabled ? "\u{1b}[?1004h" : "\u{1b}[?1004l")
    }

    /// An explicit Kitty CSI-u Shift+Enter event. The driver uses this for the
    /// two legacy byte forms that remain ambiguous after Kitty negotiation.
    public static func shiftEnterSequence() -> [UInt8] {
        bytes("\u{1b}[13;2u")
    }

    /// Set the terminal window title through OSC 0.
    public static func titleSequence(_ title: String) -> [UInt8] {
        bytes("\u{1b}]0;\(sanitizeField(title))\u{07}")
    }

    /// Clear the title on teardown. A shell prompt that owns titles will set its
    /// own title again on the next prompt; this prevents the client name from
    /// surviving a crash-safe return to the shell.
    public static func clearTitleSequence() -> [UInt8] {
        bytes("\u{1b}]0;\u{07}")
    }

    /// Emit an OSC 9;4 progress state.
    public static func progressSequence(_ progress: TerminalProgress) -> [UInt8] {
        switch progress {
        case .clear:
            return bytes("\u{1b}]9;4;0;\u{07}")
        case .indeterminate:
            return bytes("\u{1b}]9;4;3\u{07}")
        case .percent(let value):
            return bytes("\u{1b}]9;4;1;\(min(100, max(0, value)))\u{07}")
        }
    }

    /// Emit an OS notification. OSC 777 uses BEL and Kitty OSC 99 uses ST so
    /// both forms remain valid when written directly to a tty over SSH.
    public static func notificationSequence(
        title: String,
        message: String,
        protocol: TerminalNotificationProtocol = .osc777
    ) -> [UInt8] {
        let cleanTitle = sanitizeField(title)
        let cleanMessage = sanitizeField(message)
        switch `protocol` {
        case .osc777:
            return bytes("\u{1b}]777;notify;\(cleanTitle);\(cleanMessage)\u{07}")
        case .kittyOSC99:
            let titlePart = "\u{1b}]99;i=1:d=0;\(cleanTitle)\u{1b}\\"
            let bodyPart = "\u{1b}]99;i=1:p=\(cleanMessage);\(cleanMessage)\u{1b}\\"
            return bytes(titlePart + bodyPart)
        }
    }

    /// Emit one OSC 133 semantic prompt mark. The payload is deliberately
    /// numeric and contains no user-controlled text, so the sequence cannot
    /// become an OSC injection even when a turn ends with an arbitrary error.
    public static func promptMark(_ mark: TerminalPromptMark) -> [UInt8] {
        let payload: String
        switch mark {
        case .promptStart:
            payload = "A"
        case .promptEnd:
            payload = "B"
        case .commandStart:
            payload = "C"
        case .commandEnd(let exitCode):
            if let exitCode {
                payload = "D;\(exitCode)"
            } else {
                payload = "D"
            }
        }
        return bytes("\u{1b}]133;\(payload)\u{07}")
    }

    /// Parse one complete response framed by ``StdinFramer``.
    public static func parseKeyboardProtocolResponse(
        _ data: [UInt8]
    ) -> TerminalKeyboardProtocolResponse? {
        guard data.count >= 3, data[0] == 0x1b, data[1] == 0x5b else { return nil }
        let final = data[data.count - 1]
        let body = Array(data[2..<(data.count - 1)])

        if final == 0x75, body.first == 0x3f { // CSI ? flags u
            let digits = body.dropFirst()
            guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
                return nil
            }
            let text = String(decoding: digits, as: UTF8.self)
            guard let flags = Int(text) else { return nil }
            return .kitty(flags: flags)
        }

        // Device attributes are the only `CSI ?...c` response consumed by the
        // handshake. Requiring the private marker avoids swallowing an ordinary
        // cursor/report sequence ending in `c`.
        if final == 0x63, body.first == 0x3f {
            let parameters = body.dropFirst()
            guard parameters.allSatisfy({ $0 == 0x3b || ($0 >= 0x30 && $0 <= 0x39) }) else {
                return nil
            }
            return .deviceAttributes
        }
        return nil
    }

    /// Return the focus state represented by a complete terminal sequence.
    public static func focusState(from data: [UInt8]) -> Bool? {
        switch data {
        case bytes("\u{1b}[I"): return true
        case bytes("\u{1b}[O"): return false
        default: return nil
        }
    }

    /// Whether a complete frame is one of the two legacy Shift+Enter forms
    /// whose meaning becomes unambiguous only after Kitty negotiation.
    public static func isAmbiguousShiftEnter(_ data: [UInt8]) -> Bool {
        data == bytes("\u{1b}\r") || data == [0x0a]
    }

    /// Strip controls and field separators before placing text inside an OSC
    /// payload. This keeps titles and notifications from becoming an escape
    /// injection or changing the payload's field structure.
    public static func sanitizeField(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if code == 0x3b {
                result.append(" ")
            } else if code == 0x20 || code == 0x09 || (code >= 0x21 && code <= 0x7e)
                || code >= 0xa0 {
                result.append(String(scalar))
            } else if code == 0x0a || code == 0x0d {
                result.append(" ")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bytes(_ value: String) -> [UInt8] { Array(value.utf8) }
}
