// Copyright (c) 2025 opentui. MIT license.  https://github.com/anomalyco/opentui
// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/stdin-buffer.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

/// Whether a candidate escape sequence is finished, still growing, or not an
/// escape sequence at all.
///
/// This three-way answer is the whole reason the framer exists. A terminal
/// delivers `read()` chunks on its own schedule, so the SGR mouse report
/// `ESC [ < 3 5 ; 2 0 ; 5 m` can arrive as `ESC`, then `[<35`, then `;20;5m`.
/// Decoding each chunk on arrival turns one mouse event into three phantom
/// keystrokes. The framer holds an ``incomplete`` prefix until the byte that
/// completes it lands (or the disambiguation timeout fires), and only then hands
/// a whole sequence downstream.
public enum SequenceCompleteness: Sendable, Equatable {
    case complete
    case incomplete
    case notEscape
}

/// One framed input event.
///
/// A ``sequence`` is exactly one keystroke or terminal report — never a batch —
/// which is what makes the key matcher's `isKeyRelease`/`matchesKey` decisions
/// well-defined. A ``paste`` carries the *inner* content of a bracketed paste,
/// with the `ESC [ 200~` / `ESC [ 201~` guards stripped, because paste content
/// is data and must not be re-interpreted as keystrokes.
public enum StdinEvent: Sendable, Equatable {
    case sequence([UInt8])
    case paste([UInt8])
}

// MARK: - Byte constants

private let esc: UInt8 = 0x1b
private let bel: UInt8 = 0x07
private let backslash = UInt8(ascii: "\\")
private let leftBracket = UInt8(ascii: "[")
private let rightBracket = UInt8(ascii: "]")
private let capitalO = UInt8(ascii: "O")
private let capitalP = UInt8(ascii: "P")
private let capitalM = UInt8(ascii: "M")
private let smallM = UInt8(ascii: "m")
private let smallU = UInt8(ascii: "u")
private let underscore = UInt8(ascii: "_")
private let lessThan = UInt8(ascii: "<")
private let semicolon = UInt8(ascii: ";")
private let colon = UInt8(ascii: ":")

/// `ESC [ 200 ~` — the terminal wraps a paste's payload in this and its
/// counterpart so the application can tell typed bytes from pasted ones.
private let bracketedPasteStart: [UInt8] = [esc, leftBracket, 0x32, 0x30, 0x30, 0x7e]
/// `ESC [ 201 ~`.
private let bracketedPasteEnd: [UInt8] = [esc, leftBracket, 0x32, 0x30, 0x31, 0x7e]

// MARK: - Framer

/// Accumulates raw stdin bytes and emits one whole sequence per event.
///
/// A value type on purpose: the state is a byte buffer plus two paste flags, all
/// of it cheap to copy, so the I/O layer can own it behind a `Mutex` or an actor
/// without a reference-cycle story. The framer never touches a file descriptor,
/// a clock, or a `Task` — ``process(_:)`` is a pure function of its argument and
/// the current buffer, which is exactly what lets the hard cases (a mouse report
/// split at every byte boundary, an embedded `ESC` inside a paste) be driven
/// byte-by-byte in a unit test with no TTY anywhere.
///
/// The disambiguation timeout is deliberately *not* here. The framer reports
/// through ``hasPendingBytes`` that it is holding an incomplete tail; the I/O
/// layer arms its own ~10ms timer and calls ``flush()`` when it fires. Keeping
/// the timer outside the state machine is what makes the state machine testable
/// without waiting on wall-clock time.
public struct StdinFramer: Sendable {
    private var buffer: [UInt8] = []
    private var pasteMode = false
    private var pasteBuffer: [UInt8] = []

    /// A printable codepoint that was just emitted as a raw byte and might be
    /// echoed again by the terminal as an unmodified Kitty CSI-u report.
    ///
    /// WezTerm and other Kitty-protocol terminals sometimes send a printable key
    /// twice — once as `ESC [ <cp> u` and once as the raw character — and
    /// forwarding both types the letter twice. Emitting an unmodified CSI-u report
    /// primes this with its codepoint; a raw single-scalar sequence of that same
    /// codepoint arriving next is then swallowed. The dedup is one-directional
    /// (CSI-u then raw), matching pi: a raw character does not prime this slot, so
    /// a CSI-u report is never suppressed by a preceding raw duplicate.
    private var pendingKittyPrintableCodepoint: UInt32?

    public init() {}

