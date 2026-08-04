// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// Deterministic horizontal scrolling for a single terminal row.
///
/// A marquee pauses at both ends, advances one cell at a time, and returns to the
/// start only after the end pause. The state is keyed by an identity supplied by
/// the caller, so a changed notice, resized row, or different hovered item starts
/// a fresh pause instead of inheriting a stale offset. The clock is an argument,
/// which keeps the rendering oracle independent of wall-clock scheduling.
public struct MarqueeState: Equatable, Sendable {
    public private(set) var identity: String?
    public private(set) var startedAt: Double

    public init() {
        identity = nil
        startedAt = 0
    }

    public mutating func reset(identity: String, now: Double) {
        self.identity = identity
        startedAt = now
    }
}

public enum Marquee {
    /// The initial pause lets the left edge be read before motion starts.
    public static let leadingPause: Double = 0.8
    /// The final pause lets the right edge — including controls at the tail — be
    /// read before the text returns to the beginning.
    public static let trailingPause: Double = 1.0
    /// One-cell movement cadence.
    public static let stepDuration: Double = 0.25
    /// Blank cells between the end and beginning of the repeated text.
    public static let separator = "  "

    public static func isNeeded(_ text: String, width: Int) -> Bool {
        width > 0 && visibleWidth(text) > width
    }

    /// Return `text` fitted to `width`, scrolling it when it is wider than the
    /// available cell window. `identity` should include any state that changes
    /// what the row means, not merely the visible text.
    public static func render(
        _ text: String,
        width: Int,
        identity: String,
        now: Double,
        state: inout MarqueeState
    ) -> String {
        guard width > 0 else { return "" }
        let totalWidth = visibleWidth(text)
        guard totalWidth > width else {
            state.reset(identity: identity, now: now)
            return text
        }

        if state.identity != identity {
            state.reset(identity: identity, now: now)
        }

        let travel = totalWidth - width
        let activeDuration = Double(travel) * stepDuration
        let cycleDuration = leadingPause + activeDuration + trailingPause
        let elapsed = max(0, now - state.startedAt)
        let phase = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        let offset: Int
        if phase < leadingPause {
            offset = 0
        } else if phase < leadingPause + activeDuration {
            offset = min(travel, Int((phase - leadingPause) / stepDuration))
        } else {
            offset = travel
        }

        let repeated = text + separator + text
        return padToWidth(
            sliceByColumn(repeated, from: offset, to: offset + width, strict: true),
            width
        )
    }
}
