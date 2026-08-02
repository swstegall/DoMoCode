// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// One full-screen-client end-to-end test at a time, across the whole test
// binary.
//
// `@Suite(.serialized)` serializes a suite against ITSELF and nothing else, and
// there are now several suites that each stand up a real `DoMoServer`, a real
// `ServerClient`, a real `TerminalDriver` and an SSE stream, then drive them
// from the SAME main actor while polling a VT100 emulator. Run two of those at
// once and they do not fail cleanly: they starve each other's render loop, and
// the test that notices is whichever one has a deadline — which made a green
// suite depend on which machine it ran on.
//
// A plain `Bool` plus a queue of continuations rather than a semaphore package:
// an actor gives mutual exclusion for free, and FIFO ordering keeps a waiting
// test from being starved by a stream of new arrivals.

import Foundation

/// A one-at-a-time gate for tests that run the whole full-screen client.
///
/// `WedgeClient.make` acquires the gate before returning a client; tests that
/// acquire it before creating one pass `ownsFullScreenGate: false` to avoid
/// acquiring it twice.
actor FullScreenClientGate {
    static let shared = FullScreenClientGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<FullScreenClientGateLease, Error>
    }

    private var busy = false
    private var waiters: [Waiter] = []

    /// Wait until no other end-to-end client test is running, or throw if the
    /// waiting test is cancelled. A raw continuation cannot observe
    /// cancellation: leaving one in `waiters` strands every test behind it.
    func acquire() async throws -> FullScreenClientGateLease {
        let id = UUID()
        let lease = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<FullScreenClientGateLease, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !busy {
                    busy = true
                    continuation.resume(returning: FullScreenClientGateLease(gate: self))
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancel(id: id) }
        })

        // Cancellation can race with `leave()` granting this waiter. In that
        // case the waiter is no longer in the queue, so the cancellation
        // callback cannot remove it; give the permit back before propagating
        // cancellation instead.
        if Task.isCancelled {
            await lease.release()
            throw CancellationError()
        }
        return lease
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Hand the gate to the next waiter, or open it.
    func leave() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: FullScreenClientGateLease(gate: self))
    }
}

/// An idempotent permit for one full-screen client.
///
/// A client can be asked to stop from either its normal input path or the test
/// task's cancellation path. Keeping release separate from the client task
/// means either path can hand the permit back without double-releasing it — or
/// leaving the next test queued behind a task that was already cancelled.
actor FullScreenClientGateLease {
    private let gate: FullScreenClientGate
    private var released = false

    init(gate: FullScreenClientGate) {
        self.gate = gate
    }

    func release() async {
        guard !released else { return }
        released = true
        await gate.leave()
    }
}
