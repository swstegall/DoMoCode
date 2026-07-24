// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/tui.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. This is the run loop pi splits
// across `TUI.start`/`stop` and `ProcessTerminal.start`/`stop`: enter raw mode,
// pump stdin through the framer into the focused component, repaint on resize,
// and always restore the terminal on the way out. pi wires input and resize as
// Node event-emitter callbacks; Swift structured concurrency lets the same three
// sources (keystrokes, `SIGWINCH`, a quit signal) meet under one task group, so
// the "always restore" guarantee is a `defer` around the group rather than pi's
// scattered `stop()` calls in signal/exit/error handlers.

import Dispatch
import DoMoCore
import DoMoTermIO
import Foundation

// MARK: - stdout-backed RenderTarget

/// A ``RenderTarget`` that writes frames to a real output descriptor and reads
/// its size from the kernel.
///
/// This is the live counterpart to the in-memory capture target the tests use.
/// It is deliberately thin: the renderer already folds every escape, cursor move
/// and reset into the single frame string handed to ``write(_:)``, so the live
/// target only has to put those bytes on the wire and answer "how big am I".
///
/// The size is read fresh from ``TerminalSize/current(fileDescriptor:)`` on every
/// access rather than cached, because that is what makes a `SIGWINCH` transparent
/// to the renderer: the driver repaints on resize and the diff, re-reading
/// ``columns``/``rows`` here, sees the new grid with no extra plumbing. Writing
/// goes through `FileHandle` — not a raw `write(2)` — precisely so this file can
/// live under the module's strict-memory-safety setting without an `unsafe` per
/// call; the raw-syscall seam is `DoMoTermIO`'s job, not the renderer's.
public final class TerminalOutputTarget: RenderTarget {
    private let outputDescriptor: Int32
    private let handle: FileHandle

    /// - Parameter outputDescriptor: where frames are written and whose window
    ///   size is queried — stdout by default. `closeOnDealloc` is off: this does
    ///   not own the process's stdout and must not close it.
    public init(outputDescriptor: Int32 = FileHandle.standardOutput.fileDescriptor) {
        self.outputDescriptor = outputDescriptor
        self.handle = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
    }

    public var columns: Int { TerminalSize.current(fileDescriptor: outputDescriptor).columns }
    public var rows: Int { TerminalSize.current(fileDescriptor: outputDescriptor).rows }

    /// Put a frame on the wire. A failed write is swallowed: the terminal going
    /// away mid-frame is not something the renderer can recover from, and the
    /// lifecycle's restore will still run on exit.
    public func write(_ bytes: String) {
        guard !bytes.isEmpty else { return }
        try? handle.write(contentsOf: Data(bytes.utf8))
    }
}

// MARK: - Resizable target seam

/// A ``RenderTarget`` whose reported size can be set from outside.
///
/// The live ``TerminalOutputTarget`` reads its size from the kernel, so a resize
/// event needs no help to reach it. A headless target has no kernel to ask — its
/// size is whatever the test says — so the driver pushes each resize into it
/// through this seam before repainting. Conforming is how a capture target opts
/// into being resized by the injected resize stream; the live target does not,
/// and the driver's `as?` simply misses.
public protocol ResizableRenderTarget: RenderTarget {
    /// Adopt a new grid size. Called on the main actor immediately before the
    /// resize repaint, so the following ``RenderTarget/columns``/``rows`` read
    /// reflects it.
    @MainActor func setSize(_ size: TerminalSize)
}

// MARK: - Terminal lifecycle seam

/// The slice of ``TerminalLifecycle`` the driver depends on: enter raw mode, and
/// restore on the way out.
///
/// Injecting this — rather than newing a concrete ``TerminalLifecycle`` inside
/// `run` — is what lets the whole interactive loop be driven with no TTY: a test
/// passes a recording stand-in and asserts that restore ran exactly once on quit
/// and once on cancellation, without a real `tcsetattr` anywhere. The live path
/// gets the real thing through the extension below.
public protocol TerminalLifecycleControl: Sendable {
    /// Enter raw mode and arm the crash-safe restore. Throws if the descriptor is
    /// not a terminal.
    func enter() throws(DoMoError)
    /// Restore the terminal. Idempotent — safe after a signal already restored.
    func stop()
}

