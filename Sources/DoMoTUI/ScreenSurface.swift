// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The full-screen coordinator: the alt-screen counterpart of the inline `TUI`.
// `TUI` is a `Container` whose 1-D child runs the differential inline renderer;
// this owns an `AltScreenCore` and a `LayoutNode` tree instead, and adds the two
// things the alt screen needs that inline never did — Tab traversal between focus
// regions (a `FocusRing`) and overlays composited over an absolute-addressed
// page. It reuses every render-agnostic primitive the inline path already
// extracted: the overlay model types, the shared `resolveOverlayGeometry` solver,
// and the `compositeLineAt` splice. `AltScreenCore.frame` already strips the
// cursor marker and drives the hardware cursor, so a focused component's caret
// lands with no extra work here.
//
// It conforms to `TerminalApp`, so the same `TerminalDriver` that runs a `TUI`
// runs this — the coexistence the phase is named for.

import DoMoCore
import DoMoTermIO
import Dispatch
import Foundation

// MARK: - Screen surface

/// A full-screen (alternate-screen) coordinator: solve a ``LayoutNode`` tree into
/// a page, composite overlays, diff it through ``AltScreenCore``, route input to
/// the focused region, and Tab between regions.
///
/// `MainActor` by module default — the render loop, the input dispatch, and the
/// coalescing timer are one actor, exactly as in ``TUI``.
@MainActor
public final class ScreenSurface: TerminalApp {
    /// Where frames are written. `public` to witness ``TerminalApp/target``.
    public let target: any RenderTarget
    /// The alt-screen differential renderer (absolute CUP, no scroll state).
    private var core: AltScreenCore
    /// Tab-order focus between the regions the app registers.
    public let focus: FocusRing
    /// Rebuilds the layout tree each frame from the app's current state — the
    /// React-style "render is a function of state". Held, not stored as a tree,
    /// because the value-type nodes carry no identity to update in place.
    private let build: () -> any LayoutNode

    /// Floating overlays, painted over the base page in ``focusOrder`` order.
    private var overlayStack: [OverlayStackEntry] = []
    /// Monotonic z-order stamp; a later ``showOverlay(_:options:)`` sits on top.
    private var overlayCounter = 0

    // Render scheduling — mirrors `TUI` so live use coalesces and throttles, while
    // `renderSync()` stays the deterministic path a driver or a test drives.
    private var renderRequested = false
    private var renderScheduled = false
    private var stopped = false
    private static let minRenderIntervalMS = 16.0
    private var lastRenderAt = Date.distantPast

    /// Called if a *scheduled* render throws (an over-wide line). The synchronous
    /// ``renderSync()`` throws directly instead.
    public var onRenderError: ((DoMoError) -> Void)?

    /// The rows most recently composed for the screen: post-overlay,
    /// PRE-decoration, exactly `target.rows` entries of exactly `target.columns`
    /// visible columns.
    ///
    /// Retained so an owner can read back what is actually on screen. A mouse
    /// selection has no other source of truth: the layout tree is rebuilt from
    /// scratch every frame and its value-type nodes carry no identity, so there is
    /// nothing content-shaped to anchor a selection to — only the painted page.
    /// Pre-decoration, so a decorator reading it back sees the frame rather than
    /// its own last output.
    public private(set) var lastFrameLines: [String] = []

    /// A last-chance transform on the composed rows, applied immediately before
    /// the diff.
    ///
    /// For decoration that is a function of pointer state rather than of the
    /// layout tree — a selection highlight — and therefore has no ``LayoutNode``
    /// to live in.
    ///
    /// - Important: it MUST preserve every row's exact visible width.
    ///   ``AltScreenCore`` throws on a row wider than the terminal and the driver
    ///   escalates that to ending the session, so a decorator that adds a column
    ///   does not draw wrong — it hangs up on the user.
    public var decorateFrame: (([String]) -> [String])?

