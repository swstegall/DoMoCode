// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage
import Testing

@Suite("External backend adapter", .serialized)
struct ExternalBackendAdapterTests {
    @Test("an empty user-installed command is rejected before startup")
    func emptyCommandIsRejected() {
        #expect(throws: ExternalBackendError.emptyCommand) {
            _ = try ExternalBackendConfiguration(
                descriptor: descriptor(),
                command: []
            )
        }
    }

    @Test("a backend must prove isolation during its health handshake")
    func isolationMustBeProven() async throws {
        let script = try makeScript(
            """
            #!/bin/sh
            cat >/dev/null
            printf '%s' '{"status":"succeeded","output":null,"metadata":{"isolationEstablished":false}}'
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let backend = try ExternalCommandBackend(configuration: ExternalBackendConfiguration(
            descriptor: descriptor(),
            command: [script.path]
        ))
        await #expect(throws: ExternalBackendError.isolationUnavailable("external")) {
            try await backend.start()
        }
        #expect((await backend.health()).state == .failed)
    }

    @Test("a healthy JSON adapter executes through the selected backend")
    func healthyAdapterExecutes() async throws {
        let script = try makeScript(
            """
            #!/bin/sh
            request=$(cat)
            case "$request" in
                *'"operation":"health"'*)
                    printf '%s' '{"status":"succeeded","output":null,"metadata":{"isolationEstablished":true,"authenticated":true,"capabilities":["pty","workspace-write"]}}'
                    ;;
                *)
                    printf '%s' '{"status":"succeeded","output":{"adapter":"external"},"metadata":{}}'
                    ;;
            esac
            """
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let backend = try ExternalCommandBackend(configuration: ExternalBackendConfiguration(
            descriptor: descriptor(),
            command: [script.path]
        ))
        let registry = BackendRegistry()
        try await registry.register(backend)
        try await registry.start(id: "external")
        let selected = try await registry.select(BackendSelectionRequest(
            backendID: "external",
            requiredCapabilities: ["pty"]
        ))
        #expect(selected.health.authenticated)
        let result = try await registry.execute(
            id: "external",
            request: BackendRequest(
                operation: "inspect",
                metadata: ["operationID": "inspect-1"]
            )
        )
        #expect(result.output["adapter"]?.stringValue == "external")
    }

    private func makeScript(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-backend-\(UUID().uuidString)")
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func descriptor() -> BackendDescriptor {
        BackendDescriptor(
            id: "external",
            displayName: "External fixture",
            kind: .custom,
            capabilities: ["pty", "workspace-write"],
            requiresIsolation: true,
            source: AdapterSourceMetadata(
                kind: .user,
                license: "user-supplied"
            )
        )
    }
}
