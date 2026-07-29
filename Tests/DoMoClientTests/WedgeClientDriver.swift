// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// A driver for the REAL full-screen client, with an oracle that watches for
// things that do not stay on screen.
//
// `ErrorSurfaceEndToEndTests` proves a PERSISTENT row by replaying every byte the
// client ever wrote and asserting on the final grid. That method cannot see a
// transient status-line notice at all: by the time the test stops driving, the
// four-second dwell has lapsed and the message is gone from the screen it is
// asserting against. Almost every failure this file covers — a refused prompt, an
// approval that did not reach the server, a history refresh that failed — is
// exactly that shape, which is why they were the ones with no coverage.
//
// So this driver polls: it rebuilds the emulator from the byte stream every few
// milliseconds and REMEMBERS each needle the moment it appears. A needle is
// proven by having been on screen once, which is the property a transient message
// actually has.

import DoMoClient
import DoMoCore
import DoMoTermIO
import DoMoTUI
import Foundation

/// A `RenderTarget` that accumulates every byte the driver writes.
@MainActor
final class WedgeCaptureTarget: RenderTarget {
    let columns: Int
    let rows: Int
    private var buffer = ""

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    func write(_ bytes: String) { buffer += bytes }
    func snapshot() -> String { buffer }
}

/// There is no tty to put into raw mode headlessly; the driver needs only that
/// `enter`/`stop` succeed.
final class WedgeNoopLifecycle: TerminalLifecycleControl {
    func enter() throws(DoMoError) {}
    func stop() {}
}

/// One live run of the real client, driven by bytes and observed through a VT100
/// emulator.
@MainActor
final class WedgeClient {
    let target: WedgeCaptureTarget
    private let inputCont: AsyncStream<[UInt8]>.Continuation
    private let resizeCont: AsyncStream<TerminalSize>.Continuation
    private let task: Task<Void, Never>
    private var stopped = false

    /// Needles that have been on screen at least once since the run started.
    private(set) var seen: Set<String> = []
    /// Needles being watched for. Anything not listed here is only ever checked
    /// against the CURRENT screen.
    private var watching: Set<String> = []

    init(
        baseURL: String,
        token: String,
        // Wide on purpose. The status line composes a disconnect reason, a run
        // state, a transient notice and half a dozen key hints into ONE row, and
        // the row is truncated to the terminal's width — so on an 80- or
        // 150-column screen a test can "fail" because the message it is watching
        // for was pushed off the right edge by a longer message beside it. That is
        // a real product question (which segment wins when the line is full) and
        // not the question these tests ask.
        columns: Int = 220,
        rows: Int = 34,
        watching: [String] = []
    ) {
        self.target = WedgeCaptureTarget(columns: columns, rows: rows)
        self.watching = Set(watching)
        let (input, inputCont) = AsyncStream<[UInt8]>.makeStream()
        let (resize, resizeCont) = AsyncStream<TerminalSize>.makeStream()
        self.inputCont = inputCont
        self.resizeCont = resizeCont
        let target = self.target
        self.task = Task { @MainActor in
            try? await runFullScreenClient(
                baseURL: baseURL,
                token: token,
                target: target,
                input: input,
                resize: resize,
                lifecycle: WedgeNoopLifecycle()
            )
        }
    }

    // MARK: Driving

    func send(_ bytes: [UInt8]) { inputCont.yield(bytes) }

    func type(_ text: String) { inputCont.yield(Array(text.utf8)) }

    /// Enter.
    func press() { inputCont.yield([0x0d]) }

    /// Quit with ^C and wait for the client task to unwind.
    func quit() async {
        guard !stopped else { return }
        stopped = true
        inputCont.yield([0x03])
        inputCont.finish()
        resizeCont.finish()
        _ = await task.result
    }

    // MARK: Observing

    /// The screen right now, plus anything that scrolled off.
    func screen() -> [String] {
        let oracle = ScreenOracle(rows: target.rows, cols: target.columns)
        oracle.feed(target.snapshot())
        return oracle.screen + oracle.transcript
    }

    func joined() -> String { screen().joined(separator: "\n") }

    /// Record every watched needle currently visible.
    private func poll() {
        guard !watching.isSubset(of: seen) else { return }
        let rows = screen()
        for needle in watching where !seen.contains(needle) {
            if rows.contains(where: { $0.contains(needle) }) { seen.insert(needle) }
        }
    }

    /// Whether `needle` is on the screen at this instant.
    func showing(_ needle: String) -> Bool {
        screen().contains { $0.contains(needle) }
    }

    /// Whether ONE row holds every one of `needles`.
    ///
    /// For a claim about a single COMPOSED line — the status line, which joins a
    /// disconnect reason, a run state, a notice and the key hints into one row.
    /// Finding those words scattered across the screen proves nothing: the same
    /// words appear in the transcript row the same outage produces, so a
    /// whole-screen search stays green after the status-line segment is deleted.
    /// That is not hypothetical — it is exactly the hole a mutation run found here.
    func showingRow(with needles: [String]) -> Bool {
        screen().contains { row in needles.allSatisfy(row.contains) }
    }

    /// Poll until one row holds every one of `needles`.
    func waitForRow(with needles: [String], timeout: Duration = .seconds(25)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            poll()
            if showingRow(with: needles) { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return showingRow(with: needles)
    }

    /// Poll until `needle` has appeared at least once. Also advances every other
    /// watched needle, so one wait can prove several transient messages.
    @discardableResult
    func wait(for needle: String, timeout: Duration = .seconds(25)) async -> Bool {
        watching.insert(needle)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            poll()
            if seen.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        poll()
        return seen.contains(needle)
    }

    /// Poll until every watched needle has appeared at least once.
    @discardableResult
    func waitForAll(timeout: Duration = .seconds(25)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            poll()
            if watching.isSubset(of: seen) { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        poll()
        return watching.isSubset(of: seen)
    }

    /// The watched needles that never showed up — the useful half of a failure
    /// message.
    var missing: [String] { watching.subtracting(seen).sorted() }

    /// Keep polling for `duration`, recording anything that appears. For a test
    /// whose claim is "this happened at some point", not "this is the end state".
    func observe(for duration: Duration) async {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            poll()
            try? await Task.sleep(for: .milliseconds(40))
        }
        poll()
    }
}
