// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoTermIO
import Testing

@Suite("PTY service", .serialized)
struct PTYTests {

    @Test("Replay then activate does not lose bytes written between the two steps")
    func replayThenActivateClosesTheRace() async throws {
        let service = PTYService(maximumRetainedBytes: 1_024)
        let id = try await service.start(.init(
            command: ["/bin/sh", "-c", "printf first; sleep 0.15; printf second"],
            workingDirectory: "/tmp"
        ))

        for _ in 0..<100 where (await service.snapshot(sessionID: id)?.nextSequence ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let attachment = try await service.beginAttach(sessionID: id)
        // The second write happens after the replay reservation but before the
        // subscription is activated — the exact interval that a plain
        // subscribe-then-replay design loses.
        try await Task.sleep(for: .milliseconds(250))
        let stream = try await service.activate(sessionID: id, attachmentID: attachment.id)

        var bytes = Self.outputBytes(attachment.replay)
        for await event in stream {
            if case .output(_, let chunk) = event { bytes.append(contentsOf: chunk) }
        }
        #expect(String(decoding: bytes, as: UTF8.self) == "firstsecond")
        #expect(attachment.nextSequence > 0)
        await service.shutdown()
    }

    @Test("The PTY accepts input and the child sees a terminal-sized session")
    func inputRoundTrip() async throws {
        let service = PTYService()
        let id = try await service.start(.init(
            command: ["/bin/sh", "-c", "read line; printf 'got:%s' \"$line\""],
            workingDirectory: "/tmp",
            size: PTYSize(columns: 91, rows: 37)
        ))
        let attachment = try await service.beginAttach(sessionID: id)
        let stream = try await service.activate(sessionID: id, attachmentID: attachment.id)
        #expect(await service.write(sessionID: id, bytes: Array("secret\n".utf8)))

        var bytes = Self.outputBytes(attachment.replay)
        for await event in stream {
            if case .output(_, let chunk) = event { bytes.append(contentsOf: chunk) }
        }
        #expect(String(decoding: bytes, as: UTF8.self).contains("got:secret"))
        await service.shutdown()
    }

    @Test("Output retention is bounded and reports truncation")
    func retainedRingIsBounded() async throws {
        let service = PTYService(maximumRetainedBytes: 128)
        let id = try await service.start(.init(
            command: ["/bin/sh", "-c", "yes x | head -c 4096"],
            workingDirectory: "/tmp"
        ))

        for _ in 0..<200 {
            if await service.snapshot(sessionID: id)?.state != .running { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = try #require(await service.snapshot(sessionID: id))
        #expect(snapshot.retainedByteCount <= 128)
        #expect(snapshot.retainedOutputTruncated)
        await service.shutdown()
    }

    @Test("An empty-base child receives only its explicit environment")
    func environmentCanBePinned() async throws {
        let service = PTYService()
        let id = try await service.start(.init(
            command: ["/bin/sh", "-c", "printf '%s:%s' \"$PTY_TEST\" \"$PATH\""],
            workingDirectory: "/tmp",
            environment: PTYEnvironment(
                base: .empty,
                overrides: ["PTY_TEST": "present", "PATH": "/bin"]
            )
        ))
        try await Task.sleep(for: .milliseconds(30))
        let attachment = try await service.beginAttach(sessionID: id)
        let rendered = String(decoding: Self.outputBytes(attachment.replay), as: UTF8.self)
        #expect(rendered == "present:/bin")
        await service.shutdown()
    }

    @Test("Unactivated attachments can be cancelled and are bounded")
    func pendingAttachmentsAreBounded() async throws {
        let service = PTYService(maximumPendingAttachments: 1)
        let id = try await service.start(.init(
            command: ["/bin/sh", "-c", "sleep 0.2"],
            workingDirectory: "/tmp"
        ))
        let first = try await service.beginAttach(sessionID: id)
        await #expect(throws: PTYError.tooManyAttachments) {
            _ = try await service.beginAttach(sessionID: id)
        }
        #expect(await service.cancelAttach(sessionID: id, attachmentID: first.id))
        _ = try await service.beginAttach(sessionID: id)
        await service.shutdown()
    }

    private static func outputBytes(_ events: [PTYEvent]) -> [UInt8] {
        events.reduce(into: [UInt8]()) { result, event in
            if case .output(_, let bytes) = event { result.append(contentsOf: bytes) }
        }
    }
}
