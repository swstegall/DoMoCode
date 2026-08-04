// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Foundation
import SystemPackage

// MARK: - Records

/// The lifecycle of a durable job.
public enum JobState: String, Codable, Sendable, Hashable, CaseIterable {
    case queued
    case running
    case retrying
    case paused
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        case .queued, .running, .retrying, .paused: false
        }
    }
}

/// Progress is deliberately bounded so every client can render it as a
/// determinate bar without trusting a producer to normalize its value.
public struct JobProgress: Codable, Sendable, Hashable {
    public let fraction: Double
    public let message: String?

    public init(fraction: Double = 0, message: String? = nil) {
        self.fraction = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        self.message = message
    }
}

/// Retry settings use total attempts rather than retries-after-the-first.
/// Keeping that meaning in the record prevents a recovered client from
/// accidentally exceeding the configured provider or workspace budget.
public struct JobRetryPolicy: Codable, Sendable, Hashable {
    public let maxAttempts: Int
    public let initialBackoffMilliseconds: Int
    public let maximumBackoffMilliseconds: Int

    public init(
        maxAttempts: Int = 1,
        initialBackoffMilliseconds: Int = 250,
        maximumBackoffMilliseconds: Int = 30_000
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialBackoffMilliseconds = max(0, initialBackoffMilliseconds)
        self.maximumBackoffMilliseconds = max(
            self.initialBackoffMilliseconds,
            maximumBackoffMilliseconds
        )
    }

    public func delay(afterAttempt attempt: Int) -> Duration {
        guard initialBackoffMilliseconds > 0 else { return .zero }
        let exponent = max(0, attempt - 1)
        let scale = Int64(1) << Int64(min(exponent, 30))
        let scaled = Int64(initialBackoffMilliseconds).multipliedReportingOverflow(by: scale)
        let value = scaled.overflow ? Int64.max : scaled.partialValue
        let multiplier = Swift.min(Int64(maximumBackoffMilliseconds), value)
        return .milliseconds(multiplier)
    }
}

/// A job's durable identity and ownership boundary.
public struct JobAdmission: Codable, Sendable, Hashable {
    public let id: String
    public let correlationID: String
    public let sessionID: String?
    public let taskID: String?
    public let parentJobID: String?
    public let kind: String
    public let owner: String
    public let retryPolicy: JobRetryPolicy
    public let metadata: [String: JSONValue]

    public init(
        id: String = UUIDv7.generate().description,
        correlationID: String = UUIDv7.generate().description,
        sessionID: String? = nil,
        taskID: String? = nil,
        parentJobID: String? = nil,
        kind: String,
        owner: String,
        retryPolicy: JobRetryPolicy = .init(),
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.correlationID = correlationID
        self.sessionID = sessionID
        self.taskID = taskID
        self.parentJobID = parentJobID
        self.kind = kind
        self.owner = owner
        self.retryPolicy = retryPolicy
        self.metadata = metadata
    }
}

/// The latest durable state of one job.
public struct JobRecord: Codable, Sendable, Hashable {
    public let id: String
    public let correlationID: String
    public let sessionID: String?
    public let taskID: String?
    public let parentJobID: String?
    public let kind: String
    public let owner: String
    public let retryPolicy: JobRetryPolicy
    public var state: JobState
    public var progress: JobProgress
    public var attempt: Int
    public let createdAt: String
    public var updatedAt: String
    public var startedAt: String?
    public var finishedAt: String?
    public var error: String?
    public var output: JSONValue?
    public var metadata: [String: JSONValue]

    public init(
        admission: JobAdmission,
        createdAt: String,
        state: JobState = .queued,
        progress: JobProgress = .init(),
        attempt: Int = 0,
        updatedAt: String? = nil,
        startedAt: String? = nil,
        finishedAt: String? = nil,
        error: String? = nil,
        output: JSONValue? = nil
    ) {
        self.id = admission.id
        self.correlationID = admission.correlationID
        self.sessionID = admission.sessionID
        self.taskID = admission.taskID
        self.parentJobID = admission.parentJobID
        self.kind = admission.kind
        self.owner = admission.owner
        self.retryPolicy = admission.retryPolicy
        self.state = state
        self.progress = progress
        self.attempt = max(0, attempt)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.output = output
        self.metadata = admission.metadata
    }
}