    /// How long the I/O layer should hold an incomplete tail before calling
    /// ``flush()``.
    ///
    /// This is the ESC-disambiguation window: long enough that the rest of a
    /// fragmented CSI arrives, short enough that a real Escape keypress does not
    /// feel laggy. pi uses the same 10ms. The framer does not consume it — the
    /// timer belongs to the I/O layer — but the value lives here so the two
    /// cannot drift apart.
    public static let disambiguationTimeout: Duration = .milliseconds(10)

    /// True while an incomplete escape or multi-byte tail is held back.
    ///
    /// The I/O layer polls this after every ``process(_:)`` to decide whether to
    /// arm the ESC-disambiguation timer. A bare `ESC` is indistinguishable from
    /// the start of a longer sequence until either more bytes or the timeout
    /// resolve it.
    public var hasPendingBytes: Bool { !buffer.isEmpty }

    /// Feed a chunk of raw bytes; returns every sequence and paste it completed.
    public mutating func process(_ incoming: [UInt8]) -> [StdinEvent] {
        var events: [StdinEvent] = []
        processInner(incoming, into: &events)
        return events
    }

    /// Emit whatever incomplete tail is buffered as a single sequence.
    ///
    /// Called by the I/O layer when the disambiguation timer fires: a lone `ESC`
    /// that never grew into a CSI is the user pressing Escape, and a truncated
    /// tail that will never complete has to leave the buffer rather than swallow
    /// the next real keystroke behind it.
    public mutating func flush() -> [StdinEvent] {
        guard !buffer.isEmpty else { return [] }
        let sequence = buffer
        buffer = []
        pendingKittyPrintableCodepoint = nil
        var events: [StdinEvent] = []
        emitDataSequence(sequence, into: &events)
        return events
    }

    /// Drop all buffered and paste state without emitting.
    public mutating func reset() {
        buffer = []
        pasteMode = false
        pasteBuffer = []
        pendingKittyPrintableCodepoint = nil
    }

    private mutating func processInner(_ incoming: [UInt8], into events: inout [StdinEvent]) {
        // pi rewrote a lone high byte to `ESC` + (byte − 128) for 8-bit Meta, but
        // that branch only ran because Node's `setEncoding("utf8")` StringDecoder
        // had already reassembled every multi-byte scalar upstream, so pi never
        // saw a split scalar. Operating on raw bytes we do, and the two cases are
        // indistinguishable from a single byte: `0xC3` is both a plausible 8-bit
        // Meta key and the lead of `é`. UTF-8 wins — modern terminals send Alt as
        // an `ESC` prefix, not 8-bit Meta — so a high lead byte is held as an
        // incomplete scalar (see `extractCompleteSequences`) rather than rewritten.
        if incoming.isEmpty && buffer.isEmpty {
            emitDataSequence([], into: &events)
            return
        }

        buffer.append(contentsOf: incoming)

        if pasteMode {
            pasteBuffer.append(contentsOf: buffer)
            buffer = []
            drainPasteIfClosed(into: &events)
            return
        }

        if let start = firstIndex(of: bracketedPasteStart, in: buffer) {
            if start > 0 {
                // Anything before the paste marker is ordinary input. Its own
                // incomplete tail is dropped: a paste marker is a hard boundary,
                // and a half-sequence butted against it will not be completed by
                // paste content.
                let beforePaste = Array(buffer[..<start])
                let extracted = StdinFramer.extractCompleteSequences(beforePaste)
                for sequence in extracted.sequences {
                    emitDataSequence(sequence, into: &events)
                }
            }
            pendingKittyPrintableCodepoint = nil
            pasteBuffer = Array(buffer[(start + bracketedPasteStart.count)...])
            buffer = []
            pasteMode = true
            drainPasteIfClosed(into: &events)
            return
        }

        let extracted = StdinFramer.extractCompleteSequences(buffer)
        buffer = extracted.remainder
        for sequence in extracted.sequences {
            emitDataSequence(sequence, into: &events)
        }
    }

    private mutating func drainPasteIfClosed(into events: inout [StdinEvent]) {
        guard let end = firstIndex(of: bracketedPasteEnd, in: pasteBuffer) else { return }
        let content = Array(pasteBuffer[..<end])
        let remaining = Array(pasteBuffer[(end + bracketedPasteEnd.count)...])
        pasteMode = false
        pasteBuffer = []
        pendingKittyPrintableCodepoint = nil
        events.append(.paste(content))
        if !remaining.isEmpty {
            processInner(remaining, into: &events)
        }
    }

