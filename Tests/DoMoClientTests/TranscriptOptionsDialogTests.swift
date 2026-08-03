// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoHarness
import DoMoTUI
import Testing
@testable import DoMoClient

@MainActor
@Suite("Transcript options dialog")
struct TranscriptOptionsDialogTests {
    @Test("toggles content groups and submits shared formatter options")
    func togglesAndSubmits() {
        let dialog = TranscriptOptionsDialog(options: .copy)
        var submitted: TranscriptFormatOptions?
        dialog.onSubmit = { submitted = $0 }

        dialog.handleInput([0x20]) // remove reasoning
        dialog.handleInput([0x1b, 0x5b, 0x42]) // tool row
        dialog.handleInput([0x20]) // remove tools
        dialog.handleInput([0x1b, 0x5b, 0x42]) // metadata row
        dialog.handleInput([0x20]) // include metadata
        dialog.handleInput([0x0d])

        #expect(submitted == TranscriptFormatOptions(
            includeReasoning: false,
            includeToolCalls: false,
            includeToolResults: false,
            includeMetadata: true
        ))
    }

    @Test("rendering stays clipped and Escape cancels")
    func rendersSafelyAndCancels() {
        let dialog = TranscriptOptionsDialog()
        var cancelled = false
        dialog.onCancel = { cancelled = true }

        let lines = dialog.render(width: 18)
        #expect(lines.allSatisfy { visibleWidth($0) <= 18 })
        dialog.handleInput([0x1b])
        #expect(cancelled)
    }
}
