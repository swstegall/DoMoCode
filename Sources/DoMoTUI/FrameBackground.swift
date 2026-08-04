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
