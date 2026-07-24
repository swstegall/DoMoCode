// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/tui.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. Overlay layout, compositing, the
// single-pass segment extractor, and the inactive|eligible|blocked focus-restore
// state machine all track `TUI`'s overlay code; the Kitty-image guards are
// dropped (no line is ever an image in this phase).

import Foundation

// MARK: - Overlay geometry

/// Where an overlay anchors within the terminal.
public enum OverlayAnchor {
    case center
    case topLeft, topRight, bottomLeft, bottomRight
    case topCenter, bottomCenter, leftCenter, rightCenter
}

/// A size given as an absolute column/row count or a percentage of the reference
/// dimension. Ports pi's `number | "${number}%"`.
public enum SizeValue {
    case absolute(Int)
    /// Percent as the whole number before division (`.percent(50)` means "50%").
    case percent(Double)
}

/// Per-side overlay margins from the terminal edges. A `nil` side means zero.
public struct OverlayMargin {
    public var top: Int?
    public var right: Int?
    public var bottom: Int?
    public var left: Int?

    public init(top: Int? = nil, right: Int? = nil, bottom: Int? = nil, left: Int? = nil) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }

    /// The same margin on all four sides.
    public init(all value: Int) {
        top = value; right = value; bottom = value; left = value
    }
}

/// Positioning and sizing for an overlay. All fields optional, matching pi's
/// `OverlayOptions`; defaults (centered, 80-or-fit width) fill in the rest.
public struct OverlayOptions {
    public var width: SizeValue?
    public var minWidth: Int?
    public var maxHeight: SizeValue?
    public var anchor: OverlayAnchor?
    public var offsetX: Int?
    public var offsetY: Int?
    public var row: SizeValue?
    public var col: SizeValue?
    public var margin: OverlayMargin?
    /// Only render the overlay when this returns true for the current terminal
    /// size. Re-evaluated every render, so an overlay can hide itself on a resize.
    public var visible: ((_ termWidth: Int, _ termHeight: Int) -> Bool)?
    /// When true, showing the overlay does not steal keyboard focus.
    public var nonCapturing: Bool

    public init(
        width: SizeValue? = nil,
        minWidth: Int? = nil,
        maxHeight: SizeValue? = nil,
        anchor: OverlayAnchor? = nil,
        offsetX: Int? = nil,
        offsetY: Int? = nil,
        row: SizeValue? = nil,
        col: SizeValue? = nil,
        margin: OverlayMargin? = nil,
        visible: ((_ termWidth: Int, _ termHeight: Int) -> Bool)? = nil,
        nonCapturing: Bool = false
    ) {
        self.width = width
        self.minWidth = minWidth
        self.maxHeight = maxHeight
        self.anchor = anchor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.row = row
        self.col = col
        self.margin = margin
        self.visible = visible
        self.nonCapturing = nonCapturing
    }
}

/// Explicit target for ``OverlayHandle/unfocus(_:)``. Its *presence* (vs `nil`)
/// changes behaviour, so it is a wrapper rather than a bare `Component?`.
public struct OverlayUnfocusOptions {
    public var target: Component?
    public init(target: Component?) { self.target = target }
}

private func parseSizeValue(_ value: SizeValue?, reference: Int) -> Int? {
    switch value {
    case nil: return nil
    case .absolute(let n): return n
    case .percent(let p): return Int(floor((Double(reference) * p) / 100))
    }
}

// MARK: - Overlay stack entry & focus state

/// One overlay on the stack. A reference type: the renderer mutates `hidden`,
/// `focusOrder` and `preFocus` in place and compares entries by identity.
public final class OverlayStackEntry {
    let component: Component
    let options: OverlayOptions?
    var preFocus: Component?
    var hidden: Bool
    var focusOrder: Int

