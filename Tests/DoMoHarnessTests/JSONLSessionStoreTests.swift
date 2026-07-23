import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Synchronization
import SystemPackage
import Testing

/// Collects skipped-line reports across the `@Sendable` `onSkippedLine` callback.
private final class SkipCollector: Sendable {
    private let storage = Mutex<[JSONLinesError]>([])
    func record(_ error: JSONLinesError) { storage.withLock { $0.append(error) } }
    var all: [JSONLinesError] { storage.withLock { $0 } }
    var count: Int { storage.withLock { $0.count } }
}

@Suite("JSONLSessionStore")
struct JSONLSessionStoreTests {
    /// A unique, throwaway session directory. Every test writes under the system
    /// temp directory and never under the real `~/.domocode`.
    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-session-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func fixedClock(_ date: Date) -> @Sendable () -> Date {
        { date }
    }

    /// Appends a payload as a child of `parent`, minting an id, and returns the id.
    @discardableResult
    private func append(
        _ store: JSONLSessionStore,
        _ payload: SessionTreeEntry.Payload,
        parent: String?
    ) throws -> String {
        let id = store.createEntryID()
        let entry = SessionTreeEntry(
            id: id,
            parentId: parent,
            timestamp: "2026-07-23T12:00:00.000Z",
            payload: payload
        )
        try store.appendEntry(entry)
        return id
    }

    // MARK: - Header

