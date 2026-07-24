// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/components/loader.ts
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/components/cancellable-loader.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness. The frame set, the message/spinner
// colour split, and the leading-blank-line render shape are ported. The one
// deliberate divergence is the animation clock: pi drives frames from a hidden
// `setInterval` and calls `ui.requestRender()` from inside the timer callback.
// The brief requires the frame advance to be a method a test can step
// (`tick()`), so no timer lives in this component — a live caller pairs a clock
// of its own with `tick()` + `TUI.requestRender()`. This keeps the spinner a
// pure, deterministic function of its frame index.

import DoMoTermIO

// MARK: - Loader

/// An animated spinner followed by a message.
///
/// The frame is a plain index into ``frames`` that advances only when ``tick()``
/// is called — there is no embedded timer, so a test steps the animation frame
/// by frame and asserts the output, and a live UI drives `tick()` from whatever
/// clock it already runs. ``intervalMs`` is advisory metadata for that driver,
/// not a timer this component honours itself.
///
/// Rendering mirrors pi: a leading blank line, then the coloured spinner glyph,
/// a space, and the coloured message, word-wrapped to the width so no emitted
/// line can exceed the budget.
open class Loader: Component {
    /// pi's `DEFAULT_FRAMES` — the ten-phase braille spinner.
    public static let defaultFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    /// pi's `DEFAULT_INTERVAL_MS`.
    public static let defaultIntervalMs = 80

    private var frames: [String]
    private var currentFrame = 0
    private let spinnerColor: (String) -> String
    private let messageColor: (String) -> String
    private var renderIndicatorVerbatim: Bool

    /// The message shown after the spinner.
    public var message: String
    /// Advisory frame interval for an external animation driver, in milliseconds.
    public private(set) var intervalMs: Int

    public init(
        spinnerColor: @escaping (String) -> String = { $0 },
        messageColor: @escaping (String) -> String = { $0 },
        message: String = "Loading...",
        frames: [String]? = nil,
        intervalMs: Int? = nil
    ) {
        self.spinnerColor = spinnerColor
        self.messageColor = messageColor
        self.message = message
        // pi: an explicitly-supplied indicator is rendered verbatim (the caller
        // owns its colour); the default frame set is coloured by `spinnerColor`.
        self.renderIndicatorVerbatim = frames != nil
        self.frames = frames ?? Loader.defaultFrames
        let requested = intervalMs ?? Loader.defaultIntervalMs
        self.intervalMs = requested > 0 ? requested : Loader.defaultIntervalMs
    }

    /// The current frame index — exposed so a test can assert the advance.
    public var frameIndex: Int { currentFrame }

    /// Advance to the next spinner frame, wrapping. A no-op for a static
    /// indicator (zero or one frame), matching pi's `restartAnimation` guard.
    public func tick() {
        guard frames.count > 1 else { return }
        currentFrame = (currentFrame + 1) % frames.count
    }

    /// Replace the message shown after the spinner.
    public func setMessage(_ message: String) {
        self.message = message
    }

    /// Replace the animation frames (and optional interval), resetting to frame 0.
    /// An explicit frame set is rendered verbatim; passing `nil` restores the
    /// default coloured braille spinner. Ports pi's `setIndicator`.
    public func setIndicator(frames: [String]?, intervalMs: Int? = nil) {
        renderIndicatorVerbatim = frames != nil
        self.frames = frames ?? Loader.defaultFrames
        let requested = intervalMs ?? Loader.defaultIntervalMs
        self.intervalMs = requested > 0 ? requested : Loader.defaultIntervalMs
        currentFrame = 0
    }

    public func render(width: Int) -> [String] {
        guard width > 0 else { return [""] }
        let frame = currentFrame < frames.count ? frames[currentFrame] : ""
        let renderedFrame = renderIndicatorVerbatim ? frame : spinnerColor(frame)
        let indicator = frame.isEmpty ? "" : "\(renderedFrame) "
        let text = indicator + messageColor(message)
        // Leading blank line then the wrapped text — pi's `["", ...super.render]`.
        // wrapTextWithAnsi guarantees every line fits the width budget.
        return [""] + wrapTextWithAnsi(text, width)
    }
}

// MARK: - CancellableLoader

/// A ``Loader`` the user can cancel with Escape / Ctrl+C.
///
/// pi wires this to an `AbortController` whose `signal` an async operation
/// watches. Swift has no ambient AbortController, so cancellation surfaces two
/// ways a caller can consume: the ``cancelled`` flag and the ``onCancel``
/// callback, both tripped when input matches the `tui.select.cancel` semantic id
/// under the injected ``Keybindings``. A caller that wants task cancellation
/// bridges `onCancel` to its own `Task`/continuation.
public final class CancellableLoader: Loader {
    private let keybindings: Keybindings

    /// Whether the loader has been cancelled.
    public private(set) var cancelled = false
    /// Fired once when the user cancels.
    public var onCancel: (() -> Void)?

    public init(
        spinnerColor: @escaping (String) -> String = { $0 },
        messageColor: @escaping (String) -> String = { $0 },
        message: String = "Loading...",
        frames: [String]? = nil,
        intervalMs: Int? = nil,
        keybindings: Keybindings = Keybindings()
    ) {
        self.keybindings = keybindings
        super.init(
            spinnerColor: spinnerColor, messageColor: messageColor,
            message: message, frames: frames, intervalMs: intervalMs
        )
    }

    public func handleInput(_ data: [UInt8]) {
        guard !cancelled else { return }
        if keybindings.matches(data, .selectCancel) {
            cancelled = true
            onCancel?()
        }
    }
}
