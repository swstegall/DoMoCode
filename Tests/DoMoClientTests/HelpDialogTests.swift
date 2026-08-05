// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoHarness
import DoMoTermIO
import DoMoTUI
import Testing

@testable import DoMoClient

@MainActor
@Suite("Help dialog")
struct HelpDialogTests {
    @Test("Help is generated from bindings and commands and can scroll")
    func rendersScrollableReference() {
        let dialog = HelpDialog(
            commands: CommandRegistry.builtIn,
            keybindings: Keybindings(),
            globalShortcuts: [("^P", "open the palette")],
            viewportRows: 8
        )

        let initial = dialog.render(width: 72)
        #expect(initial.contains { $0.contains("GLOBAL SHORTCUTS") })
        #expect(initial.contains { $0.contains("^P") })
        #expect(initial.allSatisfy { visibleWidth($0) <= 72 })

        dialog.handleInput(Array("G".utf8))
        let bottom = dialog.render(width: 72)
        #expect(bottom.contains { $0.contains("WORKFLOWS") })
        #expect(bottom.contains { $0.contains("/workflow") })
        #expect(bottom.allSatisfy { visibleWidth($0) <= 72 })
    }

    @Test("Help closes through its cancel binding")
    func cancelFires() {
        let dialog = HelpDialog(
            commands: CommandRegistry.builtIn,
            globalShortcuts: [],
            viewportRows: 8
        )
        var cancelled = false
        dialog.onCancel = { cancelled = true }
        dialog.handleInput([0x1b])
        #expect(cancelled)
    }
}
