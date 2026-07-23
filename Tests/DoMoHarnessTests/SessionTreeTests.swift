import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import SystemPackage
import Testing

@Suite("SessionTree")
struct SessionTreeTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func fixedClock(_ date: Date) -> @Sendable () -> Date { { date } }

    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-tree-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private func ts(_ n: Int) -> String {
        let seconds = n < 10 ? "0\(n)" : "\(n)"
        return "2026-07-23T12:00:\(seconds).000Z"
    }

    private func messageEntry(_ id: String, parent: String?, _ n: Int, _ text: String) -> SessionTreeEntry {
        SessionTreeEntry(id: id, parentId: parent, timestamp: ts(n), payload: .message(.user(text)))
    }

    @discardableResult
    private func append(
        _ store: JSONLSessionStore,
        _ payload: SessionTreeEntry.Payload,
        parent: String?,
        _ n: Int
    ) throws -> String {
        let id = store.createEntryID()
        try store.appendEntry(SessionTreeEntry(id: id, parentId: parent, timestamp: ts(n), payload: payload))
        return id
    }

    // MARK: - Pure navigation

    @Test("branch walks a linear path root-to-leaf in chronological order")
    func linearBranch() throws {
        let tree = SessionTree(entries: [
            messageEntry("a", parent: nil, 1, "one"),
            messageEntry("b", parent: "a", 2, "two"),
            messageEntry("c", parent: "b", 3, "three"),
        ])
        #expect(tree.leafID == "c")
        let path = try tree.branch()
        #expect(path.map(\.id) == ["a", "b", "c"])
    }

    @Test("getEntry finds by id and reports absence without throwing")
    func getEntry() {
        let tree = SessionTree(entries: [messageEntry("a", parent: nil, 1, "one")])
        #expect(tree.entry(withID: "a")?.id == "a")
        #expect(tree.entry(withID: "missing") == nil)
    }

    @Test("children returns the direct descendants of an entry, roots under nil")
    func children() {
        // a ── b ─┬─ c
        //         └─ d
        let tree = SessionTree(entries: [
            messageEntry("a", parent: nil, 1, "one"),
            messageEntry("b", parent: "a", 2, "two"),
            messageEntry("c", parent: "b", 3, "three"),
            messageEntry("d", parent: "b", 4, "four"),
        ])
        #expect(tree.children(of: nil).map(\.id) == ["a"])
        #expect(tree.children(of: "b").map(\.id) == ["c", "d"])
        #expect(tree.children(of: "c").isEmpty)
    }

    @Test("a dangling parentId on the active path throws rather than truncating")
    func danglingParentThrows() {
        // The tolerant bulk read may have dropped the parent; resolving the
        // active path must surface that hole, not silently shorten the branch.
        let tree = SessionTree(entries: [
            messageEntry("child", parent: "ghost", 1, "orphan"),
        ])
        #expect(throws: DoMoError.self) { try tree.branch(from: "child") }
        #expect(throws: DoMoError.self) { try tree.pathToRootOrCompaction(from: "child") }
    }

    @Test("resolving from a missing leaf id throws")
    func missingLeafThrows() {
        let tree = SessionTree(entries: [messageEntry("a", parent: nil, 1, "one")])
        #expect(throws: DoMoError.self) { try tree.branch(from: "nope") }
    }

    // MARK: - Moving the leaf

    @Test("moveLeaf appends a leaf record and the next child forms a new branch")
    func branchMovesLeafAndRebuildsPath() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        let a = try append(store, .message(.user("one")), parent: nil, 1)
        let b = try append(store, .message(.user("two")), parent: a, 2)
        let c = try append(store, .message(.user("three")), parent: b, 3)

        // Before moving: leaf is c, the linear path.
        #expect(try store.leafID() == c)

        // Move the leaf back to b, then append a different child.
        try store.moveLeaf(to: b, timestamp: ts(4))
        #expect(try store.leafID() == b)
        let d = try append(store, .message(.user("four")), parent: try store.leafID(), 5)

        let tree = try SessionTree.load(from: store)
        #expect(tree.leafID == d)
        // The active branch is a → b → d, and c is off the path entirely.
        #expect(try tree.branch(from: d).map(\.id) == [a, b, d])
        #expect(tree.children(of: b).map(\.id) == [c, d])
    }

    @Test("moveLeaf rejects a target that names no entry")
    func moveLeafRejectsUnknownTarget() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        _ = try append(store, .message(.user("one")), parent: nil, 1)
        #expect(throws: DoMoError.self) { try store.moveLeaf(to: "ghost", timestamp: ts(2)) }
    }

    // MARK: - Forking

    @Test("createBranchedSession writes an independent file whose header names the parent")
    func forkNamesParentAndCopiesPath() throws {
        let dir = makeSessionDirectory()
        let source = try JSONLSessionStore.create(cwd: "/w/proj", sessionDirectory: dir, now: fixedClock(fixedDate))
        let a = try append(source, .message(.user("one")), parent: nil, 1)
        let b = try append(source, .message(.user("two")), parent: a, 2)
        // A label lands mid-path; the fork must drop it and re-chain the survivors.
        let label = try append(source, .label(targetId: a, label: "mark"), parent: b, 3)
        let c = try append(source, .message(.user("three")), parent: label, 4)

        let forked = try source.createBranchedSession(
            leafID: c,
            sessionDirectory: dir,
            now: fixedClock(fixedDate)
        )

        // Independent file: a different path from the source.
        #expect(forked.path != source.path)

        let header = try forked.readHeader()
        #expect(header.parentSession == source.path.string)
        #expect(header.cwd == "/w/proj")
        #expect(header.id != (try source.readHeader().id))

        // The label is gone and the retained messages are re-chained linearly so
        // c is no longer orphaned by the removed label.
        let entries = try forked.readEntries()
        #expect(entries.map(\.id) == [a, b, c])
        #expect(entries.allSatisfy { if case .label = $0.payload { return false } else { return true } })
        #expect(entries[0].parentId == nil)
        #expect(entries[1].parentId == a)
        #expect(entries[2].parentId == b)

        // The source file is untouched by the fork.
        #expect(try source.readEntries().count == 4)
    }

    @Test("createBranchedSession throws on an unknown leaf id")
    func forkRejectsUnknownLeaf() throws {
        let dir = makeSessionDirectory()
        let source = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        _ = try append(source, .message(.user("one")), parent: nil, 1)
        #expect(throws: DoMoError.self) {
            _ = try source.createBranchedSession(leafID: "ghost", sessionDirectory: dir)
        }
    }
}
