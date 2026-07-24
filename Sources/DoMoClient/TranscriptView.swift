// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The main pane: renders the event store's transcript to lines. Each item gets a
// role marker and wraps to the pane width; reasoning is dimmed; a tool call is a
// header line plus a capped, indented slice of its output. The app refreshes
// `items` from the store before each frame; scrolling to the newest content is
// the `TailBox` wrapper's job, not this view's.

import DoMoTUI

/// Renders `[TranscriptItem]` to width-fitted lines for the main pane.
@MainActor
final class TranscriptView: Component {
    /// The transcript to render; set from `EventStore.transcript` each frame.
    var items: [TranscriptItem] = []
    /// Whether the selected session has a turn in flight (shows a streaming hint).
    var running = false

    /// How many lines of a tool's output to show before eliding the rest.
    private let toolOutputCap = 8
    /// Never wrap more tool-output characters than could fill the cap — the rest is
    /// never shown, so wrapping it would be pure wasted (and unbounded) work.
    private let toolOutputCharCap = 4000

    /// Memoize the wrapped lines: the transcript is re-rendered every frame (e.g.
    /// on every keystroke in the input pane), but only actually changes when a new
    /// event lands, so an unchanged transcript must not re-wrap. Keyed on the
    /// content, the width, and the streaming flag.
    private var cache: (items: [TranscriptItem], running: Bool, width: Int, lines: [String])?

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        if let cache, cache.width == width, cache.running == running, cache.items == items {
            return cache.lines
        }
        let lines = renderLines(width: width)
        cache = (items, running, width, lines)
        return lines
    }

    private func renderLines(width: Int) -> [String] {
        var lines: [String] = []
        for item in items {
            switch item {
            case .user(let text):
                lines += labeledWrap("› ", text, width: width)
            case .assistant(let text):
                lines += wrapToWidth(text, width: width)
            case .reasoning(let text):
                lines += wrapToWidth(text, width: width).map(dim)
            case .tool(let name, let output, let isError, let imageCount):
                lines.append(toolHeader(name: name, isError: isError, imageCount: imageCount, width: width))
                lines += toolBody(output, width: width)
            }
            lines.append("")   // a blank spacer between items
        }
        if running { lines.append(dim("…")) }
        return lines
    }

    private func toolHeader(name: String, isError: Bool, imageCount: Int, width: Int) -> String {
        var header = (isError ? "✗ " : "⚙ ") + name
        if imageCount > 0 { header += " [\(imageCount) image\(imageCount == 1 ? "" : "s")]" }
        let styled = isError ? header : dim(header)
        return truncateToWidth(styled, width)
    }

    private func toolBody(_ output: String, width: Int) -> [String] {
        guard !output.isEmpty else { return [] }
        // Bound the work: only the first `toolOutputCap` lines are ever shown, so
        // never wrap more than a capped slice of the raw output.
        let overCharCap = output.count > toolOutputCharCap
        let bounded = overCharCap ? String(output.prefix(toolOutputCharCap)) : output
        var wrapped = wrapToWidth(bounded, width: max(1, width - 2)).map { "  " + $0 }
        if wrapped.count > toolOutputCap || overCharCap {
            wrapped = Array(wrapped.prefix(toolOutputCap)) + [dim("  … (output truncated)")]
        }
        return wrapped
    }
}