/// A completed operation's value. Jobs can carry structured output without
/// making the manager know whether the producer was a child agent, a workflow,
/// or a future automation trigger.
public struct JobResult: Sendable, Hashable {
    public let output: JSONValue?
    public let metadata: [String: JSONValue]

    public init(output: JSONValue? = nil, metadata: [String: JSONValue] = [:]) {
        self.output = output
        self.metadata = metadata
    }
}

/// An operation failure can explicitly opt into retry or cancellation without
/// forcing every producer to depend on the provider error taxonomy.
public struct JobOperationFailure: Error, Sendable, Hashable {
    public let message: String
    public let retryable: Bool
    public let cancelled: Bool

    public init(message: String, retryable: Bool = false, cancelled: Bool = false) {
        self.message = message
        self.retryable = retryable
        self.cancelled = cancelled
    }
}

// MARK: - Events and persistence

public enum JobEventKind: String, Codable, Sendable, Hashable {
    case admitted
    case started
    case progress
    case retryScheduled
    case succeeded
    case failed
    case cancelled
    case recovered
}

/// An append-only event. `sequence` is the resumable cursor shared by all jobs
/// in one store; a client can reconnect with its last value and receive only
/// events it has not seen.
public struct JobEvent: Codable, Sendable, Hashable {
    public let sequence: Int
    public let jobID: String
    public let correlationID: String
    public let timestamp: String
    public let kind: JobEventKind
    public let state: JobState
    public let attempt: Int
    public let progress: JobProgress
    public let message: String?
    public let metadata: [String: JSONValue]

    public init(
        sequence: Int,
        jobID: String,
        correlationID: String,
        timestamp: String,
        kind: JobEventKind,
        state: JobState,
        attempt: Int,
        progress: JobProgress,
        message: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.sequence = sequence
        self.jobID = jobID
        self.correlationID = correlationID
        self.timestamp = timestamp
        self.kind = kind
        self.state = state
        self.attempt = attempt
        self.progress = progress
        self.message = message
        self.metadata = metadata
    }
}

/// One journal row combines the event and the complete state after that event.
/// A restart can therefore rebuild the index without replaying operation code.
public struct JobJournalEntry: Codable, Sendable, Hashable {
    public let event: JobEvent
    public let record: JobRecord

    public init(event: JobEvent, record: JobRecord) {
        self.event = event
        self.record = record
    }
}

/// Append-only durable storage for job snapshots and their event cursor.
public struct JobStore: Sendable {
    public let path: FilePath
    public let permissions: FilePermissions

    public init(path: FilePath, permissions: FilePermissions = .ownerReadWrite) {
        self.path = path
        self.permissions = permissions
    }

    public static func create(
        directory: FilePath,
        fileName: String = "jobs.jsonl",
        permissions: FilePermissions = .ownerReadWrite
    ) throws -> JobStore {
        try FileManager.default.createDirectory(
            atPath: directory.string,
            withIntermediateDirectories: true
        )
        let store = JobStore(path: directory.appending(fileName), permissions: permissions)
        if !FileManager.default.fileExists(atPath: store.path.string) {
            try JSONLinesFileWriter(path: store.path, permissions: permissions)
                .replaceContents(with: [JobJournalEntry]())
        }
        return store
    }

    public func append(_ entry: JobJournalEntry) throws {
        try JSONLinesFileWriter(path: path, permissions: permissions).append(entry)
    }

    public func records() throws -> [JobJournalEntry] {
        guard FileManager.default.fileExists(atPath: path.string) else { return [] }
        return try JSONLines.decode(JobJournalEntry.self, contentsOf: path, options: .strict)
    }

    public func latestJobs() throws -> [String: JobRecord] {
        var result: [String: JobRecord] = [:]
        for entry in try records() {
            result[entry.record.id] = entry.record
        }
        return result
    }

    public func events(after sequence: Int = 0, jobID: String? = nil) throws -> [JobEvent] {
        try records()
            .map(\.event)
            .filter { $0.sequence > sequence && (jobID == nil || $0.jobID == jobID) }
            .sorted { $0.sequence < $1.sequence }
    }

