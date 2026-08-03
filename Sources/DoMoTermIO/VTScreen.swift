// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// A compact style attached to one emulated cell.
public struct VTStyle: Sendable, Hashable, Codable {
    public enum Color: Sendable, Hashable, Codable {
        case `default`
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    public var foreground: Color
    public var background: Color
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var inverse: Bool

    public init(
        foreground: Color = .default,
        background: Color = .default,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        inverse: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
    }

    public static let plain = VTStyle()
}

/// One cell in a ``VTScreen`` grid.
public struct VTCell: Sendable, Hashable, Codable {
    public var character: String
    public var style: VTStyle
    public var continuation: Bool

    public init(character: String = " ", style: VTStyle = .plain, continuation: Bool = false) {
        self.character = character
        self.style = style
        self.continuation = continuation
    }
}

/// A small VT parser and screen model for foreign interactive programs.
///
/// This is intentionally separate from the renderer's output scanner. The
/// renderer scanner only needs to measure DoMoCode's own SGR/cursor output; this
/// type must interpret output produced by programs the model launches, including
/// cursor movement, erasure, alternate-screen switches, SGR, OSC titles, and
/// common line-editing controls.
public struct VTScreen: Sendable, Hashable {
    private struct Buffer: Sendable, Hashable {
        var cells: [[VTCell]]
        var row: Int = 0
        var column: Int = 0
        var wrapPending = false
        var savedRow = 0
        var savedColumn = 0

        init(columns: Int, rows: Int) {
            cells = Array(
                repeating: Array(repeating: VTCell(), count: columns),
                count: rows
            )
        }
    }

    private enum ParserState: Sendable, Hashable {
        case ground
        case escape
        case csi
        case osc
        case oscEscape
        case ignoreString
        case ignoreStringEscape
        case charset
    }

    public let columns: Int
    public let rows: Int
    public private(set) var cursorVisible = true
    public private(set) var alternateScreen = false
    public private(set) var title: String?

    private var primary: Buffer
    private var alternate: Buffer?
    private var style = VTStyle.plain
    private var state: ParserState = .ground
    private var csiBytes: [UInt8] = []
    private var oscBytes: [UInt8] = []
    private var utf8Bytes: [UInt8] = []
    private var utf8Expected = 0
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabStops: Set<Int>

    private var buffer: Buffer {
        get { alternateScreen ? alternate! : primary }
        set {
            if alternateScreen { alternate = newValue } else { primary = newValue }
        }
    }

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.primary = Buffer(columns: max(1, columns), rows: max(1, rows))
        self.scrollBottom = max(0, rows - 1)
        self.tabStops = Set(stride(from: 0, to: max(1, columns), by: 8))
    }

    /// Feed raw PTY bytes. UTF-8 split across reads is retained until complete.
    public mutating func feed(_ bytes: [UInt8]) {
        for byte in bytes { consume(byte) }
    }

    public mutating func feed(_ text: String) {
        feed(Array(text.utf8))
    }

    public var cursor: (row: Int, column: Int) {
        let current = buffer
        return (current.row, current.column)
    }

    public func cell(row: Int, column: Int) -> VTCell? {
        guard (0..<rows).contains(row), (0..<columns).contains(column) else { return nil }
        return buffer.cells[row][column]
    }

    /// A line with trailing blank cells removed. This is the useful form for
    /// model-visible snapshots and leaves cell-level callers an exact grid via
    /// ``cell(row:column:)``.
    public func line(_ row: Int) -> String {
        guard (0..<rows).contains(row) else { return "" }
        var result = ""
        for cell in buffer.cells[row] {
            if cell.continuation { continue }
            result.append(cell.character)
        }
        return result.replacingTrailingSpaces()
    }

    public var text: String {
        (0..<rows).map(line).joined(separator: "\n")
    }