    /// - Parameters:
    ///   - target: where frames land and the object a resize is applied to.
    ///   - focus: the focus ring; inject a pre-populated one, or register regions
    ///     after construction.
    ///   - showHardwareCursor: whether a focused region's ``cursorMarker`` drives
    ///     the real cursor. Defaults to true — a full-screen app wants a visible
    ///     caret in its focused pane.
    ///   - build: assembles the layout tree for the current frame.
    public init(
        target: any RenderTarget,
        focus: FocusRing = FocusRing(),
        showHardwareCursor: Bool = true,
        build: @escaping () -> any LayoutNode
    ) {
        self.target = target
        self.focus = focus
        self.core = AltScreenCore(showHardwareCursor: showHardwareCursor)
        self.build = build
    }

    /// How many full redraws the diff has taken — the incremental-path metric.
    public var fullRedraws: Int { core.fullRedraws }

    /// Whether any overlay is on the stack (visible or hidden).
    public func hasOverlay() -> Bool { !overlayStack.isEmpty }

    // MARK: Rendering

    /// Render one frame synchronously and write it.
    ///
    /// Solve the tree to exactly `height × width` (``layoutLines(_:width:height:)``
    /// guarantees the shape ``AltScreenCore`` needs), composite overlays over it,
    /// then diff. The base is already full-page, so overlays sit at screen-relative
    /// rows with no padding — the one simplification the alt screen buys over the
    /// inline compositor.
    ///
    /// Unlike the inline ``TUI`` — whose renderer throws a ``DoMoError`` on an
    /// over-wide component line and ends the session — the full-screen path *clips*:
    /// ``CellBuffer`` and ``compositeLineAt`` truncate every row to the terminal
    /// width, so a misbehaving component truncates rather than crashing the session,
    /// and this never actually throws in practice. The `throws(DoMoError)` is kept
    /// for signature-parity with ``TerminalApp`` (so a driver treats both
    /// coordinators identically); the driver's render-error path is effectively
    /// inline-only.
    public func renderSync() throws(DoMoError) {
        guard !stopped else { return }
        let width = target.columns
        let height = target.rows
        // Solve to a buffer (not just lines) so the image layer travels with the
        // text grid to the renderer, which paints text around the images.
        let buffer = layoutBuffer(build(), width: width, height: height)
        var lines = buffer.flatten()
        if !overlayStack.isEmpty {
            lines = compositeOverlays(lines, termWidth: width, termHeight: height)
        }
        lastFrameLines = lines
        if let decorateFrame { lines = decorateFrame(lines) }
        let bytes = try core.frame(
            lines: lines,
            width: width,
            height: height,
            hasOverlays: !overlayStack.isEmpty,
            images: buffer.images
        )
        target.write(bytes)
        lastRenderAt = Date()
    }

    /// Force the next frame to be a full clear+redraw (theme change, resize).
    public func requestFullRedraw() {
        core.forceFullRedraw()
        requestRender()
    }

    /// Coalesce a render request; multiple calls in one turn collapse to a single
    /// throttled frame. The same scheduler ``TUI`` uses.
    public func requestRender() {
        guard !stopped else { return }
        renderRequested = true
        scheduleRender()
    }

