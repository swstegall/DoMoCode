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

/// A one-at-a-time gate for tests that run the whole full-screen client.
///
/// `WedgeClient.make` acquires the gate before returning a client; tests that
/// acquire it before creating one pass `ownsFullScreenGate: false` to avoid
/// acquiring it twice.
actor FullScreenClientGate {
    static let shared = FullScreenClientGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Wait until no other end-to-end client test is running.
    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hand the gate to the next waiter, or open it.
    func leave() {
        guard !waiters.isEmpty else {
            busy = false
            return
        }
        waiters.removeFirst().resume()
    }
}