    init(component: Component, options: OverlayOptions?, preFocus: Component?, hidden: Bool, focusOrder: Int) {
        self.component = component
        self.options = options
        self.preFocus = preFocus
        self.hidden = hidden
        self.focusOrder = focusOrder
    }
}

/// What a blocked focus-restore resumes to once the blocker yields.
enum OverlayBlockedFocusResume {
    case restoreOverlay
    case focusTarget(Component?)
}

/// The overlay focus-restore machine. `inactive` when no overlay wants focus
/// back; `eligible` when a visible overlay should reclaim focus on the next
/// input; `blocked` when another component holds focus and the overlay must wait.
/// Ports pi's `OverlayFocusRestoreState` union.
enum OverlayFocusRestoreState {
    case inactive
    case eligible(overlay: OverlayStackEntry)
    case blocked(overlay: OverlayStackEntry, blockedBy: Component, resume: OverlayBlockedFocusResume)

    var overlay: OverlayStackEntry? {
        switch self {
        case .inactive: return nil
        case .eligible(let o): return o
        case .blocked(let o, _, _): return o
        }
    }

    var isInactive: Bool {
        if case .inactive = self { return true }
        return false
    }
}

enum OverlayFocusRestorePolicy {
    case clear
    case preserve
}

// MARK: - Segment extraction (overlay compositing)

/// Extract the "before" and "after" segments of a base line around an overlay
/// window, in a single pass. Ports `utils.ts`'s `extractSegments`.
///
/// The "after" segment inherits the SGR state that was active at the overlay's
/// left edge (tracked as escapes stream past), so styling opened before the
/// overlay still colours the content the overlay does not cover. `strictAfter`
/// drops a wide cluster that would straddle the after-window's right edge.
func extractSegments(
    _ line: String,
    beforeEnd: Int,
    afterStart: Int,
    afterLen: Int,
    strictAfter: Bool = false
) -> (before: String, beforeWidth: Int, after: String, afterWidth: Int) {
    var before = ""
    var beforeWidth = 0
    var after = ""
    var afterWidth = 0
    var currentCol = 0
    var pendingAnsiBefore = ""
    var afterStarted = false
    let afterEnd = afterStart + afterLen
    let tracker = AnsiCodeTracker()

    let chars = Array(line)
    var i = 0
    let stopCondition: () -> Bool = { afterLen <= 0 ? currentCol >= beforeEnd : currentCol >= afterEnd }

    while i < chars.count {
        if let ansi = extractAnsiCode(chars, i) {
            tracker.process(ansi.code)
            if currentCol < beforeEnd {
                pendingAnsiBefore += ansi.code
            } else if currentCol >= afterStart, currentCol < afterEnd, afterStarted {
                after += ansi.code
            }
            i += ansi.length
            continue
        }

        var textEnd = i
        while textEnd < chars.count, extractAnsiCode(chars, textEnd) == nil { textEnd += 1 }

        var broke = false
        for character in chars[i..<textEnd] {
            let w = graphemeWidth(character)
            if currentCol < beforeEnd, currentCol + w <= beforeEnd {
                if !pendingAnsiBefore.isEmpty {
                    before += pendingAnsiBefore
                    pendingAnsiBefore = ""
                }
                before.append(character)
                beforeWidth += w
            } else if currentCol >= afterStart, currentCol < afterEnd {
                let fits = !strictAfter || currentCol + w <= afterEnd
                if fits {
                    if !afterStarted {
                        after += tracker.getActiveCodes()
                        afterStarted = true
                    }
                    after.append(character)
                    afterWidth += w
                }
            }
            currentCol += w
            if stopCondition() { broke = true; break }
        }
        i = textEnd
        if broke || stopCondition() { break }
    }

    return (before, beforeWidth, after, afterWidth)
}

// MARK: - TUI overlay methods

@MainActor
public extension TUI {
    // MARK: Show / hide

