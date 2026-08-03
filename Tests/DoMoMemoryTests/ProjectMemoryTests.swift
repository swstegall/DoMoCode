import DoMoCore
import DoMoMemory
import Foundation
import SystemPackage
import Testing

@Suite("project memory")
struct ProjectMemoryTests {

    @Test("stores typed records outside the checkout and upserts by kind and title")
    func roundTripAndUpsert() async throws {
        let fixture = try MemoryFixture.make()
        defer { fixture.remove() }
        let store = ProjectMemoryStore(
            configDirectory: fixture.config,
            cwd: fixture.workspace.path,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        #expect(!store.path.string.contains(fixture.workspace.path))
        let first = try await store.remember(
            kind: .project,
            title: "database",
            content: "Use SQLite for durable project memory.",
            sourceSessionID: "session-1",
            tags: ["decision", "sqlite"]
        )
        let second = try await store.remember(
            kind: .project,
            title: "database",
            content: "Use SQLite with a bounded JSON document.",
            sourceSessionID: "session-2",
            tags: ["sqlite"]
        )

        #expect(first.id == second.id)
        #expect(first.createdAt == second.createdAt)
        let records = try await store.list()
        #expect(records.count == 1)
        #expect(records[0].content.contains("bounded JSON"))
        #expect(records[0].tags == ["sqlite"])
        #expect(FileManager.default.fileExists(atPath: store.path.string))
    }

    @Test("rejects secret-shaped content before the first byte is written")
    func redactionGate() async throws {
        let fixture = try MemoryFixture.make()
        defer { fixture.remove() }
        let store = ProjectMemoryStore(path: fixture.config.appending("memory.json"))

        do {
            _ = try await store.remember(
                kind: .correction,
                title: "gateway",
                content: "Never store sk-1234567890ABCDEFGH in memory."
            )
            Issue.record("secret-shaped memory unexpectedly succeeded")
        } catch let error as ProjectMemoryError {
            #expect(error == .secretDetected(field: "content"))
        }
        #expect(!FileManager.default.fileExists(atPath: store.path.string))

        do {
            _ = try await store.remember(
                kind: .correction,
                title: "gateway",
                content: "Keep this note safe.",
                id: "sk-1234567890ABCDEFGH"
            )
            Issue.record("secret-shaped memory id unexpectedly succeeded")
        } catch let error as ProjectMemoryError {
            #expect(error == .secretDetected(field: "id"))
        }
        #expect(!FileManager.default.fileExists(atPath: store.path.string))
    }

    @Test("enforces the total byte budget")
    func byteBudget() async throws {
        let fixture = try MemoryFixture.make()
        defer { fixture.remove() }
        let store = ProjectMemoryStore(
            path: fixture.config.appending("memory.json"),
            byteBudget: 300
        )

        do {
            _ = try await store.remember(
                kind: .sessionDigest,
                title: "large",
                content: String(repeating: "x", count: 500)
            )
            Issue.record("over-budget memory unexpectedly succeeded")
        } catch let error as ProjectMemoryError {
            guard case .byteBudgetExceeded(let limit, let required) = error else {
                Issue.record("unexpected memory error: \(error)")
                return
            }
            #expect(limit == 300)
            #expect(required > limit)
        }
    }

    @Test("removes a record atomically through the same store")
    func forget() async throws {
        let fixture = try MemoryFixture.make()
        defer { fixture.remove() }
        let store = ProjectMemoryStore(path: fixture.config.appending("memory.json"))
        let record = try await store.remember(
            kind: .environment,
            title: "toolchain",
            content: "Use the pinned Swift toolchain."
        )

        #expect(try await store.forget(id: record.id))
        #expect(try await store.list().isEmpty)
        #expect(!(try await store.forget(id: record.id)))
    }
}

private struct MemoryFixture {
    let root: URL
    let config: FilePath
    let workspace: URL

    static func make() throws -> MemoryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent("config")
        let workspace = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return MemoryFixture(
            root: root,
            config: FilePath(configURL.path),
            workspace: workspace
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
