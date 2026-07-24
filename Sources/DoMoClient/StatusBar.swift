// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTUI

/// A one-line status bar; the app sets `text` each frame.
@MainActor
final class StatusBar: Component {
    var text = ""

    func render(width: Int) -> [String] {
        guard width > 0 else { return [] }
        return [truncateToWidth(dim(text), width)]
    }
}