extension TerminalLifecycle: TerminalLifecycleControl {}

// MARK: - Quit signal

/// A one-shot "please stop" the UI can pull from inside a component.
///
/// The problem it solves: a focused component handling a keystroke (the REPL's
/// quit binding, a modal's cancel) has to end the run loop, but it has no handle
/// on the task group that loop lives in. ``quit()`` is `Sendable` and callable
/// from that main-actor `handleInput`; the run loop parks on ``wait()`` and wakes
/// when it fires. It is backed by an `AsyncStream` for one reason beyond
/// simplicity: an `AsyncStream` iterator returns `nil` when its task is
/// cancelled, so ``wait()`` unblocks on cancellation too, and the run loop's
/// teardown is reached whether the exit came from a quit key or an outside
/// `Task.cancel()`.
public nonisolated final class QuitSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    /// Request shutdown. Idempotent: extra calls after the first are dropped by
    /// the stream's finish, so a component may call it freely.
    public func quit() {
        continuation.yield(())
        continuation.finish()
    }

    /// Suspend until ``quit()`` fires or the awaiting task is cancelled.
    func wait() async {
        for await _ in stream { break }
    }
}

// MARK: - Driver

/// Binds terminal I/O (``TerminalLifecycle``, an input byte stream, a resize
/// stream) to a ``TUI`` and runs the interactive session.
///
/// One object, one responsibility: turn "raw bytes and a terminal" into "a TUI
/// that renders and receives keystrokes", and guarantee the terminal is put back
/// no matter how the session ends. It owns none of the render logic (that is
/// ``RenderCore``/``TUI``) and none of the terminal syscalls (those are
/// ``TerminalLifecycle``/``TerminalOutputTarget``); it is purely the wiring pi
/// keeps in `TUI.start` and the `ProcessTerminal` input listener chain, expressed
/// as one async run loop.
///
/// Every collaborator is injected — input stream, resize stream, lifecycle — so
/// the same `run` that drives a live TTY drives a scripted headless test: feed an
/// ``AsyncStream`` of bytes, watch the focused component receive them, and assert
/// the captured frame bytes through the screen oracle. There is no "only testable
/// on a real terminal" path here; the live path is just the injected collaborators
/// pointed at real descriptors (see ``standardInputStream(fileDescriptor:queue:)``
/// and ``TerminalSize/resizeStream(fileDescriptor:queue:)``).
///
/// Rendering is driven *synchronously* from this loop (``render()`` calls
/// ``TUI/renderSync()``) at three points — the initial frame, after each input
/// batch, and on each resize — rather than through ``TUI/requestRender()``'s
/// wall-clock coalescing timer. That keeps a headless run deterministic: the
/// bytes a test asserts are produced by the drive it just performed, not by a
/// 16 ms timer that may or may not have fired. Background work (the agent) that
/// updates components from off-loop still calls ``render()`` — exposed for exactly
/// that — to flush its frame.
@MainActor
public final class TerminalDriver {
    private let input: AsyncStream<[UInt8]>
    private let resize: AsyncStream<TerminalSize>
    private let lifecycle: any TerminalLifecycleControl

    /// The framer is driver state, not a run-loop local, because the
    /// disambiguation flush timer (below) is a separate main-actor task that must
    /// mutate the same buffer the input pump feeds. A value type behind one
    /// isolation domain — the main actor — needs no lock for that.
    private var framer = StdinFramer()
    /// The armed ESC-disambiguation flush, cancelled the instant more bytes land.
    private var flushTask: Task<Void, Never>?

    /// The session's TUI and quit handle, held for the duration of `run` so
    /// ``render()`` and the render-error path can reach them without threading
    /// them through every call.
    private weak var activeTUI: TUI?
    private var activeQuit: QuitSignal?

