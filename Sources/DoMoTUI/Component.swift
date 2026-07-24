// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/tui.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

// MARK: - Component

/// The one thing every piece of on-screen UI must do: turn a viewport width into
/// a list of lines.
///
/// The renderer never asks a component *where* it is or *how tall* it is — it
/// asks for lines at a width and stacks the results. That single method is what
/// lets the differential renderer treat the whole tree as an opaque
/// `[String]`-producer and diff the flattened output, which is the only state it
/// actually needs to reason about.
///
/// `render` is the sole requirement. Input handling, key-release opt-in, and
/// cache invalidation all have defaults so a purely presentational component
/// (`Text`, `Spacer`) implements exactly one method.
///
/// Reference semantics are the norm: a component carries mutable UI state
/// (focus, scroll offset, a spinner frame) that the renderer and input dispatch
/// both reach, so components are classes. The protocol is `AnyObject` so the
/// renderer can compare components by identity — focus, the overlay stack and
/// mount checks all key off `===`, exactly as pi keys off JS reference equality.
///
/// `MainActor` by module default: the render loop, input dispatch and timers are
/// one thread, so a component never has to reason about concurrency.
public protocol Component: AnyObject {
    /// Render to lines for the given viewport width.
    ///
    /// Each returned string is one screen line. A component **must** keep every
    /// line's visible width within `width`; the renderer treats an over-wide line
    /// as fatal (it would shift every following column), so measure with
    /// ``visibleWidth(_:)`` and clip with ``truncateToWidth(_:_:ellipsis:pad:)``.
    func render(width: Int) -> [String]

    /// Handle keyboard input while this component holds focus.
    ///
    /// Receives the raw framed bytes (a decoded key press or a paste payload),
    /// not a parsed key — components consult `Keybindings` themselves so binding
    /// policy lives with the component, never in the renderer. Default: ignore.
    func handleInput(_ data: [UInt8])

    /// Whether this component wants Kitty key-*release* events.
    ///
    /// Release events are noise for almost everything, so the renderer drops them
    /// unless a component (a game, a push-to-talk affordance) opts in. Default:
    /// `false`.
    var wantsKeyRelease: Bool { get }

    /// Drop any cached render state.
    ///
    /// Called when something outside the component's own inputs changes what it
    /// should draw — a theme switch, a terminal-cell-size report — so a component
    /// that memoizes its lines must recompute. Default: do nothing.
    func invalidate()
}

public extension Component {
    func handleInput(_ data: [UInt8]) {}
    var wantsKeyRelease: Bool { false }
    func invalidate() {}
}

// MARK: - Focusable

/// A component that can hold keyboard focus and show a hardware cursor.
///
/// When ``focused`` is true the component should emit ``cursorMarker`` at its
/// caret position; the renderer finds that marker, strips it, and drives the real
/// terminal cursor there so IME candidate windows land in the right place. The
/// flag is a stored property the renderer writes on focus changes — an editor
/// reads it to decide whether to draw its caret at all.
public protocol Focusable: Component {
    /// Set by the renderer when focus changes. `true` means "you have the caret".
    var focused: Bool { get set }
}

/// The APC cursor-position marker a focused component emits at its caret.
///
/// An Application Program Command sequence terminals ignore (zero visible width),
/// so it can sit inside a rendered line without disturbing layout. The renderer
/// locates it, measures the visible width before it to get the column, strips it,
/// and positions the hardware cursor there. Kept byte-for-byte identical to pi's
/// `CURSOR_MARKER` so any future editor port emits the exact sequence.
public let cursorMarker = "\u{1b}_pi:c\u{07}"

// MARK: - Container

/// A component that stacks its children's line arrays, top to bottom.
///
/// The workhorse of composition: it does no layout beyond concatenation, because
/// the inline model has no 2-D geometry to lay out — every child contributes a
/// run of lines and the screen is those runs in order. `TUI` itself is a
/// `Container`, so the root of the tree and every branch share one render rule.
open class Container: Component {
    public private(set) var children: [Component] = []

    public init() {}

    public func addChild(_ component: Component) {
        children.append(component)
    }

    public func removeChild(_ component: Component) {
        if let index = children.firstIndex(where: { $0 === component }) {
            children.remove(at: index)
        }
    }

    public func clear() {
        children = []
    }

    public func invalidate() {
        for child in children { child.invalidate() }
    }

    public func render(width: Int) -> [String] {
        var lines: [String] = []
        for child in children {
            lines.append(contentsOf: child.render(width: width))
        }
        return lines
    }
}