    public func export(jobID: String) throws -> [JobJournalEntry] {
        try records().filter { $0.record.id == jobID }
    }
}

// MARK: - Manager

public enum JobManagerError: Error, Sendable, Equatable {
    case invalidAdmission(String)
    case duplicateJob(String)
    case notFound(String)
    case ownershipDenied(String)
    case invalidTransition(id: String, state: JobState)
    case jobBusy(String)
}

public typealias JobNotification = @Sendable (JobEvent) -> Void

public struct JobExecutionContext: Sendable {
    public let record: JobRecord
    public let reportProgress: @Sendable (JobProgress, String?) async throws -> Void
    public let isCancellationRequested: @Sendable () async -> Bool

    public init(
        record: JobRecord,
        reportProgress: @escaping @Sendable (JobProgress, String?) async throws -> Void,
        isCancellationRequested: @escaping @Sendable () async -> Bool
    ) {
        self.record = record
        self.reportProgress = reportProgress
        self.isCancellationRequested = isCancellationRequested
    }
}

public typealias JobOperation = @Sendable (JobExecutionContext) async throws -> JobResult

/// A durable manager for background work. It owns lifecycle transitions and
/// persistence, while the operation closure owns the actual agent/workflow
/// execution and can report progress through its context.
public actor JobManager {
    private let store: JobStore?
    private let now: @Sendable () -> String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let notify: JobNotification?

    private var loaded = false
    private var nextSequence = 0
    private var jobs: [String: JobRecord] = [:]
    private var eventLog: [JobEvent] = []
    private var activeJobs: Set<String> = []
    private var cancellationRequested: Set<String> = []

    public init(
        store: JobStore? = nil,
        now: @escaping @Sendable () -> String = { WorkflowStore.timestamp() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        notify: JobNotification? = nil
    ) {
        self.store = store
        self.now = now
        self.sleep = sleep
        self.notify = notify
    }

    /// Reclassifies work that was running when the process disappeared. It is
    /// unsafe to resurrect a provider subprocess or assume an old lease is
    /// still valid, so recovery is explicit and resumable rather than falsely
    /// reporting a live run.
    public func recoverInterruptedJobs() throws -> [JobRecord] {
        try loadIfNeeded()
        var recovered: [JobRecord] = []
        for id in jobs.keys.sorted() {
            guard var record = jobs[id], record.state == .running || record.state == .retrying else {
                continue
            }
            record.state = .paused
            record.error = "Job interrupted before the manager restarted."
            record.updatedAt = now()
            let event = try append(
                record: record,
                kind: .recovered,
                message: record.error
            )
            _ = event
            recovered.append(record)
        }
        return recovered
    }

    public func admit(_ admission: JobAdmission) throws -> JobRecord {
        try loadIfNeeded()
        try validate(admission)
        guard jobs[admission.id] == nil else {
            throw JobManagerError.duplicateJob(admission.id)
        }
        let record = JobRecord(admission: admission, createdAt: now())
        _ = try append(record: record, kind: .admitted)
        return record
    }

    public func snapshot(jobID: String) throws -> JobRecord? {
        try loadIfNeeded()
        return jobs[jobID]
    }

    public func list(owner: String? = nil) throws -> [JobRecord] {
        try loadIfNeeded()
        return jobs.values
            .filter { owner == nil || $0.owner == owner }
            .sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt < rhs.updatedAt
            }
    }

    public func events(after sequence: Int = 0, jobID: String? = nil) throws -> [JobEvent] {
        try loadIfNeeded()
        return eventLog.filter {
            $0.sequence > sequence && (jobID == nil || $0.jobID == jobID)
        }
    }

    /// Export the complete journal history for one job without exposing the
    /// manager's backing store or allowing a caller to mutate it.
    public func export(jobID: String) throws -> [JobJournalEntry] {
        try loadIfNeeded()
        guard jobs[jobID] != nil else { throw JobManagerError.notFound(jobID) }
        if let store { return try store.export(jobID: jobID) }
        return eventLog.compactMap { event in
            guard event.jobID == jobID, let record = jobs[jobID] else { return nil }
            return JobJournalEntry(event: event, record: record)
        }
    }

    public func updateProgress(
        jobID: String,
        owner: String,
        progress: JobProgress,
        message: String? = nil
    ) throws -> JobRecord {
        try loadIfNeeded()
        guard var record = jobs[jobID] else { throw JobManagerError.notFound(jobID) }
        try authorize(record, owner: owner)
        guard record.state == .running else {
            throw JobManagerError.invalidTransition(id: jobID, state: record.state)
        }
        record.progress = progress
        record.updatedAt = now()
        _ = try append(record: record, kind: .progress, message: message)
        return record
    }

    /// Cancels queued work immediately. Running work is cancelled
    /// cooperatively: the operation receives the request through its context,
    /// and the manager persists the terminal state when that operation returns.
    public func cancel(jobID: String, owner: String) throws -> JobRecord {
        try loadIfNeeded()
        guard var record = jobs[jobID] else { throw JobManagerError.notFound(jobID) }
        try authorize(record, owner: owner)
        guard !record.state.isTerminal else { return record }
        if record.state == .running {
            cancellationRequested.insert(jobID)
            return record
        }
        record.state = .cancelled
        record.error = "Job cancellation requested."
        record.finishedAt = now()
        record.updatedAt = record.finishedAt ?? now()
        _ = try append(record: record, kind: .cancelled, message: record.error)
        return record
    }

    /// Runs one admitted job. The method returns a terminal record for
    /// operation failures; only manager/storage errors are thrown. That keeps
    /// callers from losing the durable failure state by handling an exception
    /// before the journal write completes.
    public func run(
        jobID: String,
        owner: String,
        operation: @escaping JobOperation
    ) async throws -> JobRecord {
        try loadIfNeeded()
        guard var record = jobs[jobID] else { throw JobManagerError.notFound(jobID) }
        try authorize(record, owner: owner)
        guard !activeJobs.contains(jobID) else { throw JobManagerError.jobBusy(jobID) }
        guard record.state == .queued || record.state == .paused || record.state == .retrying else {
            if record.state.isTerminal { return record }
            throw JobManagerError.invalidTransition(id: jobID, state: record.state)
        }

        activeJobs.insert(jobID)
        defer {
            activeJobs.remove(jobID)
            cancellationRequested.remove(jobID)
        }

        while true {
            if Task.isCancelled || cancellationRequested.contains(jobID) {
                record.state = .cancelled
                record.error = "Job cancellation requested."
                record.finishedAt = now()
                record.updatedAt = record.finishedAt ?? now()
                _ = try append(record: record, kind: .cancelled, message: record.error)
                return record
            }

            record.state = .running
            record.attempt += 1
            record.startedAt = record.startedAt ?? now()
            record.updatedAt = now()
            record.error = nil
            _ = try append(record: record, kind: .started)

            let contextRecord = record
            let context = JobExecutionContext(
                record: contextRecord,
                reportProgress: { [weak self] progress, message in
                    guard let self else { return }
                    _ = try await self.updateProgress(
                        jobID: contextRecord.id,
                        owner: contextRecord.owner,
                        progress: progress,
                        message: message
                    )
                },
                isCancellationRequested: { [weak self] in
                    guard let self else { return true }
                    return await self.isCancellationRequested(jobID: contextRecord.id)
                }
            )

            do {
                let result = try await operation(context)
                if Task.isCancelled || cancellationRequested.contains(jobID) {
                    record.state = .cancelled
                    record.error = "Job cancellation requested."
                    record.finishedAt = now()
                    record.updatedAt = record.finishedAt ?? now()
                    _ = try append(record: record, kind: .cancelled, message: record.error)
                    return record
                }
                record.state = .succeeded
                record.progress = JobProgress(fraction: 1, message: "Complete")
                record.output = result.output
                record.metadata.merge(result.metadata) { _, latest in latest }
                record.error = nil
                record.finishedAt = now()
                record.updatedAt = record.finishedAt ?? now()
                _ = try append(record: record, kind: .succeeded, message: "Job completed.")
                return record
            } catch {
                let failure = classify(error)
                let message = Redaction.diagnostic(failure.message)
                if failure.cancelled || Task.isCancelled || cancellationRequested.contains(jobID) {
                    record.state = .cancelled
                    record.error = message
                    record.finishedAt = now()
                    record.updatedAt = record.finishedAt ?? now()
                    _ = try append(record: record, kind: .cancelled, message: message)
                    return record
                }
                if failure.retryable && record.attempt < record.retryPolicy.maxAttempts {
                    record.state = .retrying
                    record.error = message
                    record.updatedAt = now()
                    _ = try append(
                        record: record,
                        kind: .retryScheduled,
                        message: message,
                        metadata: [
                            "nextAttempt": .int(record.attempt + 1),
                            "backoffMilliseconds": .int(
                                Int(record.retryPolicy.delay(afterAttempt: record.attempt).milliseconds)
                            ),
                        ]
                    )
                    do {
                        try await sleep(record.retryPolicy.delay(afterAttempt: record.attempt))
                    } catch {
                        record.state = .cancelled
                        record.error = "Job retry wait was cancelled."
                        record.finishedAt = now()
                        record.updatedAt = record.finishedAt ?? now()
                        _ = try append(record: record, kind: .cancelled, message: record.error)
                        return record
                    }
                    continue
                }
                record.state = .failed
                record.error = message
                record.finishedAt = now()
                record.updatedAt = record.finishedAt ?? now()
                _ = try append(record: record, kind: .failed, message: message)
                return record
            }
        }
    }

    private func isCancellationRequested(jobID: String) -> Bool {
        cancellationRequested.contains(jobID)
    }

    private func validate(_ admission: JobAdmission) throws {
        let fields: [(String, String)] = [
            ("id", admission.id),
            ("correlationID", admission.correlationID),
            ("kind", admission.kind),
            ("owner", admission.owner),
        ]
        for (name, value) in fields where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JobManagerError.invalidAdmission("Job \(name) must not be empty.")
        }
        if admission.retryPolicy.maxAttempts < 1 {
            throw JobManagerError.invalidAdmission("Job maxAttempts must be at least one.")
        }
    }

    private func authorize(_ record: JobRecord, owner: String) throws {
        guard owner == record.owner else {
            throw JobManagerError.ownershipDenied(record.id)
        }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        if let store {
            let rows = try store.records()
            for row in rows {
                guard row.event.sequence > nextSequence else {
                    throw JobManagerError.invalidAdmission(
                        "Job journal cursor is not strictly increasing at \(row.event.sequence)."
                    )
                }
                nextSequence = row.event.sequence
                jobs[row.record.id] = row.record
                eventLog.append(row.event)
            }
        }
        loaded = true
    }

    @discardableResult
    private func append(
        record: JobRecord,
        kind: JobEventKind,
        message: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) throws -> JobEvent {
        nextSequence += 1
        let event = JobEvent(
            sequence: nextSequence,
            jobID: record.id,
            correlationID: record.correlationID,
            timestamp: record.updatedAt,
            kind: kind,
            state: record.state,
            attempt: record.attempt,
            progress: record.progress,
            message: message,
            metadata: metadata
        )
        if let store {
            do {
                try store.append(JobJournalEntry(event: event, record: record))
            } catch {
                nextSequence -= 1
                throw error
            }
        }
        jobs[record.id] = record
        eventLog.append(event)
        notify?(event)
        return event
    }

    private struct ClassifiedFailure: Sendable {
        let message: String
        let retryable: Bool
        let cancelled: Bool
    }

    private func classify(_ error: any Error) -> ClassifiedFailure {
        if let failure = error as? JobOperationFailure {
            return ClassifiedFailure(
                message: failure.message,
                retryable: failure.retryable,
                cancelled: failure.cancelled
            )
        }
        if let error = error as? DoMoError {
            return ClassifiedFailure(
                message: error.description,
                retryable: error.isRetryable,
                cancelled: error.isCancellation
            )
        }
        if error is CancellationError {
            return ClassifiedFailure(message: "Job operation was cancelled.", retryable: false, cancelled: true)
        }
        return ClassifiedFailure(message: String(describing: error), retryable: false, cancelled: false)
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        let fractional = Int64(components.attoseconds / 1_000_000_000_000_000)
        if seconds.overflow { return Int64.max }
        return seconds.partialValue + fractional
    }
}