    /// The last render error, if a frame overflowed the terminal width. Surfaced
    /// so a caller can report *why* the session ended after `run` returns.
    public private(set) var renderError: DoMoError?
    /// A failure entering raw mode (the descriptor was not a terminal), if any.
    public private(set) var startupError: DoMoError?

    public init(
        input: AsyncStream<[UInt8]>,
        resize: AsyncStream<TerminalSize>,
        lifecycle: any TerminalLifecycleControl
    ) {
        self.input = input
        self.resize = resize
        self.lifecycle = lifecycle
    }

    /// The exit reasons a child of the run group can report. `quit` and
    /// `inputEnded` end the session; a finished resize stream or completed
    /// background job do not (the user is still typing).
    private enum RunOutcome: Sendable {
        case quit
        case inputEnded
        case resizeEnded
        case backgroundEnded
    }

    /// Run the interactive session until quit, input EOF, or cancellation.
    ///
    /// - Parameters:
    ///   - tui: the renderer to drive. Its ``TUI/target`` is where frames land.
    ///   - quit: the shared shutdown handle a component pulls to end the session.
    ///   - background: optional work (the agent) run concurrently with input.
    ///     It shares the main actor for UI mutation and should honour
    ///     cancellation; when it finishes the session keeps running.
    ///
    /// The terminal is restored in a `defer` that wraps the entire body, so raw
    /// mode is undone on a normal quit, on a thrown render error, and on an
    /// outside cancellation alike — the one guarantee pi spreads across three
    /// separate teardown call sites.
    public func run(
        _ tui: TUI,
        quit: QuitSignal,
        background: (@Sendable () async -> Void)? = nil
    ) async {
        activeTUI = tui
        activeQuit = quit
        framer.reset()
        renderError = nil
        startupError = nil

        // The restore MUST run however the body exits. `tui.stop()` first so no
        // late scheduled frame writes after the descriptor is handed back, then
        // the lifecycle puts raw mode / cursor / bracketed paste back.
        defer {
            flushTask?.cancel()
            flushTask = nil
            tui.stop()
            lifecycle.stop()
            activeTUI = nil
            activeQuit = nil
        }

        do {
            try lifecycle.enter()
        } catch {
            // Typed throw: `error` is a DoMoError. Not a terminal (or raw mode
            // refused) — there is no interactive session to run. Record why and
            // let `defer` no-op the restore.
            startupError = error
            return
        }

        // The initial frame, before any input — pi renders once on start for the
        // same reason: the screen should show the UI, not a blank line, at t=0.
        render()

        await withTaskGroup(of: RunOutcome.self) { group in
            group.addTask { [input] in
                for await chunk in input {
                    await self.ingest(chunk, tui: tui)
                }
                return .inputEnded
            }
            group.addTask { [resize] in
                for await size in resize {
                    await self.handleResize(size, tui: tui)
                }
                return .resizeEnded
            }
            group.addTask {
                await quit.wait()
                return .quit
            }
            if let background {
                group.addTask {
                    await background()
                    return .backgroundEnded
                }
            }

            for await outcome in group {
                switch outcome {
                case .quit, .inputEnded:
                    // Session over. Cancelling the group unblocks the remaining
                    // stream iterators (they return nil on cancel) and the
                    // background job; the group then drains and returns.
                    group.cancelAll()
                    return
                case .resizeEnded, .backgroundEnded:
                    continue
                }
            }
        }
    }

    // MARK: Input

