// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The client's read model. The server streams a projection of the runtime's
// events (deltas, not snapshots); the client folds that stream — plus the REST
// history it seeds from — into this flat, renderable transcript. One item per
// visible block, in arrival order, is all the two-pane main view needs.

import DoMoLLM

// MARK: - Transcript item

/// One rendered block in a session transcript.
///
/// Deliberately smaller than ``DoMoLLM/Message``: the UI shows who spoke and what
/// they said, plus a compact line per tool call. Reasoning is kept separate so it
/// can be dimmed or hidden. Streaming grows the string in place — an ``assistant``
/// or ``reasoning`` item's text accumulates as `message_delta` frames arrive, then
/// is replaced with the authoritative text on `message_end`.
public enum TranscriptItem: Sendable, Hashable {
    /// A user prompt.
    case user(String)
    /// Assistant output. Grows during streaming, finalized on `message_end`.
    case assistant(String)
    /// Assistant reasoning, when the gateway forwarded it.
    case reasoning(String)
    /// A tool invocation and its result. `output` is empty while the tool runs
    /// (between `tool_start` and `tool_end`).
    case tool(name: String, output: String, isError: Bool, imageCount: Int)
    /// An image to display inline — a user attachment or a tool-produced image.
    /// The `imageId` is a stable Kitty id, allocated once when the item is created,
    /// so the differential renderer can track and delete the image across frames.
    case image(ImageBlock, imageId: UInt32)
}