    /// Show an overlay with configurable positioning and sizing, returning a
    /// handle that controls it. Captures focus unless `nonCapturing` or the
    /// overlay is not currently visible.
    @discardableResult
    func showOverlay(_ component: Component, options: OverlayOptions? = nil) -> OverlayHandle {
        focusOrderCounter += 1
        let entry = OverlayStackEntry(
            component: component,
            options: options,
            preFocus: focusedComponent,
            hidden: false,
            focusOrder: focusOrderCounter
        )
        overlayStack.append(entry)
        if !(options?.nonCapturing ?? false), isOverlayVisible(entry) {
            setFocus(component)
        }
        requestRender()
        return OverlayHandle(tui: self, entry: entry)
    }

    /// Hide the topmost overlay and restore the previous focus.
    func hideOverlay() {
        guard let overlay = overlayStack.last else { return }
        clearOverlayFocusRestoreFor(overlay)
        retargetOverlayPreFocus(overlay)
        overlayStack.removeLast()
        if focusedComponent === overlay.component {
            let topVisible = getTopmostVisibleOverlay()
            setFocus(topVisible?.component ?? overlay.preFocus)
        }
        requestRender()
    }

    /// Whether any overlay is currently visible.
    func hasOverlay() -> Bool {
        overlayStack.contains { isOverlayVisible($0) }
    }

    // MARK: Focus

    /// Set keyboard focus, clearing any pending overlay focus-restore.
    func setFocus(_ component: Component?) {
        setFocusInternal(component: component, policy: .clear)
    }

    // MARK: Layout

    /// Resolve an overlay's `(width, row, col, maxHeight)` from its options and
    /// the terminal size. Called twice per overlay: first with `overlayHeight: 0`
    /// (width/maxHeight are height-independent), then with the real height for the
    /// final row/col. Ports `resolveOverlayLayout`.
    internal func resolveOverlayLayout(
        _ options: OverlayOptions?,
        overlayHeight: Int,
        termWidth: Int,
        termHeight: Int
    ) -> (width: Int, row: Int, col: Int, maxHeight: Int?) {
        let opt = options ?? OverlayOptions()

        let marginTop = max(0, opt.margin?.top ?? 0)
        let marginRight = max(0, opt.margin?.right ?? 0)
        let marginBottom = max(0, opt.margin?.bottom ?? 0)
        let marginLeft = max(0, opt.margin?.left ?? 0)

        let availWidth = max(1, termWidth - marginLeft - marginRight)
        let availHeight = max(1, termHeight - marginTop - marginBottom)

        // Width
        var width = parseSizeValue(opt.width, reference: termWidth) ?? min(80, availWidth)
        if let minWidth = opt.minWidth { width = max(width, minWidth) }
        width = max(1, min(width, availWidth))

        // maxHeight
        var maxHeight = parseSizeValue(opt.maxHeight, reference: termHeight)
        if let mh = maxHeight { maxHeight = max(1, min(mh, availHeight)) }

        let effectiveHeight = maxHeight != nil ? min(overlayHeight, maxHeight!) : overlayHeight

        // Row
        var row: Int
        switch opt.row {
        case .percent(let p):
            let maxRow = max(0, availHeight - effectiveHeight)
            row = marginTop + Int(floor(Double(maxRow) * (p / 100)))
        case .absolute(let n):
            row = n
        case nil:
            row = resolveAnchorRow(opt.anchor ?? .center, height: effectiveHeight, availHeight: availHeight, marginTop: marginTop)
        }

        // Col
        var col: Int
        switch opt.col {
        case .percent(let p):
            let maxCol = max(0, availWidth - width)
            col = marginLeft + Int(floor(Double(maxCol) * (p / 100)))
        case .absolute(let n):
            col = n
        case nil:
            col = resolveAnchorCol(opt.anchor ?? .center, width: width, availWidth: availWidth, marginLeft: marginLeft)
        }

        if let offsetY = opt.offsetY { row += offsetY }
        if let offsetX = opt.offsetX { col += offsetX }

        row = max(marginTop, min(row, termHeight - marginBottom - effectiveHeight))
        col = max(marginLeft, min(col, termWidth - marginRight - width))

        return (width, row, col, maxHeight)
    }

