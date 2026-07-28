// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Putting text on the user's clipboard from inside a full-screen TUI, which has
// no upstream in pi (pi never takes the mouse, so the terminal's own selection
// and its own copy are always available). Two mechanisms, deliberately both:
//
//  - **OSC 52** — the terminal-native "set clipboard" escape. It is the only
//    thing that works across ssh and inside a multiplexer, because the bytes ride
//    the same tty the UI is already painting on. It is also disabled by default
//    in several terminals (xterm without `allowWindowOps`, some VTE builds) and
//    needs `set -g set-clipboard on` under tmux, so it cannot be the only path.
//  - **A local helper** — `pbcopy`/`wl-copy`/`xclip`/`xsel`, fed on stdin. It is
//    the only thing that works when the terminal refuses OSC 52, and it is
//    useless when the terminal is on the other end of an ssh connection.
//
// Everything here is PURE: it builds byte sequences and names commands, and
// spawns nothing. The spawn lives in DoMoCLI, behind DoMoClient's `ClipboardSink`
// seam, so no UI target grows a subprocess dependency for a copy.

import Foundation

// MARK: - Multiplexer

/// A terminal multiplexer sitting between this process and the real terminal.
///
/// It matters for exactly one reason: a multiplexer owns the tty, so an OSC 52
/// written straight at it is consumed by the multiplexer instead of reaching the
/// terminal that owns the clipboard. The sequence has to be smuggled through the
/// multiplexer's DCS passthrough, and the wrapping differs per multiplexer.
public enum TerminalMultiplexer: Sendable, Hashable {
    case none
    case tmux
    case screen

    /// What `environment` says is between us and the terminal.
    ///
    /// `TMUX` is set by tmux for every process in a pane and is the strongest
    /// signal, so it is checked first; `TERM` is only consulted as a fallback,
    /// because a `TERM` of `screen-256color` is also what tmux sets when it is
    /// not configured with a `tmux-*` terminfo entry. An empty value counts as
    /// unset — an exported-but-empty `TMUX` is what a *detached* shell inherits.
    public static func detect(environment: [String: String]) -> TerminalMultiplexer {
        if let tmux = environment["TMUX"], !tmux.isEmpty { return .tmux }
        let term = environment["TERM"] ?? ""
        if term.hasPrefix("tmux") { return .tmux }
        if term.hasPrefix("screen") { return .screen }
        return .none
    }
}

// MARK: - OSC 52 limits

/// The largest base64 payload an unwrapped OSC 52 will carry.
///
/// There is no standard cap, but there are real ones. A terminal bounds its OSC
/// string parser — xterm's `maxStringParseSize` defaults to 1000 bytes and
/// SILENTLY TRUNCATES past it — so an oversized sequence does not fail, it
/// produces a *wrong* clipboard. Refusing to emit it, and letting the local
/// helper carry the copy instead, is the only honest option: a truncated paste
/// that looks plausible is worse than no paste at all.
public let osc52PayloadLimit = 100_000

/// The largest base64 payload an OSC 52 wrapped for a multiplexer will carry.
///
/// tmux's DCS passthrough buffer historically tops out just under 75 KB, and the
/// wrapping itself adds bytes, so the multiplexed budget is strictly smaller than
/// ``osc52PayloadLimit``.
public let osc52MultiplexedPayloadLimit = 74_994

// MARK: - OSC 52

