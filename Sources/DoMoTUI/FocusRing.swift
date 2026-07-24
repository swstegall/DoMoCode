// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Keyboard-focus traversal for the full-screen layout world. The inline `TUI`
// never needed a ring: its focus is set explicitly (an overlay handle, a slash
// menu) and there is no Tab navigation between regions. A full-screen app is
// different — a sidebar and a main pane are peers the user Tabs between — so this
// is the one piece of focus machinery pi's inline model never had, built here
// rather than ported.
//
// The ring holds `Focusable` components by identity (they are `AnyObject`) and
// owns the single invariant the renderer relies on: at most one member is
// `focused`, and it is exactly ``current``. Every mutation re-establishes it, so
// a caller never has to hand-toggle the flag.

// MARK: - Focus ring

/// An ordered, identity-keyed set of ``Focusable`` regions with wrap-around
/// forward/backward traversal.
///
/// `MainActor` by module default, like every other component-facing type: focus
/// changes happen on the render/input actor, so the flag it writes and the flag a
/// component reads at render time are never seen mid-update.
@MainActor
public final class FocusRing {
    /// Registration order is Tab order. Never holds duplicates (identity-checked
    /// on ``register(_:)``).
    private var ring: [any Focusable] = []
    /// Index of the focused member, or `nil` when nothing is focused (an empty
    /// ring, or one explicitly cleared).
    private var currentIndex: Int?

    public init() {}

    /// The members in Tab order.
    public var members: [any Focusable] { ring }

    /// How many regions are registered.
    public var count: Int { ring.count }

    /// The focused member, or `nil`. The one component whose ``Focusable/focused``
    /// is `true`.
    public var current: (any Focusable)? {
        guard let index = currentIndex, ring.indices.contains(index) else { return nil }
        return ring[index]
    }

    /// Add a region to the end of the Tab order.
    ///
    /// A no-op if the same object (by `===`) is already registered, so a rebuild
    /// that re-registers the same panes does not duplicate them. Registering the
    /// first member focuses it — a fresh full-screen app comes up with its first
    /// region already holding the caret, matching how a real TUI opens.
    public func register(_ focusable: any Focusable) {
        guard !ring.contains(where: { $0 === focusable }) else { return }
        ring.append(focusable)
        if currentIndex == nil {
            currentIndex = ring.count - 1
            focusable.focused = true
        } else {
            // Normalize a member that arrives already focused (its flag was set
            // outside the ring): only ``current`` may carry the flag, so a
            // non-first registration always clears it. Keeps the single-focus
            // invariant true after *every* mutation, as documented.
            focusable.focused = false
        }
    }

    /// Remove a region.
    ///
    /// Removing the focused member advances focus to the region that took its slot
    /// (the next one, or the new last if it was at the end), so focus is never left
    /// dangling on a component that is gone. Removing a non-current member keeps the
    /// same component focused, adjusting the stored index for the shift.
    public func unregister(_ focusable: any Focusable) {
        guard let removedIndex = ring.firstIndex(where: { $0 === focusable }) else { return }
        let wasCurrent = currentIndex == removedIndex
        focusable.focused = false
        ring.remove(at: removedIndex)

        guard !ring.isEmpty else {
            currentIndex = nil
            return
        }
        guard let index = currentIndex else { return }
        if wasCurrent {
            let next = min(removedIndex, ring.count - 1)
            currentIndex = next
            ring[next].focused = true
        } else if index > removedIndex {
            currentIndex = index - 1
        }
    }

    /// Drop every region and clear focus.
    public func clear() {
        for member in ring { member.focused = false }
        ring = []
        currentIndex = nil
    }

    /// Focus a specific member (or clear focus with `nil`).
    ///
    /// The target must already be registered; naming an unregistered component
    /// clears focus rather than silently adding it, so the ring's membership stays
    /// the caller's decision alone.
    public func setCurrent(_ focusable: (any Focusable)?) {
        if let existing = current { existing.focused = false }
        guard let focusable, let index = ring.firstIndex(where: { $0 === focusable }) else {
            currentIndex = nil
            return
        }
        currentIndex = index
        ring[index].focused = true
    }

    /// Move focus to the next region, wrapping past the end. Returns the newly
    /// focused member, or `nil` if the ring is empty.
    @discardableResult
    public func focusNext() -> (any Focusable)? { advance(by: 1) }

    /// Move focus to the previous region, wrapping past the front. Returns the
    /// newly focused member, or `nil` if the ring is empty.
    @discardableResult
    public func focusPrevious() -> (any Focusable)? { advance(by: -1) }

    private func advance(by delta: Int) -> (any Focusable)? {
        guard !ring.isEmpty else { return nil }
        let count = ring.count
        let newIndex: Int
        if let old = currentIndex, ring.indices.contains(old) {
            ring[old].focused = false
            newIndex = ((old + delta) % count + count) % count
        } else {
            // Nothing focused yet: forward starts at the front, backward at the end.
            newIndex = delta >= 0 ? 0 : count - 1
        }
        currentIndex = newIndex
        ring[newIndex].focused = true
        return ring[newIndex]
    }
}