    private mutating func emitDataSequence(_ sequence: [UInt8], into events: inout [StdinEvent]) {
        let rawCodepoint = StdinFramer.singleBMPScalar(sequence)
        if let raw = rawCodepoint, raw == pendingKittyPrintableCodepoint {
            pendingKittyPrintableCodepoint = nil
            return
        }
        pendingKittyPrintableCodepoint = StdinFramer.parseUnmodifiedKittyPrintableCodepoint(sequence)
        events.append(.sequence(sequence))
    }
}

// MARK: - Pure completeness state machine

extension StdinFramer {
    /// Classify a candidate sequence: finished, still growing, or plain text.
    ///
    /// The public entry point of the state machine, and the one the framer's hard
    /// tests drive directly, feeding a known sequence one byte longer each time
    /// and asserting the answer flips from ``SequenceCompleteness/incomplete`` to
    /// ``SequenceCompleteness/complete`` at exactly the right byte.
    public static func isCompleteSequence(_ data: ArraySlice<UInt8>) -> SequenceCompleteness {
        guard let first = data.first, first == esc else { return .notEscape }
        if data.count == 1 { return .incomplete }

        let second = data[data.startIndex + 1]
        switch second {
        case leftBracket:
            // Legacy X10 mouse: `ESC [ M` plus three coordinate bytes. It has to
            // be recognised before the general CSI rule, because `M` is itself a
            // valid CSI final byte and the general rule would call `ESC [ M`
            // complete three bytes too early.
            if data.count >= 3, data[data.startIndex + 2] == capitalM {
                return data.count >= 6 ? .complete : .incomplete
            }
            return isCompleteCSI(data)
        case rightBracket:
            return isCompleteStringTerminated(data, allowBEL: true)
        case capitalP, underscore:
            // DCS (device control, e.g. XTVersion) and APC (application command,
            // e.g. Kitty graphics) both close on ST only, never BEL.
            return isCompleteStringTerminated(data, allowBEL: false)
        case capitalO:
            // SS3: `ESC O` plus exactly one final byte (F1–F4, application cursor).
            return data.count >= 3 ? .complete : .incomplete
        case esc:
            // `ESC ESC` is genuinely ambiguous: it is either a double-Escape /
            // meta chord (complete now) or the WezTerm split — the Escape key as a
            // raw `ESC` immediately followed by a full Kitty CSI-u release, which
            // reaches us as `ESC ESC [ … u`. With only the two bytes in hand we
            // cannot tell, so we hold exactly as a bare `ESC` is held; the third
            // byte (or the disambiguation flush) resolves it. Reporting `.complete`
            // at two bytes — as pi does — is only safe when the whole burst lands
            // in one `read()`; split at this boundary it stranded `[ … u` to be
            // typed as text. `extractCompleteSequences` performs the actual split.
            return data.count == 2 ? .incomplete : .complete
        default:
            // `ESC` + one character is a Meta chord; anything else beginning with
            // `ESC` we do not model is taken as already whole rather than held
            // forever.
            return .complete
        }
    }

    /// CSI (`ESC [ … final`) completeness.
    ///
    /// A CSI ends on a byte in `0x40…0x7E`. SGR mouse (`ESC [ < b ; x ; y M/m`)
    /// is special-cased because its coordinates contain `;` and digits that are
    /// themselves in no final-byte range, but a stray `m`/`M` mid-report would
    /// otherwise look final — so a `<`-prefixed CSI is complete only when it
    /// matches the full `< digits ; digits ; digits [Mm]` shape.
    private static func isCompleteCSI(_ data: ArraySlice<UInt8>) -> SequenceCompleteness {
        if data.count < 3 { return .incomplete }
        let payload = data[(data.startIndex + 2)...]
        let last = payload[payload.index(before: payload.endIndex)]
        guard last >= 0x40, last <= 0x7e else { return .incomplete }

        if payload[payload.startIndex] == lessThan {
            return isCompleteSGRMouse(payload) ? .complete : .incomplete
        }
        return .complete
    }