    // MARK: Parser

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            consumeGround(byte)
        case .escape:
            consumeEscape(byte)
        case .csi:
            csiBytes.append(byte)
            if (0x40...0x7e).contains(byte) { finishCSI(final: byte) }
        case .osc:
            if byte == 0x07 {
                finishOSC()
            } else if byte == 0x1b {
                state = .oscEscape
            } else if oscBytes.count < 16 * 1024 {
                oscBytes.append(byte)
            }
        case .oscEscape:
            if byte == 0x5c { finishOSC() }
            else { state = .osc }
        case .ignoreString:
            if byte == 0x1b { state = .ignoreStringEscape }
        case .ignoreStringEscape:
            state = byte == 0x5c ? .ground : .ignoreString
        case .charset:
            state = .ground
        }
    }

    private mutating func consumeGround(_ byte: UInt8) {
        switch byte {
        case 0x07:
            return // BEL: the inline surface owns any audible/visual bell policy.
        case 0x08:
            var current = buffer
            current.wrapPending = false
            current.column = max(0, current.column - 1)
            buffer = current
        case 0x09:
            tab()
        case 0x0a, 0x0b, 0x0c:
            lineFeed()
        case 0x0d:
            var current = buffer
            current.column = 0
            current.wrapPending = false
            buffer = current
        case 0x1b:
            flushInvalidUTF8()
            state = .escape
        case 0x20...0x7e:
            consumeUTF8(byte)
        default:
            if byte >= 0x80 { consumeUTF8(byte) }
        }
    }

    private mutating func consumeEscape(_ byte: UInt8) {
        switch byte {
        case 0x5b: // [
            csiBytes.removeAll(keepingCapacity: true)
            state = .csi
        case 0x5d: // ]
            oscBytes.removeAll(keepingCapacity: true)
            state = .osc
        case 0x50, 0x5e, 0x5f, 0x58: // DCS, PM, APC, SOS
            state = .ignoreString
        case 0x37:
            saveCursor()
            state = .ground
        case 0x38:
            restoreCursor()
            state = .ground
        case 0x44:
            lineFeed()
            state = .ground
        case 0x45:
            var current = buffer
            current.column = 0
            buffer = current
            lineFeed()
            state = .ground
        case 0x4d:
            reverseIndex()
            state = .ground
        case 0x63:
            reset()
        case 0x28, 0x29, 0x2a, 0x2b:
            state = .charset
        default:
            state = .ground
        }
    }

    private mutating func consumeUTF8(_ byte: UInt8) {
        if utf8Expected == 0 {
            switch byte {
            case 0x00...0x7f:
                write(String(UnicodeScalar(byte)))
            case 0xc2...0xdf:
                utf8Bytes = [byte]
                utf8Expected = 2
            case 0xe0...0xef:
                utf8Bytes = [byte]
                utf8Expected = 3
            case 0xf0...0xf4:
                utf8Bytes = [byte]
                utf8Expected = 4
            default:
                write("�")
            }
            return
        }

        guard (0x80...0xbf).contains(byte) else {
            flushInvalidUTF8()
            consumeGround(byte)
            return
        }
        utf8Bytes.append(byte)
        if utf8Bytes.count == utf8Expected {
            write(String(decoding: utf8Bytes, as: UTF8.self))
            utf8Bytes.removeAll(keepingCapacity: true)
            utf8Expected = 0
        }
    }

    private mutating func flushInvalidUTF8() {
        guard utf8Expected != 0 else { return }
        write("�")
        utf8Bytes.removeAll(keepingCapacity: true)
        utf8Expected = 0
    }

    private mutating func finishCSI(final: UInt8) {
        let bytes = csiBytes
        csiBytes.removeAll(keepingCapacity: true)
        state = .ground

        var parameters = bytes.dropLast()
        var privateMarker: UInt8?
        if let first = parameters.first, first == 0x3f || first == 0x3e || first == 0x21 {
            privateMarker = first
            parameters = parameters.dropFirst()
        } else {
            privateMarker = nil
        }
        let values = parameters.isEmpty
            ? []
            : parameters.split(separator: 0x3b, omittingEmptySubsequences: false).map {
                Int(String(decoding: $0, as: UTF8.self)) ?? 0
            }
        let first = values.first ?? 0
        switch final {
        case 0x41: moveCursor(row: -max(1, first), column: 0)
        case 0x42: moveCursor(row: max(1, first), column: 0)
        case 0x43: moveCursor(row: 0, column: max(1, first))
        case 0x44: moveCursor(row: 0, column: -max(1, first))
        case 0x45: moveCursor(row: -max(1, first), column: 0, columnStart: 0)
        case 0x46: moveCursor(row: max(1, first), column: 0, columnStart: 0)
        case 0x47: setColumn(max(1, first) - 1)
        case 0x48, 0x66:
            let row = max(1, values.first ?? 1) - 1
            let column = max(1, values.dropFirst().first ?? 1) - 1
            setCursor(row: row, column: column)
        case 0x64: setRow(max(1, first) - 1)
        case 0x4a: eraseDisplay(mode: first)
        case 0x4b: eraseLine(mode: first)
        case 0x6d: applySGR(values.isEmpty ? [0] : values)
        case 0x68, 0x6c:
            setMode(values, enabled: final == 0x68, privateMarker: privateMarker)
        case 0x73: saveCursor()
        case 0x75: restoreCursor()
        case 0x40: insertCharacters(max(1, first))
        case 0x50: deleteCharacters(max(1, first))
        case 0x58: eraseCharacters(max(1, first))
        case 0x4c: insertLines(max(1, first))
        case 0x4d: deleteLines(max(1, first))
        case 0x53: scroll(up: true, count: max(1, first))
        case 0x54: scroll(up: false, count: max(1, first))
        case 0x72: setScrollRegion(values)
        default:
            break
        }
    }

    private mutating func finishOSC() {
        let text = String(decoding: oscBytes, as: UTF8.self)
        oscBytes.removeAll(keepingCapacity: true)
        state = .ground
        guard let separator = text.firstIndex(of: ";") else { return }
        let command = text[..<separator]
        if command == "0" || command == "1" || command == "2" {
            title = String(text[text.index(after: separator)...])
        }
    }

    // MARK: Screen operations

    private mutating func write(_ text: String) {
        for scalar in text.unicodeScalars {
            let width = scalar.cellWidth
            guard width > 0 else {
                appendCombining(scalar)
                continue
            }
            var current = buffer
            if current.wrapPending {
                current.wrapPending = false
                buffer = current
                lineFeed()
                current = buffer
                current.column = 0
            }
            if current.column >= columns { current.column = columns - 1 }
            let string = String(scalar)
            current.cells[current.row][current.column] = VTCell(character: string, style: style)
            if width == 2, current.column + 1 < columns {
                current.cells[current.row][current.column + 1] = VTCell(
                    character: "",
                    style: style,
                    continuation: true
                )
            }
            if current.column + width >= columns {
                current.column = columns - 1
                current.wrapPending = true
            } else {
                current.column += width
            }
            buffer = current
        }
    }

    private mutating func appendCombining(_ scalar: UnicodeScalar) {
        var current = buffer
        let column = max(0, min(current.column - 1, columns - 1))
        guard !current.cells[current.row][column].continuation else { return }
        current.cells[current.row][column].character.append(String(scalar))
        buffer = current
    }

    private mutating func lineFeed() {
        var current = buffer
        current.wrapPending = false
        if current.row == scrollBottom {
            buffer = current
            scroll(up: true, count: 1)
        } else {
            current.row = min(rows - 1, current.row + 1)
            buffer = current
        }
    }

    private mutating func reverseIndex() {
        var current = buffer
        current.wrapPending = false
        if current.row == scrollTop {
            buffer = current
            scroll(up: false, count: 1)
        } else {
            current.row = max(0, current.row - 1)
            buffer = current
        }
    }

    private mutating func tab() {
        var current = buffer
        current.column = tabStops.first(where: { $0 > current.column }) ?? columns - 1
        current.wrapPending = false
        buffer = current
    }

    private mutating func moveCursor(row: Int, column: Int, columnStart: Int = 0) {
        var current = buffer
        current.row = max(scrollTop, min(scrollBottom, current.row + row))
        current.column = max(columnStart, min(columns - 1, current.column + column))
        current.wrapPending = false
        buffer = current
    }

    private mutating func setCursor(row: Int, column: Int) {
        var current = buffer
        current.row = max(0, min(rows - 1, row))
        current.column = max(0, min(columns - 1, column))
        current.wrapPending = false
        buffer = current
    }

    private mutating func setRow(_ row: Int) {
        var current = buffer
        current.row = max(0, min(rows - 1, row))
        current.wrapPending = false
        buffer = current
    }

    private mutating func setColumn(_ column: Int) {
        var current = buffer
        current.column = max(0, min(columns - 1, column))
        current.wrapPending = false
        buffer = current
    }

    private mutating func saveCursor() {
        var current = buffer
        current.savedRow = current.row
        current.savedColumn = current.column
        buffer = current
    }

    private mutating func restoreCursor() {
        var current = buffer
        current.row = max(0, min(rows - 1, current.savedRow))
        current.column = max(0, min(columns - 1, current.savedColumn))
        current.wrapPending = false
        buffer = current
    }

    private mutating func eraseDisplay(mode: Int) {
        var current = buffer
        switch mode {
        case 0:
            erase(cells: &current, from: current.row * columns + current.column, through: rows * columns - 1)
        case 1:
            erase(cells: &current, from: 0, through: current.row * columns + current.column)
        default:
            erase(cells: &current, from: 0, through: rows * columns - 1)
        }
        buffer = current
    }

    private mutating func eraseLine(mode: Int) {
        var current = buffer
        let start: Int
        let end: Int
        switch mode {
        case 0: start = current.column; end = columns - 1
        case 1: start = 0; end = current.column
        default: start = 0; end = columns - 1
        }
        for column in start...end { current.cells[current.row][column] = VTCell(style: style) }
        buffer = current
    }

    private func erase(cells: inout Buffer, from start: Int, through end: Int) {
        guard start <= end else { return }
        for index in start...end {
            cells.cells[index / columns][index % columns] = VTCell(style: style)
        }
    }

    private mutating func insertCharacters(_ count: Int) {
        var current = buffer
        let amount = min(count, columns - current.column)
        guard amount > 0 else { return }
        let row = current.row
        current.cells[row].insert(contentsOf: Array(repeating: VTCell(style: style), count: amount), at: current.column)
        current.cells[row].removeLast(amount)
        buffer = current
    }

    private mutating func deleteCharacters(_ count: Int) {
        var current = buffer
        let amount = min(count, columns - current.column)
        guard amount > 0 else { return }
        let row = current.row
        current.cells[row].removeSubrange(current.column..<(current.column + amount))
        current.cells[row].append(contentsOf: Array(repeating: VTCell(style: style), count: amount))
        buffer = current
    }

    private mutating func eraseCharacters(_ count: Int) {
        var current = buffer
        let end = min(columns, current.column + count)
        if current.column < end {
            for column in current.column..<end { current.cells[current.row][column] = VTCell(style: style) }
        }
        buffer = current
    }

    private mutating func insertLines(_ count: Int) {
        var current = buffer
        let amount = min(count, scrollBottom - current.row + 1)
        guard amount > 0, current.row >= scrollTop, current.row <= scrollBottom else { return }
        current.cells.insert(contentsOf: Array(repeating: Array(repeating: VTCell(), count: columns), count: amount), at: current.row)
        current.cells.removeSubrange((scrollBottom + 1)..<(scrollBottom + 1 + amount))
        buffer = current
    }

    private mutating func deleteLines(_ count: Int) {
        var current = buffer
        let amount = min(count, scrollBottom - current.row + 1)
        guard amount > 0, current.row >= scrollTop, current.row <= scrollBottom else { return }
        current.cells.removeSubrange(current.row..<(current.row + amount))
        current.cells.insert(contentsOf: Array(repeating: Array(repeating: VTCell(), count: columns), count: amount), at: scrollBottom + 1 - amount)
        buffer = current
    }

    private mutating func scroll(up: Bool, count: Int) {
        var current = buffer
        guard scrollTop <= scrollBottom else { return }
        for _ in 0..<count {
            if up {
                current.cells.remove(at: scrollTop)
                current.cells.insert(Array(repeating: VTCell(), count: columns), at: scrollBottom)
            } else {
                current.cells.remove(at: scrollBottom)
                current.cells.insert(Array(repeating: VTCell(), count: columns), at: scrollTop)
            }
        }
        buffer = current
    }

    private mutating func setScrollRegion(_ values: [Int]) {
        let top = max(1, values.first ?? 1) - 1
        let bottom = max(1, values.dropFirst().first ?? rows) - 1
        guard top < bottom, top >= 0, bottom < rows else {
            scrollTop = 0
            scrollBottom = rows - 1
            return
        }
        scrollTop = top
        scrollBottom = bottom
        setCursor(row: scrollTop, column: 0)
    }

    private mutating func applySGR(_ values: [Int]) {
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = .indexed(UInt8(value - 30))
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(UInt8(value - 40))
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(UInt8(value - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(value - 100 + 8))
            case 38, 48:
                let isForeground = value == 38
                if index + 2 < values.count, values[index + 1] == 5 {
                    let color = VTStyle.Color.indexed(UInt8(max(0, min(255, values[index + 2]))))
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 2
                } else if index + 4 < values.count, values[index + 1] == 2 {
                    let color = VTStyle.Color.rgb(
                        UInt8(max(0, min(255, values[index + 2]))),
                        UInt8(max(0, min(255, values[index + 3]))),
                        UInt8(max(0, min(255, values[index + 4])))
                    )
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private mutating func setMode(_ values: [Int], enabled: Bool, privateMarker: UInt8?) {
        guard privateMarker == 0x3f else { return }
        for value in values {
            switch value {
            case 25: cursorVisible = enabled
            case 47, 1047, 1049:
                if enabled { enterAlternateScreen() } else { leaveAlternateScreen() }
            default: break
            }
        }
    }

    private mutating func enterAlternateScreen() {
        guard !alternateScreen else { return }
        saveCursor()
        alternate = Buffer(columns: columns, rows: rows)
        alternateScreen = true
    }

    private mutating func leaveAlternateScreen() {
        guard alternateScreen else { return }
        alternateScreen = false
        alternate = nil
    }

    private mutating func reset() {
        primary = Buffer(columns: columns, rows: rows)
        alternate = nil
        alternateScreen = false
        cursorVisible = true
        title = nil
        style = .plain
        state = .ground
        csiBytes.removeAll(keepingCapacity: true)
        oscBytes.removeAll(keepingCapacity: true)
        utf8Bytes.removeAll(keepingCapacity: true)
        utf8Expected = 0
        scrollTop = 0
        scrollBottom = rows - 1
    }
}

private extension UnicodeScalar {
    var cellWidth: Int {
        switch value {
        case 0...0x1f, 0x7f...0x9f: return 0
        case 0x300...0x36f, 0x1ab0...0x1aff, 0x1dc0...0x1dff, 0x20d0...0x20ff, 0xfe20...0xfe2f:
            return 0
        case 0x1100...0x115f, 0x2329...0x232a, 0x2e80...0xa4cf, 0xac00...0xd7a3,
             0xf900...0xfaff, 0xfe10...0xfe19, 0xfe30...0xfe6f, 0xff00...0xff60,
             0xffe0...0xffe6, 0x1f300...0x1faff:
            return 2
        default:
            return 1
        }
    }
}

private extension String {
    func replacingTrailingSpaces() -> String {
        var result = self
        while result.last == " " { result.removeLast() }
        return result
    }
}
