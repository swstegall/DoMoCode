// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing

@testable import DoMoCore

@Suite("Code intelligence coordinator", .serialized)
struct CodeIntelligenceTests {
    @Test("normalizes workspace paths and bounds provider results")
    func normalizesAndBounds() async throws {
        let provider = FakeCodeProvider()
        let coordinator = try CodeIntelligenceCoordinator(
            rootPath: "/project",
            provider: provider,
            policy: CodeIntelligencePolicy(maxResults: 2)
        )

        let result = try await coordinator.perform(CodeIntelligenceRequest(
            operation: .workspaceSymbols,
            rootPath: "/ignored",
            query: "App",
            limit: 50
        ))

        #expect(result.items.count == 2)
        #expect(result.providerID == "fake")
        #expect(await provider.lastRequest?.rootPath == "/project")
        #expect(await provider.lastRequest?.limit == 2)
    }

    @Test("read-only requests cannot escape the workspace")
    func rejectsOutsidePath() async throws {
        let coordinator = try CodeIntelligenceCoordinator(
            rootPath: "/project",
            provider: FakeCodeProvider()
        )

        await #expect(throws: CodeIntelligenceCoordinatorError.pathOutsideRoot("/other/App.swift")) {
            _ = try await coordinator.perform(CodeIntelligenceRequest(
                operation: .documentSymbols,
                rootPath: "/project",
                path: "/other/App.swift"
            ))
        }
    }

    @Test("rename requires an allowed operation and an identifier-shaped name")
    func validatesRename() async throws {
        let provider = FakeCodeProvider()
        let readOnly = try CodeIntelligenceCoordinator(
            rootPath: "/project",
            provider: provider,
            policy: CodeIntelligencePolicy(allowedOperations: [.definition])
        )
        await #expect(throws: CodeIntelligenceCoordinatorError.permissionDenied(.rename)) {
            _ = try await readOnly.perform(CodeIntelligenceRequest(
                operation: .rename,
                rootPath: "/project",
                path: "/project/App.swift",
                position: .init(line: 0, column: 0),
                newName: "Renamed"
            ))
        }

        let writable = try CodeIntelligenceCoordinator(
            rootPath: "/project",
            provider: provider
        )
        await #expect(throws: CodeIntelligenceCoordinatorError.invalidRenameName) {
            _ = try await writable.perform(CodeIntelligenceRequest(
                operation: .rename,
                rootPath: "/project",
                path: "/project/App.swift",
                position: .init(line: 0, column: 0),
                newName: "not safe"
            ))
        }
    }

    @Test("missing operation inputs fail before provider invocation")
    func validatesInputs() async throws {
        let provider = FakeCodeProvider()
        let coordinator = try CodeIntelligenceCoordinator(rootPath: "/project", provider: provider)

        await #expect(throws: CodeIntelligenceCoordinatorError.missingPosition(.definition)) {
            _ = try await coordinator.perform(CodeIntelligenceRequest(
                operation: .definition,
                rootPath: "/project",
                path: "/project/App.swift"
            ))
        }
        #expect(await provider.lastRequest == nil)
    }
}

private actor FakeCodeProvider: DoMoCodeIntelligenceProvider {
    nonisolated let codeIntelligenceID = "fake"
    private(set) var lastRequest: CodeIntelligenceRequest?

    func perform(_ request: CodeIntelligenceRequest) async throws -> CodeIntelligenceResult {
        lastRequest = request
        let items = (0..<10).map { index in
            IndexSymbol(
                name: "Symbol\(index)",
                kind: .function,
                location: IndexLocation(path: "/project/App.swift", line: index, column: 0)
            )
        }
        return CodeIntelligenceResult(
            operation: request.operation,
            providerID: codeIntelligenceID,
            items: items
        )
    }
}