    /// Whether a `<`-prefixed CSI payload is a whole SGR mouse report.
    private static func isCompleteSGRMouse(_ payload: ArraySlice<UInt8>) -> Bool {
        let last = payload[payload.index(before: payload.endIndex)]
        guard last == capitalM || last == smallM else { return false }
        let middle = payload[(payload.startIndex + 1)..<payload.index(before: payload.endIndex)]
        let parts = splitBytes(middle, on: semicolon)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(isDigit)
        }
    }

    /// OSC/DCS/APC completeness: a string-terminated family that closes on ST
    /// (`ESC \`), and — for OSC only — the historical BEL shorthand.
    private static func isCompleteStringTerminated(
        _ data: ArraySlice<UInt8>,
        allowBEL: Bool
    ) -> SequenceCompleteness {
        if hasSuffix(data, [esc, backslash]) { return .complete }
        if allowBEL, data.last == bel { return .complete }
        return .incomplete
    }
}

// MARK: - Sequence extraction

extension StdinFramer {
    /// Split an accumulated buffer into whole sequences plus an incomplete tail.
    ///
    /// The tail is handed back so the caller can prepend it to the next chunk (or
    /// flush it on timeout), which is the mechanism that reassembles a sequence
    /// fragmented across `read()` boundaries.
    static func extractCompleteSequences(
        _ buffer: [UInt8]
    ) -> (sequences: [[UInt8]], remainder: [UInt8]) {
        var sequences: [[UInt8]] = []
        var pos = 0
        let count = buffer.count

        while pos < count {
            if buffer[pos] == esc {
                var length = 1
                var advanced = false
                while length <= count - pos {
                    let candidate = buffer[pos..<(pos + length)]
                    switch isCompleteSequence(candidate) {
                    case .complete:
                        // WezTerm double-ESC split: with Kitty keyboard enabled it
                        // sends the Escape key as a bare `\x1b` and the release as a
                        // full CSI-u, arriving concatenated as `\x1b\x1b[…u`. Treating
                        // `\x1b\x1b` as a Meta chord would strand `[…u` to be typed as
                        // text. `isCompleteSequence` holds `\x1b\x1b` incomplete until a
                        // third byte lands, so a `.complete` here with a second `ESC`
                        // always has that byte in hand (`length >= 3`): when it begins a
                        // new escape sequence, emit just the first `ESC` and restart at
                        // the second; otherwise the double-ESC is a genuine meta chord —
                        // emit the two bytes and let the trailing byte reframe. This
                        // makes the split reassemble correctly even byte-by-byte, not
                        // only when the whole burst lands in one `read()`.
                        if length >= 3, buffer[pos + 1] == esc {
                            let next = buffer[pos + 2]
                            if next == leftBracket || next == rightBracket || next == capitalO
                                || next == capitalP || next == underscore
                            {
                                sequences.append([esc])
                                pos += 1
                            } else {
                                sequences.append([esc, esc])
                                pos += 2
                            }
                            advanced = true
                            break
                        }
                        sequences.append(Array(candidate))
                        pos += length
                        advanced = true
                    case .incomplete:
                        length += 1
                    case .notEscape:
                        // Unreachable while the candidate starts with ESC, but stay
                        // total rather than trust that invariant silently.
                        sequences.append(Array(candidate))
                        pos += length
                        advanced = true
                    }
                    if advanced { break }
                }
                if !advanced {
                    return (sequences, Array(buffer[pos...]))
                }
            } else {
                // Ordinary bytes are emitted one Unicode scalar at a time so a
                // typed multi-byte character (an accented letter, `é`) surfaces as
                // one event, matching a keystroke. A scalar split across chunks is
                // held exactly like an incomplete escape.
                let lead = buffer[pos]
                let scalarLength = utf8ScalarLength(lead)
                if scalarLength > 1 {
                    if pos + scalarLength > count {
                        return (sequences, Array(buffer[pos...]))
                    }
                    if isValidContinuation(buffer, from: pos + 1, count: scalarLength - 1) {
                        sequences.append(Array(buffer[pos..<(pos + scalarLength)]))
                        pos += scalarLength
                    } else {
                        sequences.append([lead])
                        pos += 1
                    }
                } else {
                    sequences.append([lead])
                    pos += 1
                }
            }
        }

        return (sequences, [])
    }
}

// MARK: - Kitty printable dedup