    private func scheduleRender() {
        guard !stopped, !renderScheduled, renderRequested else { return }
        renderScheduled = true
        let elapsed = Date().timeIntervalSince(lastRenderAt) * 1000
        let delay = max(0, ScreenSurface.minRenderIntervalMS - elapsed) / 1000
        let deadline = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard !self.stopped, self.renderRequested else { return }
            self.renderRequested = false
            do {
                try self.renderSync()
            } catch let error as DoMoError {
                self.onRenderError?(error)
                return
            } catch {
                return
            }
            if self.renderRequested { self.scheduleRender() }
        }
    }

    /// Stop scheduling further frames.
    public func stop() {
        stopped = true
    }

    // MARK: Input

    /// Horizontal tab — moves focus forward.
    private static let tab: [UInt8] = [0x09]
    /// The back-tab / CBT sequence `ESC [ Z` (Shift-Tab) — moves focus backward.
    private static let backTab: [UInt8] = [0x1b, 0x5b, 0x5a]

    /// Dispatch one framed input sequence.
    ///
    /// A capturing overlay owns input while it is up (a modal dialog): it blocks
    /// the background — keystrokes AND Tab — whether or not its component is
    /// ``Focusable``, so a plain-content modal still stops traversal. This mirrors
    /// the inline ``TUI``, whose `focusedComponent` is a `Component?` that captures
    /// regardless of focusability. Otherwise Tab / Shift-Tab traverse the focus
    /// ring and everything else goes to the focused region. Kitty key-*release*
    /// events are dropped unless the receiver opts in, exactly as
    /// ``TUI/handleInput(_:)`` does.
    public func handleInput(_ data: [UInt8]) {
        if let overlay = capturingOverlay {
            let component = overlay.component
            if isKeyRelease(data), !component.wantsKeyRelease { return }
            component.handleInput(data)
            requestRender()
            return
        }

        if data == ScreenSurface.tab {
            focus.focusNext()
            requestRender()
            return
        }
        if data == ScreenSurface.backTab {
            focus.focusPrevious()
            requestRender()
            return
        }

        guard let current = focus.current else { return }
        if isKeyRelease(data), !current.wantsKeyRelease { return }
        current.handleInput(data)
        requestRender()
    }

    // MARK: Overlays

    /// The topmost visible overlay that captures input, or `nil`. A `nonCapturing`
    /// overlay (a toast, a status flash) never becomes this.
    private var capturingOverlay: OverlayStackEntry? {
        overlayStack.last { isOverlayVisible($0) && !($0.options?.nonCapturing ?? false) }
    }

    /// Whether an overlay entry steals input focus (the default), vs a toast that
    /// only paints.
    private func isCapturing(_ entry: OverlayStackEntry) -> Bool {
        !(entry.options?.nonCapturing ?? false)
    }

    /// Restore the caret after the current input owner steps aside (removed or
    /// hidden): to the topmost remaining capturing overlay's component if it has a
    /// caret, else to the ring's focused member. A non-``Focusable`` capturing
    /// overlay still owns input, so the base stays dimmed under it.
    private func refocusAfterRemoval() {
        if let next = capturingOverlay {
            (next.component as? Focusable)?.focused = true
        } else {
            focus.current?.focused = true
        }
    }

    /// Show `component` as a floating overlay. A capturing overlay owns input while
    /// up; the region that had it is dimmed (its caret hidden) and restored on
    /// ``hideOverlay()``, and the overlay's own caret shows if it is ``Focusable``.
    @discardableResult
    public func showOverlay(_ component: Component, options: OverlayOptions? = nil) -> ScreenOverlayHandle {
        overlayCounter += 1
        let capturing = !(options?.nonCapturing ?? false)
        // The region that owns input right now — a lower capturing overlay, else
        // the ring's focused member. Captured before the push so it reflects the
        // pre-show state.
        let priorOwner: (any Focusable)? = capturing ? currentInputOwner : nil
        let entry = OverlayStackEntry(
            component: component,
            options: options,
            preFocus: priorOwner,
            hidden: false,
            focusOrder: overlayCounter
        )
        overlayStack.append(entry)
        if capturing {
            // Dim the prior owner regardless of whether the overlay is Focusable —
            // a plain-content modal must still stop the background's caret and
            // input. Show the overlay's caret only if it has one.
            priorOwner?.focused = false
            (component as? Focusable)?.focused = true
        }
        requestRender()
        return ScreenOverlayHandle(surface: self, entry: entry)
    }

    /// Remove the topmost overlay and restore focus beneath it.
    public func hideOverlay() {
        guard let entry = overlayStack.last else { return }
        removeOverlay(entry)
    }

    /// Remove a specific overlay (backs ``ScreenOverlayHandle/hide()``).
    func removeOverlay(_ entry: OverlayStackEntry) {
        guard let index = overlayStack.firstIndex(where: { $0 === entry }) else { return }
        overlayStack.remove(at: index)
        if let focusable = entry.component as? Focusable { focusable.focused = false }
        refocusAfterRemoval()
        requestRender()
    }

    /// Toggle an overlay's hidden flag (backs ``ScreenOverlayHandle/setHidden(_:)``).
    ///
    /// Hiding is a soft remove: if the entry owned the caret it is dimmed and focus
    /// hands off exactly as ``removeOverlay(_:)`` does, so the revealed region below
    /// actually shows its caret. Re-showing a capturing overlay that becomes topmost
    /// re-takes focus from the current owner.
    func setOverlayHidden(_ entry: OverlayStackEntry, _ hidden: Bool) {
        guard entry.hidden != hidden else { return }
        if hidden {
            entry.hidden = true
            (entry.component as? Focusable)?.focused = false
            refocusAfterRemoval()
        } else {
            let priorOwner = currentInputOwner
            entry.hidden = false
            // Take focus only if un-hiding makes this the topmost capturing overlay.
            if isCapturing(entry), capturingOverlay === entry {
                priorOwner?.focused = false
                (entry.component as? Focusable)?.focused = true
            }
        }
        requestRender()
    }

    /// Whether `entry` is currently painted: on the stack, not hidden, and its
    /// `visible` predicate (if any) passes at the current terminal size.
    func isOverlayVisible(_ entry: OverlayStackEntry) -> Bool {
        if entry.hidden { return false }
        if let visible = entry.options?.visible {
            return visible(target.columns, target.rows)
        }
        return true
    }

    /// Who input currently reaches: the topmost capturing overlay's component (if
    /// focusable), else the ring's focused member.
    private var currentInputOwner: (any Focusable)? {
        if let overlay = capturingOverlay, let focusable = overlay.component as? Focusable {
            return focusable
        }
        return focus.current
    }

    /// Composite every visible overlay into the full-page base, sorted by focus
    /// order (higher on top). The base is already exactly `termHeight × termWidth`,
    /// so an overlay row simply splices into `result[row]` — rows and columns that
    /// fall off the page are clipped, never wrapped.
    private func compositeOverlays(_ base: [String], termWidth: Int, termHeight: Int) -> [String] {
        var result = base
        let visible = overlayStack
            .filter { isOverlayVisible($0) }
            .sorted { $0.focusOrder < $1.focusOrder }

        for entry in visible {
            let sizing = resolveOverlayGeometry(entry.options, overlayHeight: 0, termWidth: termWidth, termHeight: termHeight)
            var lines = entry.component.render(width: sizing.width)
            if let maxHeight = sizing.maxHeight, lines.count > maxHeight {
                lines = Array(lines.prefix(maxHeight))
            }
            let placement = resolveOverlayGeometry(entry.options, overlayHeight: lines.count, termWidth: termWidth, termHeight: termHeight)

            for i in 0..<lines.count {
                let row = placement.row + i
                guard row >= 0, row < result.count else { continue }
                let line = lines[i]
                let clipped = visibleWidth(line) > sizing.width
                    ? sliceByColumn(line, from: 0, to: sizing.width, strict: true)
                    : line
                result[row] = compositeLineAt(
                    result[row],
                    clipped,
                    startCol: placement.col,
                    overlayWidth: sizing.width,
                    totalWidth: termWidth
                )
            }
        }
        return result
    }
}

// MARK: - Overlay handle

/// A lightweight handle to one overlay on a ``ScreenSurface``, so a caller can
/// hide it without holding the surface or the entry.
@MainActor
public final class ScreenOverlayHandle {
    private weak var surface: ScreenSurface?
    private let entry: OverlayStackEntry

    init(surface: ScreenSurface, entry: OverlayStackEntry) {
        self.surface = surface
        self.entry = entry
    }

    /// Remove this overlay and restore focus beneath it.
    public func hide() {
        surface?.removeOverlay(entry)
    }

    /// Hide or re-show this overlay without removing it from the stack.
    public func setHidden(_ hidden: Bool) {
        surface?.setOverlayHidden(entry, hidden)
    }

    /// Whether this overlay is currently painted.
    public func isVisible() -> Bool {
        surface?.isOverlayVisible(entry) ?? false
    }
}
