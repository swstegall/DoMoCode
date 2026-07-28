// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// One staged attachment, shown as a chip above the prompt and sent with the next
// submit. Its own file rather than a nested type in PromptInput, because the
// prompt input, the app that resolves a drop off the main actor, and the layout
// that budgets chip rows all name it — and because the prompt input is due a
// rewrite it should not be able to take this shape with it.

import DoMoLLM

/// One staged attachment shown as a chip above the prompt.
///
/// It carries the BYTES, not just a path. Three things follow from that, and all
/// three are the point:
///
/// - Reading at drop time puts the failure next to the gesture that caused it. A
///   file that is missing, unreadable, too large or not an image is refused
///   while the user is still looking at where they dropped it, rather than at
///   submit, several seconds later, attached to a message they thought they sent.
/// - Submit stays pure send-with-no-IO. It cannot block the render loop on a
///   disk read and it cannot fail for a reason the prompt is not about.
/// - There is no window in which the file changes between the chip and the send.
///   What the chip claims is attached is what is attached.
///
/// `Hashable` — and therefore usable as a render-memo key — because
/// ``DoMoLLM/ImageBlock`` is `Sendable, Hashable`.
struct PromptAttachment: Sendable, Hashable, Identifiable {
    /// Stable across renders, so removing a chip is unambiguous even when two
    /// attachments share a basename or a path.
    let id: UInt32

    /// Absolute canonical path — the chip's full identity, and what a duplicate
    /// check compares.
    let path: String

    /// Basename, for the chip label.
    ///
    /// NOT sanitized here. A filename can legally contain an escape sequence, so
    /// it is untrusted text like any other; the UI applies `sanitizeUntrustedText`
    /// at the point it renders, which is the one place that can also get the
    /// width arithmetic right.
    let name: String

    let byteCount: Int

    /// Ready to hand to `ServerClient.sendPrompt(images:)` with no further work.
    let image: ImageBlock

    init(id: UInt32, path: String, name: String, byteCount: Int, image: ImageBlock) {
        self.id = id
        self.path = path
        self.name = name
        self.byteCount = byteCount
        self.image = image
    }
}