    /// Feed one raw chunk through the framer and dispatch every whole sequence.
    ///
    /// Ports the `ProcessTerminal` stdin listener: bytes in, framed sequences out,
    /// each handed to the focused component via ``TUI/handleInput(_:)`` — which is
    /// where the key-release filter lives, so a game component still gets releases
    /// and everything else does not. A completed bracketed paste is re-wrapped in
    /// its `ESC[200~ … ESC[201~` guards before dispatch because that wrapper is
    /// how ``Editor`` recognises a paste as one atomic segment; the framer stripped
    /// the guards to keep paste content out of the keystroke path, and this puts
    /// them back for exactly the one consumer that needs them.
    private func ingest(_ chunk: [UInt8], tui: TUI) {
        flushTask?.cancel()
        flushTask = nil

        let events = framer.process(chunk)
        dispatch(events, to: tui)

        // A held tail (a lone ESC, a split CSI) is neither a keypress nor noise
        // until the disambiguation window closes. Arm the flush the framer's I/O
        // contract asks for; a following chunk cancels it above.
        if framer.hasPendingBytes {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: StdinFramer.disambiguationTimeout)
                guard let self, !Task.isCancelled else { return }
                let flushed = self.framer.flush()
                self.dispatch(flushed, to: tui)
                self.render()
            }
        }

        render()
    }

    private func dispatch(_ events: [StdinEvent], to tui: TUI) {
        for event in events {
            switch event {
            case .sequence(let bytes):
                tui.handleInput(bytes)
            case .paste(let content):
                var wrapped = Array("\u{1b}[200~".utf8)
                wrapped.append(contentsOf: content)
                wrapped.append(contentsOf: Array("\u{1b}[201~".utf8))
                tui.handleInput(wrapped)
            }
        }
    }

    // MARK: Resize

    /// Apply a new terminal size and repaint.
    ///
    /// A width or height change forces the renderer down its full-redraw path (the
    /// diff detects it by comparing against the previous size), so a resize is just
    /// "tell the target its new size, then render". The live target reads size from
    /// the kernel and ignores ``ResizableRenderTarget/setSize(_:)``; a headless
    /// target adopts it so the injected resize is visible to the very next frame.
    private func handleResize(_ size: TerminalSize, tui: TUI) {
        if let resizable = tui.target as? any ResizableRenderTarget {
            resizable.setSize(size)
        }
        render()
    }

    // MARK: Render

    /// Render one frame synchronously, routing an over-wide-line error to quit.
    ///
    /// Public so background work (the agent's event sink) can flush its own
    /// component updates through the same synchronous path the loop uses, keeping
    /// all rendering on one deterministic seam instead of the coalescing timer.
    /// A ``DoMoError`` here means a component emitted a line wider than the
    /// terminal — unrecoverable for this frame — so the session is ended cleanly
    /// with the error recorded, rather than trapping.
    public func render() {
        guard let tui = activeTUI else { return }
        do {
            try tui.renderSync()
        } catch {
            // Typed throw: `error` is a DoMoError (an over-wide line).
            renderError = error
            activeQuit?.quit()
        }
    }
}

// MARK: - Live input stream

extension TerminalDriver {
    /// An ``AsyncStream`` of raw byte chunks read from an input descriptor.
    ///
    /// The live counterpart to a test's scripted stream: a `DispatchSource` read
    /// watcher yields whatever the descriptor makes available, so the read never
    /// blocks the main actor and the driver's input pump is oblivious to whether
    /// its bytes come from a keyboard or a script. Reading goes through
    /// `FileHandle.availableData` (the source guarantees data is ready) rather than
    /// a raw `read(2)`, keeping this file inside strict memory safety. The source
    /// is cancelled when the stream's consumer stops, and an empty read (EOF, e.g.
    /// stdin closed) finishes the stream — which the run loop treats as
    /// end-of-session.
    // `nonisolated` is load-bearing: under DoMoTUI's `.defaultIsolation(MainActor.self)`
    // this factory — and, crucially, the `setEventHandler` closure it builds —
    // would otherwise be `@MainActor`. The `DispatchSource` runs that handler on
    // its own `domo.tui.stdin` queue, and a main-actor-isolated closure invoked
    // off the main actor traps in `dispatchPrecondition` (`_dispatch_assert_queue_fail`),
    // crashing the real binary on the first keystroke. The headless tests inject
    // their own `AsyncStream` and never reach this path, so only a live run finds it.
    public nonisolated static func standardInputStream(
        fileDescriptor: Int32 = FileHandle.standardInput.fileDescriptor,
        queue: DispatchQueue = DispatchQueue(label: "domo.tui.stdin")
    ) -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
            source.setEventHandler {
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    return
                }
                continuation.yield([UInt8](data))
            }
            source.setCancelHandler {}
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