/// The OSC 52 "set clipboard" sequence carrying `bytes`, or `nil` when the base64
/// payload exceeds the limit for this transport.
///
/// Plain form: `ESC ] 52 ; c ; <base64> BEL`. BEL rather than ST because it is the
/// form every terminal that implements OSC 52 accepts, and because it is what this
/// package's own escape scanner already treats as an OSC terminator — so a
/// sequence that somehow lands in a rendered row is measured as zero columns
/// rather than as text.
///
/// Under tmux the sequence is smuggled through the DCS passthrough
/// `ESC P tmux ; <inner> ESC \`, with every `ESC` inside `inner` DOUBLED — that
/// doubling is how tmux's passthrough parser distinguishes an escape belonging to
/// the payload from the `ESC \` that ends the passthrough. Under screen the same
/// DCS wrapper carries the payload undoubled.
///
/// `nil` is a refusal, never a truncation. See ``osc52PayloadLimit``.
///
/// - Note: For the user, not for the code — tmux additionally needs
///   `set -g set-clipboard on`, and many terminals ship OSC 52 *write* support
///   disabled. That is why a local helper is not optional.
public func osc52CopySequence(
    _ bytes: [UInt8],
    multiplexer: TerminalMultiplexer = .none
) -> [UInt8]? {
    let payload = Data(bytes).base64EncodedString()
    let limit = multiplexer == .none ? osc52PayloadLimit : osc52MultiplexedPayloadLimit
    guard payload.utf8.count <= limit else { return nil }

    let inner = "\u{1b}]52;c;" + payload + "\u{07}"
    switch multiplexer {
    case .none:
        return Array(inner.utf8)
    case .tmux:
        let escaped = inner.replacingOccurrences(of: "\u{1b}", with: "\u{1b}\u{1b}")
        return Array(("\u{1b}Ptmux;" + escaped + "\u{1b}\\").utf8)
    case .screen:
        return Array(("\u{1b}P" + inner + "\u{1b}\\").utf8)
    }
}

// MARK: - Local helper

/// A local clipboard helper: a program plus fixed arguments, fed the text on
/// STDIN.
///
/// The text never appears on a command line. That is the whole point of the stdin
/// contract and it is what makes the helper safe for arbitrary selected text —
/// quotes, newlines, `$(...)`, a stray `;` — with no quoting rules to get wrong.
public struct ClipboardCommand: Sendable, Hashable {
    public let program: String
    public let arguments: [String]

    public init(program: String, arguments: [String]) {
        self.program = program
        self.arguments = arguments
    }

    /// The `sh -c` form.
    ///
    /// Safe by construction: every token is a compile-time literal chosen by
    /// ``localClipboardCommand(environment:isAvailable:)``, and the user's data
    /// travels on stdin. A "configurable clipboard command" setting would turn
    /// this into an injection surface, which is why there is not one.
    public var shellCommand: String { ([program] + arguments).joined(separator: " ") }
}

/// Every helper this knows how to drive, in the order they are preferred when the
/// environment gives no better hint.
private let clipboardHelpers: [ClipboardCommand] = [
    ClipboardCommand(program: "pbcopy", arguments: []),
    ClipboardCommand(program: "wl-copy", arguments: []),
    ClipboardCommand(program: "xclip", arguments: ["-selection", "clipboard"]),
    ClipboardCommand(program: "xsel", arguments: ["--clipboard", "--input"]),
]

/// Resolve the platform's clipboard helper, or `nil` when none is reachable.
///
/// `isAvailable` answers "is this program on `PATH`", injected rather than probed
/// so this function is pure, deterministic and unit-testable with no filesystem
/// and no per-platform `#if` — `pbcopy` simply is not available off Darwin, and a
/// Linux box with no display server simply has no X helper, which the probe
/// already says. Preference order:
///
///   1. `pbcopy` — Darwin's system helper, and never present elsewhere.
///   2. `WAYLAND_DISPLAY` set → `wl-copy`.
///   3. `DISPLAY` set → `xclip -selection clipboard`, then `xsel --clipboard --input`.
///   4. Neither display variable set → the first of `wl-copy`/`xclip`/`xsel`
///      that exists. An ssh session with no forwarded display may still reach a
///      helper, and trying costs one refused spawn.
///
/// A `nil` result is not a failure: OSC 52 is then the only path, which is exactly
/// the right answer on a remote host.
public func localClipboardCommand(
    environment: [String: String],
    isAvailable: (String) -> Bool
) -> ClipboardCommand? {
    func named(_ program: String) -> ClipboardCommand? {
        guard let command = clipboardHelpers.first(where: { $0.program == program }) else { return nil }
        return isAvailable(program) ? command : nil
    }
    func isSet(_ key: String) -> Bool {
        guard let value = environment[key] else { return false }
        return !value.isEmpty
    }

    if let pbcopy = named("pbcopy") { return pbcopy }
    if isSet("WAYLAND_DISPLAY"), let wayland = named("wl-copy") { return wayland }
    if isSet("DISPLAY") {
        if let xclip = named("xclip") { return xclip }
        if let xsel = named("xsel") { return xsel }
    }
    return clipboardHelpers.first { $0.program != "pbcopy" && isAvailable($0.program) }
}