    private func resolveAnchorRow(_ anchor: OverlayAnchor, height: Int, availHeight: Int, marginTop: Int) -> Int {
        switch anchor {
        case .topLeft, .topCenter, .topRight:
            return marginTop
        case .bottomLeft, .bottomCenter, .bottomRight:
            return marginTop + availHeight - height
        case .leftCenter, .center, .rightCenter:
            return marginTop + (availHeight - height) / 2
        }
    }

    private func resolveAnchorCol(_ anchor: OverlayAnchor, width: Int, availWidth: Int, marginLeft: Int) -> Int {
        switch anchor {
        case .topLeft, .leftCenter, .bottomLeft:
            return marginLeft
        case .topRight, .rightCenter, .bottomRight:
            return marginLeft + availWidth - width
        case .topCenter, .center, .bottomCenter:
            return marginLeft + (availWidth - width) / 2
        }
    }

    // MARK: Compositing

    /// Composite every visible overlay into `lines` (sorted by focus order,
    /// higher on top). Ports `compositeOverlays`.
    ///
    /// Content is padded to at least the terminal height so overlays get
    /// screen-relative positions, and each overlay row is spliced in with
    /// ``compositeLineAt`` after a defensive truncate to its declared width. This
    /// runs *before* the diff so overlays participate in it correctly.
    internal func compositeOverlays(_ lines: [String], termWidth: Int, termHeight: Int) -> [String] {
        if overlayStack.isEmpty { return lines }
        var result = lines

        struct RenderedOverlay {
            var overlayLines: [String]
            var row: Int
            var col: Int
            var w: Int
        }
        var rendered: [RenderedOverlay] = []
        var minLinesNeeded = result.count

        let visibleEntries = overlayStack
            .filter { isOverlayVisible($0) }
            .sorted { $0.focusOrder < $1.focusOrder }

        for entry in visibleEntries {
            let layout0 = resolveOverlayLayout(entry.options, overlayHeight: 0, termWidth: termWidth, termHeight: termHeight)
            var overlayLines = entry.component.render(width: layout0.width)
            if let maxHeight = layout0.maxHeight, overlayLines.count > maxHeight {
                overlayLines = Array(overlayLines.prefix(maxHeight))
            }
            let layout = resolveOverlayLayout(
                entry.options,
                overlayHeight: overlayLines.count,
                termWidth: termWidth,
                termHeight: termHeight
            )
            rendered.append(RenderedOverlay(overlayLines: overlayLines, row: layout.row, col: layout.col, w: layout0.width))
            minLinesNeeded = max(minLinesNeeded, layout.row + overlayLines.count)
        }

        // Pad to at least terminal height so overlays sit at screen-relative rows.
        let workingHeight = max(result.count, termHeight, minLinesNeeded)
        while result.count < workingHeight { result.append("") }

        let viewportStart = max(0, workingHeight - termHeight)

        for overlay in rendered {
            for i in 0..<overlay.overlayLines.count {
                let idx = viewportStart + overlay.row + i
                if idx >= 0, idx < result.count {
                    let line = overlay.overlayLines[i]
                    let truncated = visibleWidth(line) > overlay.w
                        ? sliceByColumn(line, from: 0, to: overlay.w, strict: true)
                        : line
                    result[idx] = compositeLineAt(
                        result[idx],
                        truncated,
                        startCol: overlay.col,
                        overlayWidth: overlay.w,
                        totalWidth: termWidth
                    )
                }
            }
        }

        return result
    }

