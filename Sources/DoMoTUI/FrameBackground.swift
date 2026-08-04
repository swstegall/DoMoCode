// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// Paints the selected page background into every cell of a full-screen frame.
///
/// A component's row may be empty, padded, or end a local SGR span. Applying the
/// background at the frame boundary makes those cases equivalent: every blank
/// cell receives the selected background, while a component can still opt out by
/// selecting ``ThemeColor/inherit``. Re-applying the background after a local SGR
/// reset keeps a component's reset from turning the rest of the page back into the
/// terminal default.
public func paintFrameBackground(
    _ lines: [String],
    width: Int,
    color: ThemeColor,
    trueColor: Bool = true
) -> [String] {
    guard width > 0 else { return lines }
    let background = color.background(trueColor: trueColor)
    guard !background.isEmpty else { return lines }

    let reset = "\u{1b}[0m"
    return lines.map { line in
        let fitted = visibleWidth(line) < width ? padToWidth(line, width) : line
        let restated = fitted.replacingOccurrences(of: reset, with: reset + background)
        return background + restated + reset
    }
}

/// Paints the selected page foreground into every cell of a full-screen frame.
///
/// This is the foreground counterpart to ``paintFrameBackground``. It matters
/// especially for plain dialog text: a component that emits no foreground SGR
/// otherwise inherits whatever color the terminal happened to have before the
/// alternate screen started, which made the light theme unreadable in iTerm2.
/// Restating the foreground after local resets keeps component-level styling
/// isolated without allowing a reset to fall back to the terminal default.
public func paintFrameForeground(
    _ lines: [String],
    width: Int,
    color: ThemeColor,
    trueColor: Bool = true
) -> [String] {
    guard width > 0 else { return lines }
    let foreground = color.foreground(trueColor: trueColor)
    guard !foreground.isEmpty else { return lines }

    let reset = "\u{1b}[0m"
    return lines.map { line in
        let fitted = visibleWidth(line) < width ? padToWidth(line, width) : line
        let restated = fitted.replacingOccurrences(of: reset, with: reset + foreground)
        return foreground + restated + reset
    }
}
