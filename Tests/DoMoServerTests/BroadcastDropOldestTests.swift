// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Pins the fact that justifies `GET /session/{id}/status` existing at all.
//
// Both broadcast hops are `.bufferingNewest(N)`, which drops the OLDEST buffered
// element, not the newest. So the frame a slow subscriber loses is the one that
// arrived FIRST — and the first frame of a stall is precisely the interesting one
// (a `permission_request` the run is now parked on). Once a frame like that is
// gone, no further edge is coming: the client believes a run is in flight forever
// and there is nothing to un-believe it with. That is why run state needs a
// level-triggered query, not just an event stream.

import DoMoAgent
import DoMoCore
import DoMoLLM
import DoMoServer
import Testing

@Suite
struct BroadcastDropOldestTests {

    @Test("A slow subscriber loses its OLDEST frames, not its newest")
    func slowSubscriberLosesTheOldest() async throws {
        let sink = BroadcastEventSink(perSubscriberBuffer: 4)
        let subscription = sink.subscribe()

        // The ask first, then enough traffic to overflow the buffer, then the
        // close. Nothing is read until after every broadcast, so the buffer
        // genuinely overflows.
        sink.broadcast(.permissionRequest(
            id: "per_1",
            sessionID: "s",
            permission: "bash",
            patterns: [],
            always: [],
            metadata: [:],
            disableAlways: false
        ))
        for index in 0..<8 {
            sink.broadcast(.messageDelta(text: "chunk \(index)", reasoning: nil))
        }
        sink.broadcast(.agentEnd(reason: "completed"))
        sink.unsubscribe(subscription.id)

        var received: [ServerEvent] = []
        for await event in subscription.events { received.append(event) }

        #expect(received.count == 4, "buffer policy changed: got \(received.count) frames")
        #expect(
            !received.contains { if case .permissionRequest = $0 { true } else { false } },
            "the permission ask survived — if drop-oldest ever becomes drop-newest, revisit the status poll"
        )
        #expect(
            received.contains { if case .agentEnd = $0 { true } else { false } },
            "the terminal frame was dropped, which would be a far worse failure mode"
        )
    }

    @Test("A subscriber that keeps up loses nothing")
    func keepingUpLosesNothing() async throws {
        let sink = BroadcastEventSink(perSubscriberBuffer: 4)
        let subscription = sink.subscribe()

        let reader = Task { () -> Int in
            var count = 0
            for await _ in subscription.events {
                count += 1
                if count == 12 { return count }
            }
            return count
        }
        for index in 0..<12 {
            sink.broadcast(.messageDelta(text: "chunk \(index)", reasoning: nil))
            // Give the reader a chance to drain, so the buffer never overflows.
            await Task.yield()
        }
        #expect(await reader.value == 12)
        sink.unsubscribe(subscription.id)
    }
}
