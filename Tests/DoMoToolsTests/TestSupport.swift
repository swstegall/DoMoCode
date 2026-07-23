import DoMoCore
import DoMoExec
import DoMoTools
import Foundation
import SystemPackage

/// A temporary sandbox root plus a tool context pointed at it.
struct ToolFixture {
    let root: FilePath
    let context: ToolContext
    private let cleanupURL: URL

    /// Builds a fresh temp directory and a ``ToolContext`` sandboxed to it.
    static func make(toolLocator: ExternalToolLocator = .pathSearch) async throws -> ToolFixture {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("domotools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let shell = try SubprocessShell()
        let context = try await ToolContext.rooted(
            at: FilePath(base.path),
            shell: shell,
            toolLocator: toolLocator
        )
        return ToolFixture(root: context.workingDirectory, context: context, cleanupURL: base)
    }

    /// The absolute filesystem path of a path relative to the sandbox root.
    func path(_ relative: String) -> String {
        root.appending(relative).string
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            atPath: path(relative), withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> String {
        try writeBytes(relative, Data(contents.utf8))
    }

    @discardableResult
    func writeBytes(_ relative: String, _ data: Data) throws -> String {
        let full = path(relative)
        let parent = (full as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: full, contents: data)
        return full
    }

    /// Creates a symlink at `relative` pointing at `target` (an absolute path).
    func symlink(_ relative: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: target)
    }

    func removeCleanup() {
        try? FileManager.default.removeItem(at: cleanupURL)
    }
}

/// Creates executable stub scripts named after each key and returns a locator
/// that resolves those names to them — a stand-in for a host `rg`/`fd` so the
/// shell-out code path is exercised without the real binaries installed.
func fakeToolLocator(_ tools: [String: String]) throws -> ExternalToolLocator {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("domotools-fake-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var paths: [String: FilePath] = [:]
    for (name, script) in tools {
        let file = dir.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        paths[name] = FilePath(file.path)
    }
    let resolved = paths
    return ExternalToolLocator { resolved[$0] }
}

/// A throwaway temp directory *outside* any sandbox, for escape targets.
func makeOutsideFile(_ name: String, _ contents: String) throws -> String {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("domotools-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
    return file.path
}
