// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The clipboard primitives are pure by design — they build bytes and name
// commands — so every one of them is asserted here against fixed fixtures, with
// the availability probe injected from a `Set<String>` and never from the
// filesystem. Two properties matter more than the rest:
//
//  * an oversized payload must be REFUSED, not truncated. A truncated OSC 52 is
//    not a failed copy, it is a WRONG clipboard, and the user finds out by pasting
//    half a command into a shell.
//  * the tmux wrapping must contain no bare `ESC ]`, or tmux consumes the escape
//    itself and the clipboard never sees it.

import DoMoTermIO
import Foundation
import Testing

@Suite("Clipboard primitives")
struct ClipboardTests {

    private let escape = "\u{1b}"
    private let bell = "\u{07}"

    private func text(_ bytes: [UInt8]?) -> String? {
        bytes.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Multiplexer detection

    @Test("TMUX in the environment wins over TERM")
    func detectTmuxFromEnvironment() {
        #expect(TerminalMultiplexer.detect(environment: ["TMUX": "/tmp/tmux-501/default,1,0"]) == .tmux)
        // tmux commonly sets TERM=screen-256color; the TMUX variable is the truth.
        #expect(
            TerminalMultiplexer.detect(environment: [
                "TMUX": "/tmp/tmux-501/default,1,0",
                "TERM": "screen-256color",
            ]) == .tmux
        )
    }

    @Test("TERM names the multiplexer when TMUX is absent")
    func detectFromTerm() {
        #expect(TerminalMultiplexer.detect(environment: ["TERM": "screen-256color"]) == .screen)
        #expect(TerminalMultiplexer.detect(environment: ["TERM": "tmux-256color"]) == .tmux)
        #expect(TerminalMultiplexer.detect(environment: ["TERM": "xterm-256color"]) == .none)
        #expect(TerminalMultiplexer.detect(environment: [:]) == .none)
    }

    @Test("An exported-but-empty TMUX is not a multiplexer")
    func emptyTmuxIsNotTmux() {
        // A detached shell inherits TMUX as an empty string; wrapping for a
        // passthrough that is not there would put raw DCS bytes on the screen.
        #expect(TerminalMultiplexer.detect(environment: ["TMUX": ""]) == .none)
        #expect(TerminalMultiplexer.detect(environment: ["TMUX": "", "TERM": "xterm"]) == .none)
    }

    // MARK: OSC 52 encoding

    @Test("The plain OSC 52 form is ESC ] 52 ; c ; <base64> BEL")
    func plainOSC52() {
        #expect(text(osc52CopySequence(Array("hi".utf8))) == "\(escape)]52;c;aGk=\(bell)")
        #expect(text(osc52CopySequence([])) == "\(escape)]52;c;\(bell)")
    }

    @Test("Base64 is Foundation's, and round-trips arbitrary UTF-8")
    func base64RoundTrip() {
        let original = String(repeating: "héllo\tworld ✅ 漢字\n", count: 200)
        let sequence = try! #require(osc52CopySequence(Array(original.utf8)))
        let rendered = String(decoding: sequence, as: UTF8.self)
        let payload = String(rendered.dropFirst("\(escape)]52;c;".count).dropLast())
        let decoded = try! #require(Data(base64Encoded: payload))
        #expect(String(decoding: decoded, as: UTF8.self) == original)
        #expect(original.utf8.count > 4096, "the fixture must exceed a single read buffer")
    }