    /// Splice `overlayLine` into `baseLine` at `startCol`, single pass. Ports
    /// `compositeLineAt`.
    ///
    /// The composed line's width is re-verified against `totalWidth` and, only as
    /// a last-resort safeguard, truncated — not trapped. Width tracking can drift
    /// on complex ANSI/OSC runs or a wide cluster at a boundary, and one stray
    /// column would corrupt the frame, so the belt-and-suspenders truncate stays.
    internal func compositeLineAt(
        _ baseLine: String,
        _ overlayLine: String,
        startCol: Int,
        overlayWidth: Int,
        totalWidth: Int
    ) -> String {
        let afterStart = startCol + overlayWidth
        let base = extractSegments(
            baseLine,
            beforeEnd: startCol,
            afterStart: afterStart,
            afterLen: totalWidth - afterStart,
            strictAfter: true
        )
        let overlay = sliceWithWidth(overlayLine, from: 0, to: overlayWidth, strict: true)

        let beforePad = max(0, startCol - base.beforeWidth)
        let overlayPad = max(0, overlayWidth - overlay.width)
        let actualBeforeWidth = max(startCol, base.beforeWidth)
        let actualOverlayWidth = max(overlayWidth, overlay.width)
        let afterTarget = max(0, totalWidth - actualBeforeWidth - actualOverlayWidth)
        let afterPad = max(0, afterTarget - base.afterWidth)

        let r = RenderCore.segmentReset
        let result = base.before
            + String(repeating: " ", count: beforePad)
            + r
            + overlay.text
            + String(repeating: " ", count: overlayPad)
            + r
            + base.after
            + String(repeating: " ", count: afterPad)

        let resultWidth = visibleWidth(result)
        if resultWidth <= totalWidth { return result }
        return sliceByColumn(result, from: 0, to: totalWidth, strict: true)
    }

    // MARK: Visibility helpers

    internal func isOverlayVisible(_ entry: OverlayStackEntry) -> Bool {
        if entry.hidden { return false }
        if let visible = entry.options?.visible {
            return visible(target.columns, target.rows)
        }
        return true
    }

    internal func getTopmostVisibleOverlay() -> OverlayStackEntry? {
        var topmost: OverlayStackEntry?
        for overlay in overlayStack {
            if overlay.options?.nonCapturing ?? false { continue }
            if !isOverlayVisible(overlay) { continue }
            if topmost == nil || overlay.focusOrder > topmost!.focusOrder {
                topmost = overlay
            }
        }
        return topmost
    }

    // MARK: Focus internals (the inactive|eligible|blocked machine)

    internal func setFocusInternal(component: Component?, policy: OverlayFocusRestorePolicy) {
        let previousFocus = focusedComponent
        var nextFocus = component
        let previousFocusedOverlay = previousFocus.flatMap { pf in
            overlayStack.first { $0.component === pf && isOverlayVisible($0) }
        }
        let nextFocusIsOverlay = nextFocus.map { nf in overlayStack.contains { $0.component === nf } } ?? false
        let restoreState = getVisibleOverlayFocusRestore()

        if let nf = nextFocus, !nextFocusIsOverlay {
            if case .blocked(let overlay, let blockedBy, let resume) = restoreState, blockedBy === previousFocus {
                let resumeIsTarget: Bool
                if case .focusTarget = resume { resumeIsTarget = true } else { resumeIsTarget = false }
                if resumeIsTarget || !isComponentMounted(blockedBy) {
                    nextFocus = resolveBlockedOverlayFocusResume(restoreState)
                } else {
                    overlayFocusRestore = .blocked(overlay: overlay, blockedBy: nf, resume: resume)
                }
            } else if let pfo = previousFocusedOverlay,
                      !restoreState.isInactive,
                      restoreState.overlay === pfo,
                      !isOverlayFocusAncestor(pfo, component: nf) {
                overlayFocusRestore = .blocked(overlay: pfo, blockedBy: nf, resume: .restoreOverlay)
            }
        } else if nextFocus == nil {
            if case .blocked(_, let blockedBy, _) = restoreState, blockedBy === previousFocus {
                nextFocus = resolveBlockedOverlayFocusResume(restoreState)
            } else if policy == .clear {
                clearOverlayFocusRestore()
            }
        }

        if let focusable = focusedComponent as? Focusable {
            focusable.focused = false
        }
        focusedComponent = nextFocus
        if let focusable = nextFocus as? Focusable {
            focusable.focused = true
        }

        let focusedOverlay = nextFocus.flatMap { nf in
            overlayStack.first { $0.component === nf && isOverlayVisible($0) }
        }
        if let focusedOverlay {
            overlayFocusRestore = .eligible(overlay: focusedOverlay)
        }
    }

