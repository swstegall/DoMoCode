// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoAgent
import DoMoLLM
import DoMoServer
import Testing

@Suite("BroadcastEventSink fan-out")
struct BroadcastEventSinkTests {

    @Test("An emitted event reaches a subscriber, projected")
    func emitReachesSubscriber() async {
        let sink = BroadcastEventSink()
        let sub = sink.subscribe()
        await sink.emit(.agentStart)
        var it = sub.events.makeAsyncIterator()
        let received = await it.next()
        #expect(received == .agentStart)
    }

    @Test("Every subscriber receives every event")
    func fanOutToAll() async {
        let sink = BroadcastEventSink()
        let a = sink.subscribe()
        let b = sink.subscribe()
        await sink.emit(.turnStart)
        var ia = a.events.makeAsyncIterator()
        var ib = b.events.makeAsyncIterator()
        let ra = await ia.next()
        let rb = await ib.next()
        #expect(ra == .turnStart)
        #expect(rb == .turnStart)
    }

    @Test("Subscriber count tracks subscribe/unsubscribe")
    func subscriberCount() {
        let sink = BroadcastEventSink()
        #expect(sink.subscriberCount == 0)
        let sub = sink.subscribe()
        #expect(sink.subscriberCount == 1)
        sink.unsubscribe(sub.id)
        #expect(sink.subscriberCount == 0)
    }

    @Test("Unsubscribe finishes the stream")
    func unsubscribeFinishes() async {
        let sink = BroadcastEventSink()
        let sub = sink.subscribe()
        sink.unsubscribe(sub.id)
        var it = sub.events.makeAsyncIterator()
        let received = await it.next()
        #expect(received == nil)
    }

    @Test("A server-originated frame broadcasts to subscribers")
    func broadcastServerFrame() async {
        let sink = BroadcastEventSink()
        let sub = sink.subscribe()
        sink.broadcast(.connected(protocolVersion: serverProtocolVersion, sessionID: "s-1"))
        var it = sub.events.makeAsyncIterator()
        let received = await it.next()
        #expect(received == .connected(protocolVersion: serverProtocolVersion, sessionID: "s-1"))
    }

    @Test("A non-projecting event is dropped, not forwarded as an empty frame")
    func nonProjectingEventDropped() async {
        let sink = BroadcastEventSink()
        let sub = sink.subscribe()
        // A completed-snapshot assembly frame projects to nil.
        await sink.emit(.messageUpdate(message: .user("x"), assembly: .done(AssistantMessage(model: "m"))))
        await sink.emit(.turnStart)
        var it = sub.events.makeAsyncIterator()
        let received = await it.next()
        // The first thing the subscriber sees is turnStart — the .done was dropped.
        #expect(received == .turnStart)
    }

    @Test("closeAll finishes every stream and clears the registry")
    func closeAllFinishes() async {
        let sink = BroadcastEventSink()
        // Both subscriptions must stay alive: a dropped `Subscription` auto-
        // unregisters (that is the correct behaviour when an SSE stream is
        // discarded), which would defeat the count assertion. Using both at the
        // end keeps them live through the checks in debug and release.
        let a = sink.subscribe()
        let b = sink.subscribe()
        #expect(sink.subscriberCount == 2)
        sink.closeAll()
        #expect(sink.subscriberCount == 0)
        var ia = a.events.makeAsyncIterator()
        let ra = await ia.next()
        #expect(ra == nil)
        var ib = b.events.makeAsyncIterator()
        let rb = await ib.next()
        #expect(rb == nil)
    }

    @Test("emit never blocks on a subscriber that never reads")
    func emitIsNonBlocking() async {
        let sink = BroadcastEventSink(perSubscriberBuffer: 8)
        let sub = sink.subscribe()  // retained but never consumed
        // Far more than the buffer holds; drop-oldest must keep emit non-blocking.
        // If emit awaited the consumer this test would hang and time out.
        for _ in 0..<1000 {
            await sink.emit(.turnStart)
        }
        #expect(sink.subscriberCount == 1)
        withExtendedLifetime(sub) {}
    }
}
