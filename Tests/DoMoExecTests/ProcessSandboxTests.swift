// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoExec
import Foundation
import SystemPackage
import Testing

@testable import DoMoExec

private final class SandboxScratch: Sendable {
    let url: URL
    let path: FilePath

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("domo-process-sandbox-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = FilePath(url.resolvingSymlinksInPath().path)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class WorkspaceScratch: Sendable {
    let url: URL
    let path: FilePath

    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".domo-process-sandbox-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = FilePath(url.path)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

@Suite("Process sandbox launch plans", .serialized)
struct ProcessSandboxPlanTests {
    @Test("Pinned child environments scrub credentials and ambient interactive state")
    func pinsEnvironment() async throws {
        let environment = ShellEnvironment.inherit([
            "DOMOCODE_API_KEY": "should-disappear",
            "DOMO_SANDBOX_CUSTOM_SECRET": "should-disappear",
            "PATH": "/user/bin",
        ])
        let pinned = environment.pinnedForSandbox(
            workspace: FilePath("/work"),
            alsoUnsetting: ["DOMO_SANDBOX_CUSTOM_SECRET"]
        )

        #expect(pinned.base == .inherited)
        #expect(pinned.overrides.keys.contains("DOMOCODE_API_KEY"))
        #expect(pinned.overrides.keys.contains("DOMO_SANDBOX_CUSTOM_SECRET"))
        if let apiKey = pinned.overrides["DOMOCODE_API_KEY"],
           let customSecret = pinned.overrides["DOMO_SANDBOX_CUSTOM_SECRET"]
        {
            #expect(apiKey == nil)
            #expect(customSecret == nil)
        } else {
            Issue.record("sandbox environment did not retain explicit unset entries")
        }
        #expect(pinned.overrides["PATH"] != "/user/bin")
        #expect(pinned.overrides["LC_ALL"] == "C")
        #expect(pinned.overrides["PAGER"] == "cat")
        #expect(pinned.overrides["HOME"] == "/work")

        let shell = try SubprocessShell()
        let child = try await shell.run(
            ShellRequest(
                "if env | grep -E '^(DOMOCODE_API_KEY|DOMO_SANDBOX_CUSTOM_SECRET)=' >/dev/null; then exit 1; else exit 0; fi",
                environment: pinned
            )
        )
        #expect(child.isSuccess)
    }

    @Test("Seatbelt keeps the workspace out of SBPL and passes it as a parameter")
    func seatbeltIsParameterized() throws {
        let scratch = try SandboxScratch()
        let sandbox = try ProcessSandbox(
            forTestingBackend: .seatbelt,
            root: scratch.path,
            executable: FilePath("/usr/bin/sandbox-exec")
        )
        let launch = try sandbox.launch(
            command: ["/bin/echo", "hello"],
            workingDirectory: scratch.path
        )

        #expect(ProcessSandbox.seatbeltProfile.contains("(param \"WORKSPACE\")"))
        #expect(!ProcessSandbox.seatbeltProfile.contains(scratch.path.string))
        #expect(launch.arguments.contains("-p"))
        #expect(launch.arguments.contains("WORKSPACE=" + sandbox.root.string))
        #expect(launch.arguments.suffix(2).elementsEqual(["/bin/echo", "hello"]))
    }

    @Test("Bubblewrap hides the host root before binding only system trees and the workspace")
    func bubblewrapIsFailClosedInItsPlan() throws {
        let scratch = try SandboxScratch()
        let sandbox = try ProcessSandbox(
            forTestingBackend: .bubblewrap,
            root: scratch.path,
            executable: FilePath("/usr/bin/bwrap")
        )
        let launch = try sandbox.launch(command: ["bash", "-c", "pwd"], workingDirectory: scratch.path)

        #expect(launch.arguments.contains("--tmpfs"))
        #expect(launch.arguments.contains("/"))
        #expect(launch.arguments.contains("--unshare-net"))
        #expect(launch.arguments.contains("--bind"))
        #expect(launch.arguments.contains(sandbox.root.string))
        #expect(launch.arguments.suffix(4).elementsEqual(["--", "bash", "-c", "pwd"]))
    }

    #if os(macOS)
    @Test("The available Seatbelt backend confines a shell without spawning an unwrapped fallback")
    func seatbeltShellRunsConfined() async throws {
        let scratch = try WorkspaceScratch()
        let sandbox = try ProcessSandbox.automatic(root: scratch.path)
        let shell = try SubprocessShell(sandbox: sandbox)
        let result = try await shell.run(
            ShellRequest(
                "touch marker; test ! -r /Users",
                workingDirectory: scratch.path
            )
        )

        #expect(result.isSuccess)
        #expect(result.stderr.text.isEmpty)
        #expect(FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("marker").path))
    }
    #endif
}