    internal func clearOverlayFocusRestore() {
        overlayFocusRestore = .inactive
    }

    internal func clearOverlayFocusRestoreFor(_ overlay: OverlayStackEntry) {
        if !overlayFocusRestore.isInactive, overlayFocusRestore.overlay === overlay {
            clearOverlayFocusRestore()
        }
    }

    internal func resolveBlockedOverlayFocusResume(_ state: OverlayFocusRestoreState) -> Component? {
        guard case .blocked(let overlay, _, let resume) = state else { return nil }
        switch resume {
        case .restoreOverlay:
            return overlay.component
        case .focusTarget(let target):
            clearOverlayFocusRestore()
            return target
        }
    }

    internal func getVisibleOverlayFocusRestore() -> OverlayFocusRestoreState {
        if overlayFocusRestore.isInactive { return overlayFocusRestore }
        guard let overlay = overlayFocusRestore.overlay,
              overlayStack.contains(where: { $0 === overlay }),
              isOverlayVisible(overlay) else {
            return .inactive
        }
        return overlayFocusRestore
    }

    internal func isOverlayFocusAncestor(_ entry: OverlayStackEntry, component: Component) -> Bool {
        var visited: [ObjectIdentifier] = []
        var current = entry.preFocus
        while let cur = current, !visited.contains(ObjectIdentifier(cur)) {
            visited.append(ObjectIdentifier(cur))
            if cur === component { return true }
            current = overlayStack.first { $0.component === cur }?.preFocus
        }
        return false
    }

    internal func retargetOverlayPreFocus(_ removed: OverlayStackEntry) {
        for overlay in overlayStack where overlay !== removed && overlay.preFocus === removed.component {
            overlay.preFocus = removed.preFocus
        }
    }

    internal func isComponentMounted(_ component: Component) -> Bool {
        children.contains { containsComponent($0, target: component) }
    }

    internal func containsComponent(_ root: Component, target: Component) -> Bool {
        if root === target { return true }
        guard let container = root as? Container else { return false }
        return container.children.contains { containsComponent($0, target: target) }
    }

    // MARK: Input-time focus transitions (called from handleInput)

    internal func revalidateFocusedOverlayVisibility() {
        guard let focusedOverlay = overlayStack.first(where: { $0.component === focusedComponent }) else { return }
        if !isOverlayVisible(focusedOverlay) {
            if let topVisible = getTopmostVisibleOverlay() {
                setFocus(topVisible.component)
            } else {
                setFocusInternal(component: focusedOverlay.preFocus, policy: .preserve)
            }
        }
    }

    internal func applyOverlayFocusRestoreOnInput() {
        let focusIsOverlay = overlayStack.contains { $0.component === focusedComponent }
        guard !focusIsOverlay else { return }
        let restoreState = getVisibleOverlayFocusRestore()
        switch restoreState {
        case .eligible(let overlay):
            setFocus(overlay.component)
        case .blocked(let overlay, let blockedBy, let resume) where !(blockedBy === focusedComponent):
            switch resume {
            case .restoreOverlay:
                setFocus(overlay.component)
            case .focusTarget(let target):
                clearOverlayFocusRestore()
                setFocus(target)
            }
        default:
            break
        }
    }

