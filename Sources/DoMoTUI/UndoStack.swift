// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/tui/src/undo-stack.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

// MARK: - UndoStack

/// A generic snapshotting undo stack.
///
/// pi clones each pushed snapshot with `structuredClone` because its state is a
/// graph of mutable JS objects that a later edit would otherwise alias. This port
/// needs no clone step: `S` is expected to be a value type (the editor pushes a
/// struct of `[[Character]]`, `[Int: String]`, and `Int` fields), so appending it
/// to the backing array already copies it — a popped snapshot is a fully detached
/// value with no shared references back into live state. Keeping the type generic
/// preserves pi's shape: the editor decides *what* a snapshot is, the stack only
/// owns the ordering.
struct UndoStack<S> {
    private var stack: [S] = []

    /// Push a snapshot. Value-type `S` is copied by the append, which is what
    /// makes the stored snapshot independent of subsequent mutation.
    mutating func push(_ state: S) {
        stack.append(state)
    }

    /// Pop and return the most recent snapshot, or `nil` when empty.
    mutating func pop() -> S? {
        stack.popLast()
    }

    /// Remove all snapshots.
    mutating func clear() {
        stack.removeAll()
    }

    var count: Int { stack.count }
}
