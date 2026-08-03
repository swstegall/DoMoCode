import DoMoCore
import DoMoExec
import Foundation
import SystemPackage
import Testing

@Suite("Background processes", .serialized, .timeLimit(.minutes(2)))
struct BackgroundProcessTests {
    @Test("a process can be started, polled, written to, and stopped")
    func lifecycle() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domo-background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BackgroundProcessManager()
        let started = try await manager.start(
            "printf 'ready\\n'; read line; printf 'received:%s\\n' \"$line\"; sleep 30",
            workingDirectory: FilePath(root.path),
            environment: .inherit
        )
        #expect(started.state == .running)

        let ready = try await waitForOutput(manager: manager, id: started.id, containing: "ready")
        #expect(ready.output.contains("ready"))
        #expect(await manager.write(id: started.id, input: "hello\n"))
        let received = try await waitForOutput(manager: manager, id: started.id, containing: "received:hello")
        #expect(received.output.contains("received:hello"))

        #expect(await manager.stop(id: started.id))
        let stopped = await manager.poll(id: started.id, clearOutput: false)
        #expect(stopped?.state == .terminated || stopped?.state == .exited)
        await manager.shutdown()
    }

    private func waitForOutput(
        manager: BackgroundProcessManager,
        id: String,
        containing needle: String
    ) async throws -> BackgroundProcessSnapshot {
        for _ in 0..<100 {
            if let snapshot = await manager.poll(id: id), snapshot.output.contains(needle) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = await manager.poll(id: id, clearOutput: false)
        Issue.record("timed out waiting for background output \(needle): \(String(describing: snapshot))")
        return snapshot ?? BackgroundProcessSnapshot(id: id, state: .failed)
    }
}
