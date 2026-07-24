// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// An isolated temp tree for one binary run: a working directory the child runs
/// in, an empty config directory, and an empty home. Isolating all three keeps
/// the test off the developer's real `~/.domocode` settings and trust store.
struct Workspace {
    let root: URL
    let workDirectory: URL
    let configDirectory: URL
    let homeDirectory: URL

    init() throws {
        let manager = FileManager.default
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domocode-e2e-\(UUID().uuidString)", isDirectory: true)
        workDirectory = root.appendingPathComponent("work", isDirectory: true)
        configDirectory = root.appendingPathComponent("config", isDirectory: true)
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        for directory in [workDirectory, configDirectory, homeDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func writeFile(named name: String, contents: String) throws {
        try contents.write(
            to: workDirectory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The outcome of running the binary.
struct ProcessRunResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

/// The directory holding the built products, so the `domo` executable can be
/// found next to the test bundle.
///
/// `Bundle.allBundles` does not reliably list the running bundle under SwiftPM's
/// swift-testing helper, so the primary source is the `--test-bundle-path`
/// argument the helper is launched with — walking it up to the directory that
/// contains the `.xctest` bundle, which is the same build directory that holds
/// `domo`. The `.xctest`/`allBundles`/argv-0 fallbacks cover XCTest and Linux.
func productsDirectory() -> URL {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--test-bundle-path"), index + 1 < arguments.count {
        var url = URL(fileURLWithPath: arguments[index + 1])
        while url.pathExtension != "xctest" && url.deletingLastPathComponent().path != url.path {
            url = url.deletingLastPathComponent()
        }
        if url.pathExtension == "xctest" {
            return url.deletingLastPathComponent()
        }
    }
    #if os(macOS)
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
    }
    #endif
    // Linux (and last resort): the test runner and domocode are siblings.
    return URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
}

func domoBinaryURL() -> URL {
    productsDirectory().appendingPathComponent("domo")
}

/// Runs the real `domo` binary and captures its output.
///
/// The child inherits this process's environment — which is what carries the
/// toolchain's `DYLD_*` runtime paths `swift test` sets up, without which the
/// binary cannot load its Swift runtime — and then overrides only the
/// configuration-relevant variables to isolate the run.
func runDomo(arguments: [String], workspace: Workspace) throws -> ProcessRunResult {
    let process = Process()
    process.executableURL = domoBinaryURL()
    process.arguments = arguments
    process.currentDirectoryURL = workspace.workDirectory

    var environment = ProcessInfo.processInfo.environment
    environment["DOMOCODE_CONFIG_DIR"] = workspace.configDirectory.path
    environment["HOME"] = workspace.homeDirectory.path
    environment["DOMOCODE_API_KEY"] = "sk-mock-test-key"
    environment["DOMOCODE_LOG_LEVEL"] = "error"
    // Strip anything from the developer's shell that would leak into resolution.
    for key in ["OPENAI_API_KEY", "LITELLM_API_KEY", "DOMOCODE_MODEL", "DOMOCODE_BASE_URL", "DOMOCODE_OFFLINE"] {
        environment.removeValue(forKey: key)
    }
    process.environment = environment

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    // Output is small; reading stdout to EOF (which arrives when the child exits
    // and closes the pipe) then stderr avoids an ordering deadlock here.
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return ProcessRunResult(
        exitCode: process.terminationStatus,
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self)
    )
}
