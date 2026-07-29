// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// `TerminalLifecycleControl.setMouseReporting` is what lets a full-screen app hand
// the mouse back to the terminal mid-session — the escape hatch for a user whose
// terminal this program's mouse handling gets wrong, and the only way the
// terminal's own selection and right-click menu come back without ending the
// session.
//
// Two properties are pinned here because both are easy to break and neither shows
// up until a UI is wired to them:
//
//  * the requirement has a no-op DEFAULT, so the existing test doubles that
//    implement only `enter`/`stop` keep compiling untouched;
//  * the protocol carries NO `AnyObject`, so a VALUE TYPE can implement it. That
//    is not a style preference — the doubles in this target and in DoMoCLITests
//    are structs, and adding `AnyObject` is an immediate compile error.

import DoMoCore
import DoMoTermIO
import DoMoTUI
import Testing

/// A conformer that ignores mouse reporting entirely — the shape every existing
/// double has. It must keep compiling with no `setMouseReporting` of its own.
private struct SilentLifecycle: TerminalLifecycleControl {
    func enter() throws(DoMoError) {}
    func stop() {}
}

/// A VALUE-TYPE conformer that does implement it, recording through a reference
/// box because a struct's `func` cannot mutate `self`.
private struct RecordingLifecycle: TerminalLifecycleControl {
    final class Log: @unchecked Sendable {
        var calls: [Bool] = []
    }

    let log = Log()

    func enter() throws(DoMoError) {}
    func stop() {}
    func setMouseReporting(_ enabled: Bool) {
        log.calls.append(enabled)
    }
}

// `TerminalLifecycleControl` is declared in DoMoTUI, which is
// `.defaultIsolation(MainActor.self)`, so the requirement is MainActor-isolated and
// every caller — including `ClientApp`'s toggle key — must already be on the main
// actor. The concrete `TerminalLifecycle` implementation is `nonisolated` and
// witnesses it regardless.
@MainActor
@Suite("Mid-session mouse reporting seam")
struct MouseReportingSeamTests {

    @Test("A conformer that ignores the mouse gets a no-op default")
    func defaultIsANoOp() {
        // Compiling at all is most of the assertion: three existing doubles declare
        // only `enter`/`stop`, so a mandatory requirement would have broken two test
        // targets. Calling it must also be harmless.
        let lifecycle: any TerminalLifecycleControl = SilentLifecycle()
        lifecycle.setMouseReporting(false)
        lifecycle.setMouseReporting(true)
    }

    @Test("A value type can take and release the mouse — the protocol requires no class")
    func valueTypeCanImplementIt() {
        let lifecycle = RecordingLifecycle()
        let control: any TerminalLifecycleControl = lifecycle
        control.setMouseReporting(false)
        control.setMouseReporting(true)
        control.setMouseReporting(false)
        #expect(lifecycle.log.calls == [false, true, false])
    }

    @Test("The real lifecycle witnesses the requirement with its own implementation")
    func concreteLifecycleOverridesTheDefault() {
        // `extension TerminalLifecycle: TerminalLifecycleControl {}` must pick up the
        // concrete method, not the protocol's no-op — otherwise F8 would silently do
        // nothing on the one conformer that matters. The descriptor is not a tty, so
        // the call is inert here; what is asserted is that it dispatches and that the
        // declared mode is unchanged by it.
        let lifecycle = TerminalLifecycle(
            outputDescriptor: -1,
            useAlternateScreen: true,
            enableMouse: true
        )
        let control: any TerminalLifecycleControl = lifecycle
        control.setMouseReporting(false)
        #expect(lifecycle.enableMouse == true)
        // And the bytes it would have written are the ones the teardown reverses.
        #expect(
            TerminalLifecycle.mouseSequence(enabled: false)
                == Array(TerminalLifecycle.teardownSequence(useAlternateScreen: false, enableMouse: true)
                    .prefix(TerminalLifecycle.mouseSequence(enabled: false).count))
        )
    }
}
