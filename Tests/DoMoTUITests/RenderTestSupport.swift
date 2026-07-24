// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI

/// A `RenderTarget` that captures written bytes instead of touching a terminal.
///
/// The seam that makes the whole pipeline oracle-testable: drive a real `TUI`
/// against this, drain the bytes each frame, and feed them to a `ScreenOracle`
/// exactly as a terminal would receive the stream.
@MainActor
final class CaptureTarget: RenderTarget {
    var columns: Int
    var rows: Int
    private var buffer = ""

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    func write(_ bytes: String) {
        buffer += bytes
    }

    /// Return everything written since the last drain, and clear.
    func drain() -> String {
        defer { buffer = "" }
        return buffer
    }
}

/// A component whose lines are a settable array — the test stand-in for real
/// content, so a test can mutate what a frame renders and re-render.
@MainActor
final class LinesComponent: Component {
    var lines: [String]

    init(_ lines: [String]) {
        self.lines = lines
    }

    func render(width: Int) -> [String] {
        lines
    }
}

/// A focusable component that records the input it receives and emits a cursor
/// marker at a fixed column when focused.
@MainActor
final class FocusableProbe: @MainActor Focusable {
    var focused = false
    var received: [[UInt8]] = []
    var markerColumn: Int?
    var label: String
    var wantsKeyRelease: Bool = false

    init(_ label: String, markerColumn: Int? = nil) {
        self.label = label
        self.markerColumn = markerColumn
    }

    func render(width: Int) -> [String] {
        guard focused, let markerColumn else { return [label] }
        let prefix = String(label.prefix(markerColumn))
        return [prefix + cursorMarker + String(label.dropFirst(markerColumn))]
    }

    func handleInput(_ data: [UInt8]) {
        received.append(data)
    }
}

@MainActor
extension ScreenOracle {
    /// Render one frame through `tui` and feed the emitted bytes into this oracle.
    func drive(_ tui: TUI, from target: CaptureTarget) throws {
        try tui.renderSync()
        feed(target.drain())
    }
}
