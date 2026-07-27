// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Mouse report decoding. pi never reads the mouse — its inline model leaves the
// terminal's own selection and scrollback in charge — so this has no upstream to
// port from; it is the decoder side of the `?1000h`/`?1006h` modes the full-screen
// lifecycle enables, and it exists because the alternate screen has no scrollback
// for the terminal to scroll on the user's behalf. Once the app owns the whole
// page, the wheel is the app's to handle.
//
// Two encodings arrive in practice and ``StdinFramer`` already frames both as
// whole sequences:
//
//  - **SGR** (`ESC [ < b ; x ; y M|m`), enabled by `?1006h`. Coordinates are
//    decimal and unbounded, and press (`M`) and release (`m`) are distinguished by
//    the final byte. This is what every terminal worth supporting sends once
//    `?1006h` is set.
//  - **X10** (`ESC [ M` + three bytes, each offset by 32), the pre-SGR default.
//    Decoded too, because a terminal that ignored `?1006h` still reports in it,
//    and a wheel event that arrived undecoded would be typed into the prompt as
//    garbage. Its coordinates saturate past column/row 223 — a limitation of the
//    encoding, not of this decoder.

// MARK: - Mouse event

/// One decoded mouse report, in 0-based screen coordinates.
public struct MouseEvent: Sendable, Hashable {
    /// What the report says happened.
    public enum Kind: Sendable, Hashable {
        case press
        case release
        /// Pointer motion (only reported when a motion mode is enabled).
        case move
        case scrollUp
        case scrollDown
        case scrollLeft
        case scrollRight
    }

    /// Which button, for press/release/move. Wheel events report ``Button/none``.
    public enum Button: Sendable, Hashable {
        case left
        case middle
        case right
        case none
    }

    public var kind: Kind
    public var button: Button
    /// 0-based column, left edge = 0.
    public var column: Int
    /// 0-based row, top edge = 0.
    public var row: Int
    public var shift: Bool
    public var alt: Bool
    public var ctrl: Bool

    public init(
        kind: Kind,
        button: Button = .none,
        column: Int,
        row: Int,
        shift: Bool = false,
        alt: Bool = false,
        ctrl: Bool = false
    ) {
        self.kind = kind
        self.button = button
        self.column = column
        self.row = row
        self.shift = shift
        self.alt = alt
        self.ctrl = ctrl
    }

    /// Whether this is a wheel event in either axis — the events a scrollable pane
    /// cares about.
    public var isScroll: Bool {
        switch kind {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight: return true
        case .press, .release, .move: return false
        }
    }
}

// MARK: - Decoding

/// Decode a framed input sequence as a mouse report, or `nil` if it is not one.
///
/// Accepts both the SGR and X10 encodings. `data` must be a WHOLE sequence as
/// ``StdinFramer`` emits it; a partial report decodes to `nil` rather than to a
/// wrong position.
public func decodeMouseEvent(_ data: [UInt8]) -> MouseEvent? {
    decodeSGRMouseEvent(data) ?? decodeX10MouseEvent(data)
}

/// `ESC [ < b ; x ; y M|m` — the `?1006h` encoding.
private func decodeSGRMouseEvent(_ data: [UInt8]) -> MouseEvent? {
    // Shortest possible report is `ESC [ < 0 ; 1 ; 1 M` = 9 bytes.
    guard data.count >= 9,
        data[0] == 0x1b, data[1] == 0x5b, data[2] == 0x3c
    else { return nil }

    let final = data[data.count - 1]
    guard final == 0x4d || final == 0x6d else { return nil }   // 'M' press, 'm' release

    // Three semicolon-separated decimal fields between `<` and the final byte.
    var fields: [Int] = []
    var value = 0
    var sawDigit = false
    for byte in data[3..<(data.count - 1)] {
        switch byte {
        case 0x30...0x39:
            // Bound the accumulator: a pathological report must not overflow.
            if value < 1_000_000 { value = value * 10 + Int(byte - 0x30) }
            sawDigit = true
        case 0x3b:   // ';'
            guard sawDigit else { return nil }
            fields.append(value)
            value = 0
            sawDigit = false
        default:
            return nil
        }
    }
    guard sawDigit else { return nil }
    fields.append(value)
    guard fields.count == 3 else { return nil }

    // SGR coordinates are 1-based; a terminal that sends 0 is clamped, not wrapped.
    return makeEvent(
        buttonCode: fields[0],
        column: max(0, fields[1] - 1),
        row: max(0, fields[2] - 1),
        isRelease: final == 0x6d
    )
}

/// `ESC [ M` + three bytes, each biased by 32 — the pre-SGR encoding.
private func decodeX10MouseEvent(_ data: [UInt8]) -> MouseEvent? {
    guard data.count == 6, data[0] == 0x1b, data[1] == 0x5b, data[2] == 0x4d else { return nil }
    let code = Int(data[3]) - 32
    guard code >= 0 else { return nil }
    // X10 biases coordinates by 33 (32 + 1 for the 1-based origin).
    let column = max(0, Int(data[4]) - 33)
    let row = max(0, Int(data[5]) - 33)
    // X10 has no separate release code: button bits `3` means "some button came up".
    let isRelease = (code & 0b11) == 3 && (code & 64) == 0
    return makeEvent(buttonCode: code, column: column, row: row, isRelease: isRelease)
}

/// Turn a decoded button code plus position into an event.
///
/// Bit layout, shared by both encodings: the low two bits select the button,
/// `4` is shift, `8` is alt/meta, `16` is ctrl, `32` marks motion, and `64` marks
/// a wheel event (where the low two bits become the wheel direction).
private func makeEvent(buttonCode: Int, column: Int, row: Int, isRelease: Bool) -> MouseEvent {
    let shift = buttonCode & 4 != 0
    let alt = buttonCode & 8 != 0
    let ctrl = buttonCode & 16 != 0
    let isMotion = buttonCode & 32 != 0
    let isWheel = buttonCode & 64 != 0
    let low = buttonCode & 0b11

    if isWheel {
        let kind: MouseEvent.Kind
        switch low {
        case 0: kind = .scrollUp
        case 1: kind = .scrollDown
        case 2: kind = .scrollLeft
        default: kind = .scrollRight
        }
        return MouseEvent(kind: kind, button: .none, column: column, row: row, shift: shift, alt: alt, ctrl: ctrl)
    }

    let button: MouseEvent.Button
    switch low {
    case 0: button = .left
    case 1: button = .middle
    case 2: button = .right
    default: button = .none
    }
    let kind: MouseEvent.Kind = isRelease ? .release : (isMotion ? .move : .press)
    return MouseEvent(kind: kind, button: button, column: column, row: row, shift: shift, alt: alt, ctrl: ctrl)
}
