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

/// The environment a `domo` child runs under in an end-to-end test.
///
/// It INHERITS this process's environment — which is what carries the
/// toolchain's `DYLD_*` runtime paths `swift test` sets up, without which the
/// binary cannot load its Swift runtime — then removes everything that
/// configures a run (the whole `DOMOCODE_*` namespace, plus the two unprefixed
/// credential fallbacks), and only then applies the isolation defaults and the
/// caller's overrides.
///
/// **The removal is by prefix, and that is the whole point of this function.**
/// It used to be a list of five names spelled out at each spawn site, and that
/// list made end-to-end tests depend on the developer's shell:
///
/// * an exported `DOMOCODE_REASONING_EFFORT=high` satisfied the reasoning-effort
///   assertion in ``SurfaceWiringTests`` with the per-alias plumbing that
///   assertion exists to pin DELETED, and
/// * an exported `DOMOCODE_SMALL_MODEL` installed a compaction summarizer that a
///   test's stated premise says nothing configured, failing it for a reason
///   found nowhere in the repository.
///
/// A test a stray shell variable can satisfy is not a test. A name-by-name list
/// is also a thing to forget: ``EnvName`` gains a variable and every spawn site
/// has to be revisited, whereas `DOMOCODE_*` is the naming rule that file
/// already states. The two credential fallbacks that carry no prefix
/// (`LITELLM_API_KEY`, `OPENAI_API_KEY`) are named explicitly because nothing
/// about their spelling says `domo`.
///
/// - Parameter inherited: the environment to start from. A parameter rather than
///   a direct read of `ProcessInfo` so the sweep itself can be tested without
///   mutating the test process's own environment.
/// - Parameter extra: applied LAST, so a caller can override an isolation
///   default (a test that must exercise the retry loop shrinks the backoff
///   instead of paying seconds of real sleep) and so a deliberately-set
///   `DOMOCODE_*` value survives the sweep.
func isolatedChildEnvironment(
    inherited: [String: String] = ProcessInfo.processInfo.environment,
    workspace: Workspace,
    extra: [String: String] = [:]
) -> [String: String] {
    var environment = inherited
    for key in Array(environment.keys) where key.hasPrefix("DOMOCODE_") {
        environment.removeValue(forKey: key)
    }
    for key in ["LITELLM_API_KEY", "OPENAI_API_KEY"] {
        environment.removeValue(forKey: key)
    }
    environment["DOMOCODE_CONFIG_DIR"] = workspace.configDirectory.path
    environment["HOME"] = workspace.homeDirectory.path
    environment["DOMOCODE_API_KEY"] = "sk-mock-test-key"
    environment["DOMOCODE_LOG_LEVEL"] = "error"
    for (key, value) in extra { environment[key] = value }
    return environment
}

/// Runs the real `domo` binary and captures its output.
///
/// - Parameter environment: extra variables, applied last — see
///   ``isolatedChildEnvironment(inherited:workspace:extra:)``, which is where
///   this run's isolation is decided.
func runDomo(
    arguments: [String],
    workspace: Workspace,
    environment extra: [String: String] = [:]
) throws -> ProcessRunResult {
    let process = Process()
    process.executableURL = domoBinaryURL()
    process.arguments = arguments
    process.currentDirectoryURL = workspace.workDirectory
    process.environment = isolatedChildEnvironment(workspace: workspace, extra: extra)

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
