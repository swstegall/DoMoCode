// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

// The focus ring — pure logic, no rendering. The one invariant every test pins:
// at most one member is `focused`, and it is exactly `current`. Public API only
// (no `@testable`): `FocusRing` is exercised as a full-screen app would use it.

import DoMoTUI
import Testing

@MainActor
private func focusedCount(_ ring: FocusRing) -> Int {
    ring.members.filter(\.focused).count
}

@MainActor
@Suite("Focus ring traversal")
struct FocusRingTests {
    @Test("Registration order is Tab order and the first member is focused")
    func registrationOrderAndFirstFocus() {
        let ring = FocusRing()
        let a = FocusableProbe("a")
        let b = FocusableProbe("b")
        ring.register(a)
        ring.register(b)

        #expect(ring.count == 2)
        #expect(ring.members.map { $0 === a } == [true, false])
        #expect(ring.current === a)     // first registration takes focus
        #expect(a.focused)
        #expect(!b.focused)
        #expect(focusedCount(ring) == 1)
    }

    @Test("Registering the same object twice is a no-op")
    func duplicateRegisterIgnored() {
        let ring = FocusRing()
        let a = FocusableProbe("a")
        ring.register(a)
        ring.register(a)
        #expect(ring.count == 1)
    }

    @Test("focusNext wraps past the end")
    func nextWraps() {
        let ring = FocusRing()
        let a = FocusableProbe("a"), b = FocusableProbe("b"), c = FocusableProbe("c")
        ring.register(a); ring.register(b); ring.register(c)

        #expect(ring.focusNext() === b)
        #expect(ring.current === b)
        #expect(focusedCount(ring) == 1)
        #expect(ring.focusNext() === c)
        #expect(ring.focusNext() === a)   // wrapped
        #expect(ring.current === a)
        #expect(focusedCount(ring) == 1)
    }

    @Test("focusPrevious wraps past the front")
    func previousWraps() {
        let ring = FocusRing()
        let a = FocusableProbe("a"), b = FocusableProbe("b"), c = FocusableProbe("c")
        ring.register(a); ring.register(b); ring.register(c)   // a focused

        #expect(ring.focusPrevious() === c)   // wrapped from the front
        #expect(ring.current === c)
        #expect(ring.focusPrevious() === b)
        #expect(focusedCount(ring) == 1)
    }

    @Test("An empty ring focuses nothing")
    func emptyRing() {
        let ring = FocusRing()
        #expect(ring.current == nil)
        #expect(ring.focusNext() == nil)
        #expect(ring.focusPrevious() == nil)
        #expect(focusedCount(ring) == 0)
    }

    @Test("A single member stays focused across traversal")
    func singleMember() {
        let ring = FocusRing()
        let a = FocusableProbe("a")
        ring.register(a)
        #expect(ring.focusNext() === a)
        #expect(ring.focusPrevious() === a)
        #expect(a.focused)
        #expect(focusedCount(ring) == 1)
    }

    @Test("setCurrent focuses a member and clears the previous one")
    func setCurrentToMember() {
        let ring = FocusRing()
        let a = FocusableProbe("a"), b = FocusableProbe("b")
        ring.register(a); ring.register(b)
        ring.setCurrent(b)
        #expect(ring.current === b)
        #expect(!a.focused)
        #expect(b.focused)
        #expect(focusedCount(ring) == 1)
    }

    @Test("setCurrent to a non-member clears focus rather than adding it")
    func setCurrentToNonMember() {
        let ring = FocusRing()
        let a = FocusableProbe("a")
        let stranger = FocusableProbe("stranger")
        ring.register(a)
        ring.setCurrent(stranger)
        #expect(ring.current == nil)
        #expect(ring.count == 1)        // membership unchanged
        #expect(!a.focused)
        #expect(!stranger.focused)
    }

    @Test("setCurrent(nil) clears focus")
    func setCurrentNil() {
        let ring = FocusRing()
        let a = FocusableProbe("a")
        ring.register(a)
        ring.setCurrent(nil)
        #expect(ring.current == nil)
        #expect(!a.focused)
        #expect(focusedCount(ring) == 0)
    }

    @Test("Unregistering the focused member advances focus to its successor")
    func unregisterCurrentAdvances() {
        let ring = FocusRing()
        let a = FocusableProbe("a"), b = FocusableProbe("b"), c = FocusableProbe("c")
        ring.register(a); ring.register(b); ring.register(c)   // a focused
        ring.unregister(a)
        #expect(ring.count == 2)
        #expect(ring.current === b)     // b took a's slot
        #expect(b.focused)
        #expect(!a.focused)
        #expect(focusedCount(ring) == 1)
    }

    @Test("Unregistering the focused last member wraps focus to the new last")
    func unregisterCurrentAtEndWraps() {
        let ring = FocusRing()
        let a = FocusableProbe("a"), b = FocusableProbe("b")
        ring.register(a); ring.register(b)
        ring.setCurrent(b)               // focus the last member
        ring.unregister(b)
        #expect(ring.count == 1)
        #expect(ring.current === a)      // clamped to the new last
        #expect(a.focused)
        #expect(focusedCount(ring) == 1)
    }

    @Test("Unregistering a non-current member keeps the same component focused")
    func unregisterNonCurrentKeepsFocus() {
        let ring = FocusRing()
        let a = FocusableProbe("a"), b = FocusableProbe("b"), c = FocusableProbe("c")
        ring.register(a); ring.register(b); ring.register(c)
        ring.setCurrent(c)               // focus c (index 2)
        ring.unregister(a)               // remove an earlier member
        #expect(ring.current === c)      // still c, index shifted underneath
        #expect(c.focused)
        #expect(focusedCount(ring) == 1)
    }

    @Test("Unregistering the only member leaves nothing focused")
    func unregisterOnlyMember() {
        let ring = FocusRing()
        let a = FocusableProbe("a")
        ring.register(a)
        ring.unregister(a)
        #expect(ring.count == 0)
        #expect(ring.current == nil)
        #expect(!a.focused)
    }

    @Test("clear drops every member and unfocuses them")
    func clearAll() {
        let ring = FocusRing()
        let a = FocusableProbe("a"), b = FocusableProbe("b")
        ring.register(a); ring.register(b)
        ring.clear()
        #expect(ring.count == 0)
        #expect(ring.current == nil)
        #expect(!a.focused)
        #expect(!b.focused)
    }

    @Test("Registering a member that arrives already focused normalizes it")
    func registerPreFocusedNormalized() {
        let ring = FocusRing()
        let a = FocusableProbe("a")
        ring.register(a)          // a is current + focused
        let b = FocusableProbe("b")
        b.focused = true          // flag set outside the ring, before registering
        ring.register(b)
        #expect(ring.current === a)
        #expect(a.focused)
        #expect(!b.focused)       // normalized: only current keeps the flag
        #expect(focusedCount(ring) == 1)
    }
}
