// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoHarness
import Foundation
import Synchronization
import SystemPackage
import Testing

private actor JobAttemptCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

private actor JobStartedSignal {
    private var started = false

    func mark() { started = true }

    func value() -> Bool { started }
}

@Suite("Durable job manager", .serialized)
struct JobManagerTests {
    @Test("persists progress, retries within the total-attempt budget, and resumes event cursors")
    func retriesProgressAndCursor() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try JobStore.create(directory: directory)
        let notifications = Mutex<[JobEvent]>([])
        let attempts = JobAttemptCounter()
        let manager = JobManager(
            store: store,
            now: { "2026-01-01T00:00:00Z" },
            sleep: { _ in },
            notify: { event in
                notifications.withLock { $0.append(event) }
            }
        )

        _ = try await manager.admit(JobAdmission(
            id: "job-retry",
            correlationID: "corr-1",
            sessionID: "session-1",
            taskID: "task-1",
            kind: "workflow-stage",
            owner: "client-a",
            retryPolicy: JobRetryPolicy(
                maxAttempts: 2,
                initialBackoffMilliseconds: 1,
                maximumBackoffMilliseconds: 1
            ),
            triggerSource: .scheduled
        ))

        let result = try await manager.run(jobID: "job-retry", owner: "client-a") { context in
            let attempt = await attempts.increment()
            try await context.reportProgress(JobProgress(fraction: 0.5), "Halfway")
            if attempt == 1 {
                throw JobOperationFailure(message: "temporary provider overload", retryable: true)
            }
            return JobResult(output: "complete", metadata: ["attempts": .int(attempt)])
        }

        #expect(result.state == .succeeded)
        #expect(result.attempt == 2)
        #expect(result.progress.fraction == 1)
        #expect(result.output == .string("complete"))
        #expect(result.metadata["attempts"] == .int(2))
        #expect(result.triggerSource == .scheduled)

        let allEvents = try await manager.events()
        #expect(allEvents.map(\.kind) == [
            .admitted, .started, .progress, .retryScheduled,
            .started, .progress, .succeeded,
        ])
        #expect(allEvents.allSatisfy { $0.triggerSource == .scheduled })
        let resumed = try await manager.events(after: 3)
        #expect(resumed.map(\.sequence) == [4, 5, 6, 7])
        #expect(notifications.withLock { $0 } == allEvents)

        let reopened = JobManager(store: store, now: { "2026-01-01T00:00:01Z" })
        let reopenedRecord = try await reopened.snapshot(jobID: "job-retry")
        let reopenedEvents = try await reopened.events(after: 5)
        #expect(reopenedRecord == result)
        #expect(reopenedEvents.map(\.kind) == [.progress, .succeeded])
    }

    @Test("cancellation is cooperative for running work and immediate for queued work")
    func cancellation() async throws {
        let manager = JobManager(now: { "2026-01-01T00:00:00Z" }, sleep: { _ in })
        _ = try await manager.admit(JobAdmission(
            id: "job-cancel",
            correlationID: "corr-cancel",
            kind: "background",
            owner: "client-a"
        ))
        let signal = JobStartedSignal()
        let run = Task {
            try await manager.run(jobID: "job-cancel", owner: "client-a") { context in
                await signal.mark()
                while !(await context.isCancellationRequested()) {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                throw JobOperationFailure(
                    message: "operation observed cancellation",
                    cancelled: true
                )
            }
        }

        for _ in 0..<100 {
            if await signal.value() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await signal.value())
        _ = try await manager.cancel(jobID: "job-cancel", owner: "client-a")
        let result = try await run.value
        #expect(result.state == .cancelled)
        let events = try await manager.events()
        #expect(events.last?.kind == .cancelled)

        _ = try await manager.admit(JobAdmission(
            id: "job-queued-cancel",
            correlationID: "corr-queued-cancel",
            kind: "background",
            owner: "client-a"
        ))
        let queued = try await manager.cancel(jobID: "job-queued-cancel", owner: "client-a")
        #expect(queued.state == .cancelled)
    }

    @Test("ownership is enforced and restart recovery never lies about running work")
    func ownershipAndRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let store = try JobStore.create(directory: directory)
        let admission = JobAdmission(
            id: "job-recover",
            correlationID: "corr-recover",
            sessionID: "session-recover",
            taskID: "task-recover",
            kind: "agent",
            owner: "client-a"
        )
        var interrupted = JobRecord(admission: admission, createdAt: "2026-01-01T00:00:00Z")
        interrupted.state = .running
        interrupted.attempt = 1
        interrupted.startedAt = "2026-01-01T00:00:01Z"
        interrupted.updatedAt = interrupted.startedAt ?? ""
        let event = JobEvent(
            sequence: 1,
            jobID: interrupted.id,
            correlationID: interrupted.correlationID,
            timestamp: interrupted.updatedAt,
            kind: .started,
            state: .running,
            attempt: 1,
            progress: interrupted.progress
        )
        try store.append(JobJournalEntry(event: event, record: interrupted))

        let manager = JobManager(store: store, now: { "2026-01-01T00:00:02Z" })
        await #expect(throws: JobManagerError.ownershipDenied("job-recover")) {
            _ = try await manager.cancel(jobID: "job-recover", owner: "client-b")
        }
        let recovered = try await manager.recoverInterruptedJobs()
        #expect(recovered.count == 1)
        #expect(recovered[0].state == .paused)
        #expect(recovered[0].error == "Job interrupted before the manager restarted.")
        let recoveryEvents = try await manager.events(after: 1)
        #expect(recoveryEvents.map(\.kind) == [.recovered])
    }

    private func temporaryDirectory() -> FilePath {
        FilePath(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("domocode-jobs-\(UUID().uuidString)", isDirectory: true)
                .path
        )
    }
}