    // MARK: Handle-backing operations

    internal func overlayHide(_ entry: OverlayStackEntry) {
        guard let index = overlayStack.firstIndex(where: { $0 === entry }) else { return }
        clearOverlayFocusRestoreFor(entry)
        retargetOverlayPreFocus(entry)
        overlayStack.remove(at: index)
        if focusedComponent === entry.component {
            let topVisible = getTopmostVisibleOverlay()
            setFocus(topVisible?.component ?? entry.preFocus)
        }
        requestRender()
    }

    internal func overlaySetHidden(_ entry: OverlayStackEntry, hidden: Bool) {
        if entry.hidden == hidden { return }
        entry.hidden = hidden
        if hidden {
            clearOverlayFocusRestoreFor(entry)
            if focusedComponent === entry.component {
                let topVisible = getTopmostVisibleOverlay()
                setFocus(topVisible?.component ?? entry.preFocus)
            }
        } else {
            if !(entry.options?.nonCapturing ?? false), isOverlayVisible(entry) {
                focusOrderCounter += 1
                entry.focusOrder = focusOrderCounter
                setFocus(entry.component)
            }
        }
        requestRender()
    }

    internal func overlayFocus(_ entry: OverlayStackEntry) {
        guard overlayStack.contains(where: { $0 === entry }), isOverlayVisible(entry) else { return }
        focusOrderCounter += 1
        entry.focusOrder = focusOrderCounter
        setFocus(entry.component)
        requestRender()
    }

    internal func overlayUnfocus(_ entry: OverlayStackEntry, options unfocusOptions: OverlayUnfocusOptions?) {
        let isFocused = focusedComponent === entry.component
        let restoreState = overlayFocusRestore
        let hasPendingRestore = !restoreState.isInactive && restoreState.overlay === entry
        if !isFocused, !hasPendingRestore { return }

        if case .blocked(let overlay, let blockedBy, _) = restoreState,
           overlay === entry,
           focusedComponent === blockedBy {
            if let unfocusOptions {
                overlayFocusRestore = .blocked(overlay: entry, blockedBy: blockedBy, resume: .focusTarget(unfocusOptions.target))
            } else {
                clearOverlayFocusRestore()
            }
            requestRender()
            return
        }

        clearOverlayFocusRestoreFor(entry)
        if isFocused || unfocusOptions != nil {
            let topVisible = getTopmostVisibleOverlay()
            let fallbackTarget = (topVisible != nil && topVisible !== entry) ? topVisible!.component : entry.preFocus
            setFocus(unfocusOptions != nil ? unfocusOptions!.target : fallbackTarget)
        }
        requestRender()
    }
}

// MARK: - OverlayHandle

/// A controller for a shown overlay. Ports pi's `OverlayHandle` object: the same
/// six operations, forwarded to the owning ``TUI``.
@MainActor
public final class OverlayHandle {
    private weak var tui: TUI?
    private let entry: OverlayStackEntry

    init(tui: TUI, entry: OverlayStackEntry) {
        self.tui = tui
        self.entry = entry
    }

    /// Permanently remove the overlay.
    public func hide() { tui?.overlayHide(entry) }
    /// Temporarily hide or show without removing from the stack.
    public func setHidden(_ hidden: Bool) { tui?.overlaySetHidden(entry, hidden: hidden) }
    /// Whether the overlay is temporarily hidden.
    public func isHidden() -> Bool { entry.hidden }
    /// Focus this overlay and bring it to the visual front.
    public func focus() { tui?.overlayFocus(entry) }
    /// Release focus to the next visible overlay, the previous target, or an
    /// explicit target when `options` is provided.
    public func unfocus(_ options: OverlayUnfocusOptions? = nil) { tui?.overlayUnfocus(entry, options: options) }
    /// Whether this overlay currently holds focus.
    public func isFocused() -> Bool { tui?.focusedComponent === entry.component }
}
