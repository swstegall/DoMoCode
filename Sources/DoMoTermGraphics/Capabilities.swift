// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/terminal-image.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. `detectCapabilities`, the cached
// capability lookup, and the cell-pixel-size state map 1:1 to terminal-image.ts;
// pi's module-level mutable `let`s become `Mutex`-guarded state so the process-
// global cache is safe to touch from the render actor and a background query.

import DoMoCore
import Foundation
import Synchronization

// MARK: - Types

/// The inline-image protocol a terminal speaks, or `nil` for none (text fallback).
public enum ImageProtocol: String, Sendable, Hashable {
    case kitty
    case iterm2
}

/// What a terminal supports. Only ``images`` is load-bearing for Phase 7.5; the
/// other two are carried for parity with pi (and future OSC 8 work).
public struct TerminalCapabilities: Sendable, Hashable {
    public var images: ImageProtocol?
    public var trueColor: Bool
    public var hyperlinks: Bool

    public init(images: ImageProtocol?, trueColor: Bool, hyperlinks: Bool) {
        self.images = images
        self.trueColor = trueColor
        self.hyperlinks = hyperlinks
    }
}

/// The pixel size of one terminal cell — needed to convert an image's pixel
/// dimensions into a cell footprint. Defaults to pi's `9 × 18`; whoever owns the
/// tty refines it with an actual terminal query (Phase 7.5b).
public struct CellDimensions: Sendable, Hashable {
    public var widthPx: Int
    public var heightPx: Int

    public init(widthPx: Int, heightPx: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
    }

    /// pi's default when the terminal never answers the cell-size query.
    public static let `default` = CellDimensions(widthPx: 9, heightPx: 18)
}

// MARK: - Process-global state

/// The lazily-detected, cached capabilities. `Mutex` (not a bare global `var`) so
/// the render actor and a startup detection can share it without a data race.
private let capabilitiesCache = Mutex<TerminalCapabilities?>(nil)
/// The current cell pixel size, refined by a terminal query.
private let cellDimensionsBox = Mutex<CellDimensions>(.default)

/// The current cell pixel size.
public func getCellDimensions() -> CellDimensions {
    cellDimensionsBox.withLock { $0 }
}

/// Set the cell pixel size (called after a terminal cell-size query resolves).
public func setCellDimensions(_ dimensions: CellDimensions) {
    cellDimensionsBox.withLock { $0 = dimensions }
}

/// The cached capabilities, detecting once on first use.
public func getCapabilities() -> TerminalCapabilities {
    capabilitiesCache.withLock { slot in
        if let cached = slot { return cached }
        let detected = detectCapabilities()
        slot = detected
        return detected
    }
}

/// Clear the capability cache (re-detect on next ``getCapabilities()``).
public func resetCapabilitiesCache() {
    capabilitiesCache.withLock { $0 = nil }
}

/// Force the cached capabilities — the test seam pi uses to exercise both the
/// image and no-image paths without a real terminal.
public func setCapabilities(_ capabilities: TerminalCapabilities) {
    capabilitiesCache.withLock { $0 = capabilities }
}

// MARK: - Detection

/// Detect a terminal's capabilities by environment sniffing, in pi's exact branch
/// order (tmux/screen first — they force `images: nil` because graphics are
/// unreliable through a multiplexer — then the graphics-capable emulators, then
/// the known text-only ones).
///
/// `environment` is injectable so both code paths are unit-testable without
/// mutating the process environment (pi mutates `process.env` in its tests; a
/// parameter is the Swift-clean equivalent). `tmuxForwardsHyperlink` only affects
/// the `hyperlinks` field under tmux and defaults conservative-false — the image
/// result under tmux is `nil` regardless, so Phase 7.5 needs no tmux subprocess.
public func detectCapabilities(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    tmuxForwardsHyperlink: () -> Bool = { false }
) -> TerminalCapabilities {
    func value(_ key: String) -> String { (environment[key] ?? "").lowercased() }
    // pi checks `process.env.X` for truthiness, and JS treats an empty string as
    // falsy — so a var set to "" counts as ABSENT, not present. Match that (a bare
    // `environment[key] != nil` would wrongly treat `KITTY_WINDOW_ID=""` as kitty).
    func present(_ key: String) -> Bool { !(environment[key] ?? "").isEmpty }
    let termProgram = value("TERM_PROGRAM")
    let terminalEmulator = value("TERMINAL_EMULATOR")
    let term = value("TERM")
    let colorTerm = value("COLORTERM")
    let hasTrueColorHint = colorTerm == "truecolor" || colorTerm == "24bit"

    // Image protocols are unreliable under tmux, so leave images nil.
    if present("TMUX") || term.hasPrefix("tmux") {
        return TerminalCapabilities(images: nil, trueColor: hasTrueColorHint, hyperlinks: tmuxForwardsHyperlink())
    }
    // screen does not forward OSC 8, so keep hyperlinks off.
    if term.hasPrefix("screen") {
        return TerminalCapabilities(images: nil, trueColor: hasTrueColorHint, hyperlinks: false)
    }
    if present("KITTY_WINDOW_ID") || termProgram == "kitty" {
        return TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true)
    }
    if termProgram == "ghostty" || term.contains("ghostty") || present("GHOSTTY_RESOURCES_DIR") {
        return TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true)
    }
    if present("WEZTERM_PANE") || termProgram == "wezterm" {
        return TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true)
    }
    // Warp supports the Kitty graphics protocol and OSC 8 hyperlinks.
    if termProgram == "warpterminal" || present("WARP_SESSION_ID") || present("WARP_TERMINAL_SESSION_UUID") {
        return TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true)
    }
    if present("ITERM_SESSION_ID") || termProgram == "iterm.app" {
        return TerminalCapabilities(images: .iterm2, trueColor: true, hyperlinks: true)
    }
    if present("WT_SESSION") {
        return TerminalCapabilities(images: nil, trueColor: true, hyperlinks: true)
    }
    if termProgram == "vscode" {
        return TerminalCapabilities(images: nil, trueColor: true, hyperlinks: true)
    }
    if termProgram == "alacritty" {
        return TerminalCapabilities(images: nil, trueColor: true, hyperlinks: true)
    }
    if terminalEmulator == "jetbrains-jediterm" {
        return TerminalCapabilities(images: nil, trueColor: true, hyperlinks: false)
    }
    // Unknown terminal: be conservative — text fallback.
    return TerminalCapabilities(images: nil, trueColor: hasTrueColorHint, hyperlinks: false)
}
