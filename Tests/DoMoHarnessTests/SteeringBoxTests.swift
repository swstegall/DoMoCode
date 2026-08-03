import DoMoHarness
import DoMoLLM
import Testing

@Suite("SteeringBox")
struct SteeringBoxTests {
    @Test("one-at-a-time preserves order and leaves later messages queued")
    func oneAtATime() {
        let box = SteeringBox()
        box.enqueue(contentsOf: [.user("first"), .user("second"), .user("third")])

        #expect(box.count == 3)
        #expect(box.drain() == [.user("first")])
        #expect(box.count == 2)
        #expect(box.drain() == [.user("second")])
        #expect(box.drain() == [.user("third")])
        #expect(box.drain().isEmpty)
    }

    @Test("all delivers the complete batch")
    func all() {
        let box = SteeringBox(mode: .all)
        let messages: [Message] = [.user("first"), .user("second")]
        box.enqueue(contentsOf: messages)

        #expect(box.drain() == messages)
        #expect(box.count == 0)
    }

    @Test("drainAll and clear ignore the delivery mode")
    func drainAllAndClear() {
        let box = SteeringBox(mode: .oneAtATime)
        box.enqueue(contentsOf: [.user("first"), .user("second")])

        #expect(box.drainAll() == [.user("first"), .user("second")])
        #expect(box.count == 0)

        box.enqueue(.user("third"))
        box.clear()
        #expect(box.count == 0)
    }

    @Test("mode can change without disturbing queued order")
    func modeChange() {
        let box = SteeringBox()
        box.enqueue(contentsOf: [.user("first"), .user("second")])
        box.mode = .all

        #expect(box.drain() == [.user("first"), .user("second")])
    }
}