    @Test("The tmux form is a DCS passthrough with every ESC doubled and no bare ESC ]")
    func tmuxWrapping() {
        let rendered = try! #require(text(osc52CopySequence(Array("hi".utf8), multiplexer: .tmux)))
        #expect(rendered == "\(escape)Ptmux;\(escape)\(escape)]52;c;aGk=\(bell)\(escape)\\")
        #expect(rendered.hasPrefix("\(escape)Ptmux;"))
        #expect(rendered.hasSuffix("\(escape)\\"))
        // Every ESC between the wrapper's own bookends is doubled, and undoubling
        // the payload reproduces the plain sequence exactly. A single ESC in there
        // would be eaten by tmux itself and never reach the terminal that owns the
        // clipboard — the doubling is the whole mechanism.
        let inner = String(rendered.dropFirst("\(escape)Ptmux;".count).dropLast(2))
        #expect(inner.replacingOccurrences(of: "\(escape)\(escape)", with: escape)
            == text(osc52CopySequence(Array("hi".utf8))))
        var scanner = Substring(inner)
        while let index = scanner.firstIndex(of: "\u{1b}") {
            let next = scanner.index(after: index)
            #expect(next < scanner.endIndex && scanner[next] == "\u{1b}", "found an undoubled ESC")
            scanner = scanner[scanner.index(after: next)...]
        }
    }

    @Test("The screen form is the same DCS wrapper without the doubling")
    func screenWrapping() {
        let rendered = try! #require(text(osc52CopySequence(Array("hi".utf8), multiplexer: .screen)))
        #expect(rendered == "\(escape)P\(escape)]52;c;aGk=\(bell)\(escape)\\")
        #expect(!rendered.contains("\(escape)\(escape)"))
    }

    // MARK: Size limits

    @Test("A payload over the plain limit is refused, never truncated")
    func oversizedPayloadIsRefused() {
        // base64 is 4 bytes per 3, so this is the smallest raw size that overflows.
        let overflowing = Array(repeating: UInt8(ascii: "x"), count: (osc52PayloadLimit / 4) * 3 + 3)
        #expect(osc52CopySequence(overflowing) == nil)

        let fitting = Array(repeating: UInt8(ascii: "x"), count: (osc52PayloadLimit / 4) * 3)
        let sequence = try! #require(osc52CopySequence(fitting))
        // And what it DOES emit carries the whole payload: a refusal is the only
        // way this function ever declines, so anything returned is complete.
        let rendered = String(decoding: sequence, as: UTF8.self)
        let payload = String(rendered.dropFirst("\(escape)]52;c;".count).dropLast())
        #expect(Data(base64Encoded: payload)?.count == fitting.count)
    }

    @Test("A multiplexer has a strictly smaller budget, and the same payload can pass one and fail the other")
    func multiplexedLimitIsSmaller() {
        #expect(osc52MultiplexedPayloadLimit < osc52PayloadLimit)
        // Sized to sit between the two limits: fine unwrapped, refused through tmux,
        // where the passthrough buffer is what would truncate it.
        let between = Array(repeating: UInt8(ascii: "y"), count: (osc52MultiplexedPayloadLimit / 4) * 3 + 3)
        #expect(osc52CopySequence(between) != nil)
        #expect(osc52CopySequence(between, multiplexer: .tmux) == nil)
        #expect(osc52CopySequence(between, multiplexer: .screen) == nil)
    }

    // MARK: Local helper resolution

    private func resolve(_ environment: [String: String], available: Set<String>) -> ClipboardCommand? {
        localClipboardCommand(environment: environment, isAvailable: { available.contains($0) })
    }

    @Test("pbcopy wins wherever it exists")
    func darwinResolvesToPbcopy() {
        let command = try! #require(resolve(["PATH": "/usr/bin"], available: ["pbcopy"]))
        #expect(command.program == "pbcopy")
        #expect(command.arguments.isEmpty)
        #expect(command.shellCommand == "pbcopy")
    }

    @Test("Wayland prefers wl-copy over an available X helper")
    func waylandResolvesToWlCopy() {
        let command = try! #require(
            resolve(["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"], available: ["wl-copy", "xclip"])
        )
        #expect(command.program == "wl-copy")
    }

    @Test("X11 prefers xclip, and falls back to xsel when xclip is missing")
    func x11Resolution() {
        let xclip = try! #require(resolve(["DISPLAY": ":0"], available: ["xclip", "xsel"]))
        #expect(xclip.program == "xclip")
        #expect(xclip.shellCommand == "xclip -selection clipboard")

        let xsel = try! #require(resolve(["DISPLAY": ":0"], available: ["xsel"]))
        #expect(xsel.program == "xsel")
        #expect(xsel.shellCommand == "xsel --clipboard --input")
    }

    @Test("With no display variable set, any installed helper is still tried")
    func headlessStillTriesInstalledHelpers() {
        // An ssh session with no forwarded display may still reach a helper, and the
        // cost of being wrong is one refused spawn.
        let command = try! #require(resolve([:], available: ["xsel"]))
        #expect(command.program == "xsel")
    }

    @Test("Nothing installed resolves to nil, which is OSC 52's cue")
    func nothingAvailableResolvesToNil() {
        #expect(resolve(["DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0"], available: []) == nil)
        #expect(resolve([:], available: ["emacs", "vim"]) == nil)
    }

    @Test("An empty display variable does not count as set")
    func emptyDisplayIsNotSet() {
        // `DISPLAY=` exported empty is what a headless session inherits; treating it
        // as set would pick an X helper that cannot connect to anything.
        let command = try! #require(resolve(["DISPLAY": "", "WAYLAND_DISPLAY": ""], available: ["wl-copy", "xsel"]))
        #expect(command.program == "wl-copy", "the fallback order, not the DISPLAY branch")
    }

    @Test("Every resolved command carries its arguments on the command line and its data on stdin")
    func commandsAreLiteralAndArgumentOnly() {
        // The contract that makes arbitrary selected text safe: nothing in the
        // command string is derived from user data, so there is nothing to quote.
        for available in [Set(["pbcopy"]), Set(["wl-copy"]), Set(["xclip"]), Set(["xsel"])] {
            let command = try! #require(resolve(["DISPLAY": ":0"], available: available))
            #expect(!command.shellCommand.contains("$"))
            #expect(!command.shellCommand.contains("\""))
            #expect(!command.shellCommand.contains("'"))
            #expect(command.shellCommand == ([command.program] + command.arguments).joined(separator: " "))
        }
    }
}
