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
///
/// The reported size is mutable so a test can stage a resize: the live stdout
/// target learns its new size from the kernel on `SIGWINCH`, and a headless one
/// has to be told — which is what ``ResizableRenderTarget`` exists for. Without
/// this seam nothing in a headless test can reach the app's resize handling at
/// all, so the whole re-fit path (a modal and the ^G panel are both laid out for
/// a size that a window drag invalidates) was unreachable and uncovered.
@MainActor
final class WedgeCaptureTarget: RenderTarget {
    private(set) var columns: Int
    private(set) var rows: Int
    /// The grid the EMULATOR is replayed at, fixed for the life of the run.
    ///
    /// Deliberately not `columns`/`rows`. The oracle re-feeds the whole byte log
    /// from the start on every poll, so replaying it at a size the app was not
    /// using when those bytes were written would wrap and scroll history that
    /// never wrapped on the real screen. A test that stages a resize therefore
    /// pins this at the LARGEST size the run will ever report: a smaller app just
    /// paints into the left of it, and the full clear+redraw that every size
    /// change forces wipes whatever the previous layout left behind.
    let oracleColumns: Int
    let oracleRows: Int
    private var buffer = ""

    init(columns: Int, rows: Int, oracleColumns: Int? = nil, oracleRows: Int? = nil) {
        self.columns = columns
        self.rows = rows
        self.oracleColumns = oracleColumns ?? columns
        self.oracleRows = oracleRows ?? rows
    }

    func write(_ bytes: String) { buffer += bytes }
    func snapshot() -> String { buffer }
}

extension WedgeCaptureTarget: @MainActor ResizableRenderTarget {
    func setSize(_ size: TerminalSize) {
        columns = size.columns
        rows = size.rows
    }
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

    /// Acquire the cross-suite full-screen permit before handing the client to a
    /// test. Starting a task that waits for the permit is not enough: the test
    /// would begin polling an empty screen, time out, and then wait forever in
    /// `quit()` for that queued task while the current permit holder waits behind
    /// it.
    static func make(
        baseURL: String,
        token: String,
        columns: Int = 220,
        rows: Int = 34,
        oracleColumns: Int? = nil,
        oracleRows: Int? = nil,
        watching: [String] = [],
        ownsFullScreenGate: Bool = true
    ) async -> WedgeClient {
        if ownsFullScreenGate {
            await FullScreenClientGate.shared.enter()
        }
        return WedgeClient(
            baseURL: baseURL,
            token: token,
            columns: columns,
            rows: rows,
            oracleColumns: oracleColumns,
            oracleRows: oracleRows,
            watching: watching,
            ownsFullScreenGate: ownsFullScreenGate,
            gateAlreadyAcquired: ownsFullScreenGate
        )
    }

    private init(
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
        // The emulator's own grid, when a test intends to ``resize(columns:rows:)``
        // the app to something LARGER than it starts at. See
        // ``WedgeCaptureTarget/oracleColumns``.
        oracleColumns: Int? = nil,
        oracleRows: Int? = nil,
        watching: [String] = [],
        ownsFullScreenGate: Bool = true,
        gateAlreadyAcquired: Bool = false
    ) {
        self.target = WedgeCaptureTarget(
            columns: columns, rows: rows, oracleColumns: oracleColumns, oracleRows: oracleRows
        )
        self.watching = Set(watching)
        let (input, inputCont) = AsyncStream<[UInt8]>.makeStream()
        let (resize, resizeCont) = AsyncStream<TerminalSize>.makeStream()
        self.inputCont = inputCont
        self.resizeCont = resizeCont
        let target = self.target
        self.task = Task { @MainActor in
            if ownsFullScreenGate, !gateAlreadyAcquired {
                await FullScreenClientGate.shared.enter()
            }
            try? await runFullScreenClient(
                baseURL: baseURL,
                token: token,
                target: target,
                input: input,
                resize: resize,
                lifecycle: WedgeNoopLifecycle()
            )
            if ownsFullScreenGate {
                await FullScreenClientGate.shared.leave()
            }
        }
    }

    // MARK: Driving

    func send(_ bytes: [UInt8]) { inputCont.yield(bytes) }

    func type(_ text: String) { inputCont.yield(Array(text.utf8)) }

    /// Enter.
    func press() { inputCont.yield([0x0d]) }

    /// Stage a terminal resize, exactly as a window drag would: the driver adopts
    /// the new size into the target and repaints on the same hop.
    ///
    /// Never larger than the emulator's own grid — see
    /// ``WedgeCaptureTarget/oracleColumns``.
    func resize(columns: Int, rows: Int) {
        resizeCont.yield(TerminalSize(columns: columns, rows: rows))
    }

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
        let oracle = ScreenOracle(rows: target.oracleRows, cols: target.oracleColumns)
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

    /// Poll until `needle` is no longer on the CURRENT screen.
    ///
    /// The counterpart to ``wait(for:timeout:)``: that one proves a message was
    /// shown at some point, this one proves it stopped being shown. Pair them to
    /// pin a transient message that must both appear and then go away for a
    /// reason other than its own expiry timer.
    @discardableResult
    func waitUntilGone(_ needle: String, timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            poll()
            if !joined().contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        poll()
        return !joined().contains(needle)
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