extension StdinFramer {
    /// The codepoint of `ESC [ <n> u` (an unmodified Kitty printable report), or
    /// `nil` if the sequence is not one, matching pi's
    /// `^\x1b\[(\d+)(?::\d*)?(?::\d+)?u$` with the `n >= 32` printable guard.
    static func parseUnmodifiedKittyPrintableCodepoint(_ sequence: [UInt8]) -> UInt32? {
        guard sequence.count >= 4, sequence[0] == esc, sequence[1] == leftBracket else {
            return nil
        }

        var index = 2
        let numberStart = index
        while index < sequence.count, isDigit(sequence[index]) { index += 1 }
        guard index > numberStart else { return nil }
        let codepoint = parseUInt32(sequence[numberStart..<index])

        // Optional `: \d*` (the shifted-key field, which may be empty).
        if index < sequence.count, sequence[index] == colon {
            index += 1
            while index < sequence.count, isDigit(sequence[index]) { index += 1 }
        }
        // Optional `: \d+` (the base-layout-key field).
        if index < sequence.count, sequence[index] == colon {
            index += 1
            let baseStart = index
            while index < sequence.count, isDigit(sequence[index]) { index += 1 }
            guard index > baseStart else { return nil }
        }

        guard index == sequence.count - 1, sequence[index] == smallU else { return nil }
        guard let codepoint, codepoint >= 32 else { return nil }
        return codepoint
    }

    /// The scalar value of a one-scalar, BMP sequence — the case where pi's
    /// JS-string length is exactly 1 UTF-16 unit and the raw/CSI-u dedup applies.
    /// Multi-scalar sequences and astral scalars (emoji) return `nil`.
    static func singleBMPScalar(_ sequence: [UInt8]) -> UInt32? {
        guard !sequence.isEmpty else { return nil }
        let decoded = String(decoding: sequence, as: UTF8.self).unicodeScalars
        guard decoded.count == 1, let scalar = decoded.first, scalar.value <= 0xFFFF else {
            return nil
        }
        return scalar.value
    }
}

// MARK: - Byte helpers

private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

private func parseUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32? {
    var value: UInt32 = 0
    for byte in bytes {
        let digit = UInt32(byte - 0x30)
        let (multiplied, overflow1) = value.multipliedReportingOverflow(by: 10)
        guard !overflow1 else { return nil }
        let (added, overflow2) = multiplied.addingReportingOverflow(digit)
        guard !overflow2 else { return nil }
        value = added
    }
    return value
}

/// Expected UTF-8 scalar length from a lead byte. Stray continuation bytes and
/// invalid `0xF8…0xFF` leads report length 1 so they are emitted as-is rather
/// than swallowing the bytes that follow.
private func utf8ScalarLength(_ lead: UInt8) -> Int {
    if lead < 0x80 { return 1 }
    if lead < 0xC0 { return 1 }
    if lead < 0xE0 { return 2 }
    if lead < 0xF0 { return 3 }
    if lead < 0xF8 { return 4 }
    return 1
}

private func isValidContinuation(_ buffer: [UInt8], from start: Int, count: Int) -> Bool {
    var index = start
    let end = start + count
    while index < end {
        let byte = buffer[index]
        if byte < 0x80 || byte > 0xBF { return false }
        index += 1
    }
    return true
}

private func hasSuffix(_ data: ArraySlice<UInt8>, _ suffix: [UInt8]) -> Bool {
    guard data.count >= suffix.count else { return false }
    var dataIndex = data.index(data.endIndex, offsetBy: -suffix.count)
    for byte in suffix {
        if data[dataIndex] != byte { return false }
        dataIndex = data.index(after: dataIndex)
    }
    return true
}

private func splitBytes(_ data: ArraySlice<UInt8>, on separator: UInt8) -> [ArraySlice<UInt8>] {
    var parts: [ArraySlice<UInt8>] = []
    var partStart = data.startIndex
    var index = data.startIndex
    while index < data.endIndex {
        if data[index] == separator {
            parts.append(data[partStart..<index])
            partStart = data.index(after: index)
        }
        index = data.index(after: index)
    }
    parts.append(data[partStart..<data.endIndex])
    return parts
}

/// First start-offset of `pattern` within `haystack`, or `nil`. A plain scan;
/// the patterns are the six-byte paste markers, so nothing subtler is warranted.
private func firstIndex(of pattern: [UInt8], in haystack: [UInt8]) -> Int? {
    guard !pattern.isEmpty, haystack.count >= pattern.count else { return nil }
    let last = haystack.count - pattern.count
    var start = 0
    while start <= last {
        var matched = true
        var offset = 0
        while offset < pattern.count {
            if haystack[start + offset] != pattern[offset] {
                matched = false
                break
            }
            offset += 1
        }
        if matched { return start }
        start += 1
    }
    return nil
}