    @Test("create writes a parseable header and readHeader returns it")
    func createWritesHeader() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(
            cwd: "/Users/dev/project",
            sessionDirectory: dir,
            now: fixedClock(fixedDate)
        )
        let header = try store.readHeader()
        #expect(header.type == "session")
        #expect(header.cwd == "/Users/dev/project")
        #expect(header.version == SessionHeader.currentVersion)
        #expect(header.parentSession == nil)
        // The injected clock, not the wall clock, is what the header records.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(formatter.date(from: header.timestamp) == fixedDate)
    }

    @Test("the session file lives under a sanitized-cwd directory")
    func fileLocationIsSanitized() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(
            cwd: "/Users/dev/project",
            sessionDirectory: dir,
            now: fixedClock(fixedDate)
        )
        #expect(store.path.string.contains("--Users-dev-project--"))
        #expect(store.path.string.hasSuffix(".jsonl"))
    }

    @Test("a forked session header carries its parentSession path")
    func forkedHeader() throws {
        let dir = makeSessionDirectory()
        let parentPath = "/tmp/orig.jsonl"
        let store = try JSONLSessionStore.create(
            cwd: "/Users/dev/project",
            sessionDirectory: dir,
            parentSession: parentPath,
            now: fixedClock(fixedDate)
        )
        #expect(try store.readHeader().parentSession == parentPath)
    }

    @Test("readHeader on a file whose first line is not a header throws")
    func headerRequired() throws {
        let dir = makeSessionDirectory()
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let filePath = dir.appending("bogus.jsonl")
        try Data("not a header at all\n".utf8).write(to: URL(fileURLWithPath: filePath.string))
        let store = JSONLSessionStore(path: filePath)
        #expect(throws: (any Error).self) { _ = try store.readHeader() }
        #expect(throws: (any Error).self) { _ = try JSONLSessionStore.open(path: filePath) }
    }

    @Test("open validates the header eagerly")
    func openValidates() throws {
        let dir = makeSessionDirectory()
        let created = try JSONLSessionStore.create(
            cwd: "/w",
            sessionDirectory: dir,
            now: fixedClock(fixedDate)
        )
        let reopened = try JSONLSessionStore.open(path: created.path)
        #expect(try reopened.readHeader().cwd == "/w")
    }

    // MARK: - Round-trip every entry type

    @Test("every entry type round-trips through the JSONL file in order")
    func everyEntryTypeRoundTrips() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))

        let assistant = AssistantMessage(
            content: [.text("hi"), .toolCall(ToolCallBlock(id: "c1", name: "bash", arguments: .object(["x": .int(1)])))],
            model: "claude-sonnet-4-5",
            usage: Usage(input: 10, output: 2),
            stopReason: .toolUse
        )
        let payloads: [SessionTreeEntry.Payload] = [
            .message(.user("hello")),
            .message(.assistant(assistant)),
            .message(.tool(ToolResultBlock(toolCallID: "c1", toolName: "bash", output: "ok"))),
            .modelChange(provider: "openai", modelId: "gpt-4o"),
            .compaction(Compaction(summary: "s", tokensBefore: 100, retainedTail: [.user("kept")])),
            .branchSummary(BranchSummary(fromId: "x", summary: "b")),
            .label(targetId: "x", label: "mark"),
            .sessionInfo(name: "My session"),
            .leaf(targetId: nil),
        ]

        var built: [SessionTreeEntry] = []
        var parent: String? = nil
        for payload in payloads {
            let id = store.createEntryID()
            let entry = SessionTreeEntry(id: id, parentId: parent, timestamp: "2026-07-23T12:00:00.000Z", payload: payload)
            try store.appendEntry(entry)
            built.append(entry)
            parent = id
        }

        let read = try store.readEntries()
        #expect(read == built)
    }

    // MARK: - Crash safety

    @Test("a crash-truncated final line still reads every prior entry")
    func truncatedFinalLine() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        let id1 = try append(store, .message(.user("first")), parent: nil)
        let id2 = try append(store, .message(.user("second")), parent: id1)

        // Simulate a process killed after writing a partial final entry: append
        // a JSON fragment with no closing brace and no trailing newline directly
        // to the file, the way an interrupted O_APPEND write would leave it.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: store.path.string))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"message","id":"m3","parentId":"#.utf8))
        try handle.close()

        let skipped = SkipCollector()
        let read = try store.readEntries { skipped.record($0) }
        #expect(read.map(\.id) == [id1, id2])
        #expect(skipped.count == 1)
    }

    @Test("a malformed middle line is skipped and reported under tolerant read")
    func malformedMiddleLine() throws {
        let dir = makeSessionDirectory()
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let filePath = dir.appending("hand.jsonl")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = SessionHeader(id: "sess-1", timestamp: "2026-07-23T12:00:00.000Z", cwd: "/w")
        let good1 = SessionTreeEntry(id: "g1", parentId: nil, timestamp: "t", payload: .message(.user("one")))
        let good2 = SessionTreeEntry(id: "g2", parentId: "g1", timestamp: "t", payload: .message(.user("two")))

        var bytes = Data()
        bytes.append(try encoder.encode(header)); bytes.append(0x0A)
        bytes.append(try encoder.encode(good1)); bytes.append(0x0A)
        bytes.append(Data(#"{"type":"message","id":"broken""#.utf8)); bytes.append(0x0A)
        bytes.append(try encoder.encode(good2)); bytes.append(0x0A)
        try bytes.write(to: URL(fileURLWithPath: filePath.string))

        let store = JSONLSessionStore(path: filePath)
        let skipped = SkipCollector()
        let read = try store.readEntries { skipped.record($0) }
        #expect(read.map(\.id) == ["g1", "g2"])
        #expect(skipped.count == 1)
        #expect(skipped.all.first?.kind == .malformedLine)
    }

    // MARK: - Leaf and path resolution

    @Test("leafID is the last entry's tip and follows leaf entries")
    func leafIDTracksTip() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        #expect(try store.leafID() == nil)
        let id1 = try append(store, .message(.user("a")), parent: nil)
        #expect(try store.leafID() == id1)
        let id2 = try append(store, .message(.user("b")), parent: id1)
        #expect(try store.leafID() == id2)
        // A leaf entry moves the tip back to an earlier entry.
        try append(store, .leaf(targetId: id1), parent: id2)
        #expect(try store.leafID() == id1)
    }

    @Test("pathToRootOrCompaction walks leaf to root")
    func pathToRoot() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        let id1 = try append(store, .message(.user("a")), parent: nil)
        let id2 = try append(store, .message(.user("b")), parent: id1)
        let id3 = try append(store, .message(.user("c")), parent: id2)
        let path = try store.pathToRootOrCompaction(from: id3)
        #expect(path.map(\.id) == [id1, id2, id3])
    }

    @Test("pathToRootOrCompaction stops at a compaction checkpoint")
    func pathStopsAtCompaction() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        let id1 = try append(store, .message(.user("a")), parent: nil)
        let id2 = try append(store, .message(.user("b")), parent: id1)
        let cp = try append(
            store,
            .compaction(Compaction(summary: "s", tokensBefore: 1, retainedTail: [.user("kept")])),
            parent: id2
        )
        let id4 = try append(store, .message(.user("d")), parent: cp)
        let path = try store.pathToRootOrCompaction(from: id4)
        #expect(path.map(\.id) == [cp, id4])
    }

    @Test("pathToRootOrCompaction throws on a missing leaf")
    func pathThrowsOnMissingLeaf() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        try append(store, .message(.user("a")), parent: nil)
        #expect(throws: (any Error).self) {
            _ = try store.pathToRootOrCompaction(from: "does-not-exist")
        }
    }

    @Test("pathToRootOrCompaction throws when a parent link dangles")
    func pathThrowsOnDanglingParent() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        // A child whose parent was never written: the tolerant read keeps the
        // child, but the path resolver cannot span the gap and must throw.
        let orphan = try append(store, .message(.user("orphan")), parent: "ghost-parent")
        #expect(throws: (any Error).self) {
            _ = try store.pathToRootOrCompaction(from: orphan)
        }
    }

    // MARK: - Ordering and lookup

    @Test("minted entry ids sort in creation order")
    func idsSortInCreationOrder() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        var ids: [String] = []
        var parent: String? = nil
        for _ in 0..<50 {
            let id = try append(store, .message(.user("x")), parent: parent)
            ids.append(id)
            parent = id
        }
        #expect(ids == ids.sorted())
    }

    @Test("entry(withID:) finds a present entry and returns nil for an absent one")
    func entryLookup() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        let id1 = try append(store, .sessionInfo(name: "n"), parent: nil)
        #expect(try store.entry(withID: id1)?.id == id1)
        #expect(try store.entry(withID: "missing") == nil)
    }

    // MARK: - Listing

    @Test("list returns the sessions for a cwd, ordered by timestamp")
    func listOrders() throws {
        let dir = makeSessionDirectory()
        let cwd = "/Users/dev/project"
        let older = try JSONLSessionStore.create(
            cwd: cwd,
            sessionDirectory: dir,
            sessionID: "sess-older",
            now: fixedClock(Date(timeIntervalSince1970: 1_000))
        )
        let newer = try JSONLSessionStore.create(
            cwd: cwd,
            sessionDirectory: dir,
            sessionID: "sess-newer",
            now: fixedClock(Date(timeIntervalSince1970: 2_000))
        )
        let listings = try JSONLSessionStore.list(cwd: cwd, sessionDirectory: dir)
        #expect(listings.count == 2)
        #expect(listings.map(\.header.id) == ["sess-older", "sess-newer"])
        #expect(Set(listings.map(\.path)) == [older.path, newer.path])
    }

    @Test("list of an unknown cwd is empty, not an error")
    func listEmpty() throws {
        let dir = makeSessionDirectory()
        #expect(try JSONLSessionStore.list(cwd: "/nowhere", sessionDirectory: dir).isEmpty)
    }
}
