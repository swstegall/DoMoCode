// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI
import Testing

@testable import DoMoClient

@MainActor
@Suite("Dialog stack")
struct DialogStackTests {
    @Test("Unboxed dialogs reserve both border rows")
    func reservesFrameRows() {
        let dialog = SearchableSelectDialog(
            title: "Test",
            items: [SelectItem(value: "one", label: "one")]
        )
        let options = OverlayOptions(maxHeight: .absolute(7))
        let adjusted = DialogStack.optionsForFramedComponent(dialog, options: options)

        guard let adjusted, case .absolute(let height) = adjusted.maxHeight else {
            Issue.record("expected an absolute height")
            return
        }
        #expect(height == 9)
    }

    @Test("Explicitly boxed dialogs keep their existing height budget")
    func preservesExplicitBoxBudget() {
        let dialog = Box(
            SearchableSelectDialog(
                title: "Test",
                items: [SelectItem(value: "one", label: "one")]
            ),
            paddingX: 1
        )
        let options = OverlayOptions(maxHeight: .absolute(7))
        let adjusted = DialogStack.optionsForFramedComponent(dialog, options: options)

        guard let adjusted, case .absolute(let height) = adjusted.maxHeight else {
            Issue.record("expected an absolute height")
            return
        }
        #expect(height == 7)
    }

    @Test("A catalog picker inserts its selected tool on Tab and Enter")
    func toolCatalogInsertionBindings() {
        let dialog = SearchableSelectDialog(
            title: "Tools",
            items: [SelectItem(value: "read", label: "read")]
        )
        var inserted: [String] = []
        dialog.onInsert = { inserted.append($0.value) }
        dialog.onSelect = { inserted.append("enter:($0.value)") }

        dialog.handleInput([0x09])
        dialog.handleInput([0x0d])

        #expect(inserted == ["read", "enter:read"])
    }
}
