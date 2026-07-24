// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// Capability detection, driven by injected environment dictionaries (pi mutates
// process.env; a parameter is the clean equivalent). Every branch of pi's
// detection matrix is pinned, in order.

import DoMoTermGraphics
import Testing

@Suite("Terminal capability detection", .serialized)
struct CapabilitiesTests {
    private func detect(_ env: [String: String]) -> TerminalCapabilities {
        detectCapabilities(environment: env, tmuxForwardsHyperlink: { true })
    }

    @Test("tmux forces images off (before any graphics terminal) and consults the hyperlink probe")
    func tmux() {
        // Even with a kitty env present, tmux wins because it is checked first.
        let caps = detect(["TMUX": "/tmp/tmux-1000/default,123,0", "KITTY_WINDOW_ID": "1", "COLORTERM": "truecolor"])
        #expect(caps.images == nil)
        #expect(caps.trueColor)             // from COLORTERM hint
        #expect(caps.hyperlinks)            // the injected probe returned true
    }

    @Test("screen forces images off and hyperlinks off")
    func screen() {
        let caps = detect(["TERM": "screen-256color"])
        #expect(caps.images == nil)
        #expect(!caps.hyperlinks)
    }

    @Test("Kitty, Ghostty, WezTerm, and Warp all map to the kitty protocol")
    func kittyFamily() {
        #expect(detect(["KITTY_WINDOW_ID": "1"]).images == .kitty)
        #expect(detect(["TERM_PROGRAM": "kitty"]).images == .kitty)
        #expect(detect(["TERM_PROGRAM": "ghostty"]).images == .kitty)
        #expect(detect(["GHOSTTY_RESOURCES_DIR": "/x"]).images == .kitty)
        #expect(detect(["TERM": "xterm-ghostty"]).images == .kitty)
        #expect(detect(["WEZTERM_PANE": "0"]).images == .kitty)
        #expect(detect(["TERM_PROGRAM": "wezterm"]).images == .kitty)
        #expect(detect(["TERM_PROGRAM": "WarpTerminal"]).images == .kitty)
        #expect(detect(["WARP_SESSION_ID": "abc"]).images == .kitty)
    }

    @Test("iTerm2 maps to the iterm2 protocol")
    func iterm2() {
        #expect(detect(["ITERM_SESSION_ID": "w0t0p0"]).images == .iterm2)
        #expect(detect(["TERM_PROGRAM": "iTerm.app"]).images == .iterm2)
    }

    @Test("Windows Terminal, VSCode, Alacritty, JediTerm, and unknown terminals have no image protocol")
    func noImageTerminals() {
        #expect(detect(["WT_SESSION": "x"]).images == nil)
        #expect(detect(["TERM_PROGRAM": "vscode"]).images == nil)
        #expect(detect(["TERM_PROGRAM": "alacritty"]).images == nil)
        #expect(detect(["TERMINAL_EMULATOR": "JetBrains-JediTerm"]).images == nil)
        #expect(detect(["TERM": "xterm-256color"]).images == nil)   // unknown
        #expect(detect([:]).images == nil)                          // empty
    }

    @Test("An empty-string env var is treated as absent (JS-falsiness parity with pi)")
    func emptyEnvIsAbsent() {
        #expect(detect(["KITTY_WINDOW_ID": ""]).images == nil)              // "" -> absent -> not kitty
        #expect(detect(["ITERM_SESSION_ID": ""]).images == nil)
        #expect(detect(["TMUX": "", "KITTY_WINDOW_ID": "1"]).images == .kitty)   // empty TMUX doesn't suppress
    }

    @Test("The COLORTERM truecolor hint is honored for unknown terminals")
    func trueColorHint() {
        #expect(detect(["COLORTERM": "truecolor"]).trueColor)
        #expect(detect(["COLORTERM": "24bit"]).trueColor)
        #expect(!detect(["COLORTERM": "256"]).trueColor)
    }

    @Test("setCapabilities overrides the cache and resetCapabilitiesCache clears it")
    func cacheOverride() {
        setCapabilities(TerminalCapabilities(images: .kitty, trueColor: true, hyperlinks: true))
        #expect(getCapabilities().images == .kitty)
        setCapabilities(TerminalCapabilities(images: nil, trueColor: false, hyperlinks: false))
        #expect(getCapabilities().images == nil)
        resetCapabilitiesCache()   // leave the cache clean for other tests
    }

    @Test("Cell dimensions default to 9x18 and are settable")
    func cellDimensions() {
        setCellDimensions(.default)
        #expect(getCellDimensions() == CellDimensions(widthPx: 9, heightPx: 18))
        setCellDimensions(CellDimensions(widthPx: 10, heightPx: 20))
        #expect(getCellDimensions() == CellDimensions(widthPx: 10, heightPx: 20))
        setCellDimensions(.default)   // restore
    }
}
