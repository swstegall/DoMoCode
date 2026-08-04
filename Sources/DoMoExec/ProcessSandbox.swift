// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The OS-level boundary for processes the model can cause to run. `PathSandbox`
// protects file-tool paths; this type protects the process itself. The CLI only
// constructs it through `automatic`, which deliberately has no "best effort"
// branch: an unavailable backend is a startup error, never a silent downgrade.

import DoMoCore
import Foundation
import Subprocess
import SystemPackage

/// A launch plan for one model-originated process.
///
/// The wrapper executable is the OS sandbox (`sandbox-exec` or `bwrap`), while
/// `arguments` contains the original command after the wrapper's options. Keeping
/// this as data makes the policy testable without spawning a child and gives all
/// subprocess owners the same fail-closed behavior.
public struct ProcessSandbox: Sendable, Hashable {
    public enum Backend: String, Sendable, Hashable {
        case seatbelt
        case bubblewrap
    }

    /// The capability owner that requested a child process. Keeping this
    /// label in the launch plan lets one policy boundary cover every process
    /// owner instead of treating a formatter, MCP server, or provider as an
    /// unclassified shell.
    public enum Role: String, Codable, Sendable, Hashable, CaseIterable {
        case shell
        case background
        case mcp
        case lsp
        case formatter
        case git
        case workspaceSetup
        case pty
        case browser
        case notebook
        case provider
    }

    public struct Launch: Sendable, Hashable {
        public let executable: FilePath
        public let arguments: [String]
        public let workingDirectory: FilePath

        public init(executable: FilePath, arguments: [String], workingDirectory: FilePath) {
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
        }
    }

    /// The complete sandbox decision for a child. Callers pass this object to
    /// their subprocess library rather than rebuilding executable, arguments,
    /// cwd, and environment policy independently.
    public struct LaunchPlan: Sendable, Hashable {
        public let role: Role
        public let backend: Backend
        public let executable: FilePath
        public let arguments: [String]
        public let workingDirectory: FilePath
        public let environment: ShellEnvironment

        public init(
            role: Role,
            backend: Backend,
            executable: FilePath,
            arguments: [String],
            workingDirectory: FilePath,
            environment: ShellEnvironment
        ) {
            self.role = role
            self.backend = backend
            self.executable = executable
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
        }
    }

    /// The backend selected by ``automatic(root:)``.
    public let backend: Backend

    /// The standardized path visible inside the sandbox. Bubblewrap binds the
    /// project at this same absolute path so existing tool arguments and the
    /// system prompt do not acquire a second, guest-only spelling.
    public let root: FilePath

    private let sourceRoot: FilePath
    private let canonicalRoot: FilePath
    private let backendExecutable: FilePath

    /// A constant SBPL policy. The workspace is supplied as the `WORKSPACE`
    /// parameter to `sandbox-exec`; it is intentionally never interpolated into
    /// this string. A path containing quotes, parentheses, or SBPL syntax is
    /// therefore data in one argv element, not policy text.
    public static let seatbeltProfile = #"""
        (version 1)
        (deny default)
        (import "system.sb")
        (deny network*)
        (allow process*)
        (allow file-read-metadata (subpath "/"))
        (allow file-read* (subpath (param "WORKSPACE")))
        (allow file-write* (subpath (param "WORKSPACE")))
        (allow file-read* (subpath "/bin"))
        (allow file-read* (subpath "/dev"))
        (allow file-read* (subpath "/etc"))
        (allow file-read* (subpath "/Library"))
        (allow file-read* (subpath "/opt"))
        (allow file-read* (subpath "/System"))
        (allow file-read* (subpath "/usr"))
        (allow file-write* (subpath "/dev"))
        """#

    /// Select the native backend for the current platform.
    ///
    /// This is the only production constructor used for `--sandbox`. It checks
    /// both the workspace and the backend executable and throws a configuration
    /// error naming the unavailable backend. Linux does not fall back to an
    /// unconfined shell when `bwrap` is absent, and unsupported platforms refuse
    /// the flag explicitly.
    public static func automatic(root: FilePath) throws(DoMoError) -> ProcessSandbox {
        let paths = try validatedRoot(root)

        #if os(macOS)
        let executable = FilePath("/usr/bin/sandbox-exec")
        guard isExecutable(executable) else {
            throw DoMoError(
                .configuration,
                "--sandbox requested, but the Seatbelt backend is unavailable at (executable)"
            )
        }
        return ProcessSandbox(
            backend: .seatbelt,
            root: paths.display,
            sourceRoot: paths.canonical,
            canonicalRoot: paths.canonical,
            backendExecutable: executable
        )
        #elseif os(Linux)
        guard let executable = searchExecutable(named: "bwrap") else {
            throw DoMoError(
                .configuration,
                "--sandbox requested, but the bubblewrap backend (bwrap) is unavailable on PATH"
            )
        }
        return ProcessSandbox(
            backend: .bubblewrap,
            root: paths.display,
            sourceRoot: paths.canonical,
            canonicalRoot: paths.canonical,
            backendExecutable: executable
        )
        #else
        throw DoMoError(
            .configuration,
            "--sandbox requested, but no supported OS backend is available on this platform"
        )
        #endif
    }

    /// Build a backend-specific launch plan.
    ///
    /// `workingDirectory` is checked through realpath before it is returned in
    /// the guest plan. A symlink inside the project cannot turn a process cwd
    /// into an outside directory, even though the guest keeps the requested
    /// spelling for compatibility with existing command arguments.
    public func launch(
        command: [String],
        workingDirectory: FilePath? = nil
    ) throws(DoMoError) -> Launch {
        guard let first = command.first, !first.isEmpty else {
            throw DoMoError(.configuration, "sandboxed process command must not be empty")
        }
        let guestWorkingDirectory = try guestWorkingDirectory(for: workingDirectory)

        switch backend {
        case .seatbelt:
            return Launch(
                executable: backendExecutable,
                arguments: [
                    "-D", "WORKSPACE=\(sourceRoot.string)",
                    "-p", Self.seatbeltProfile,
                    "--",
                ] + command,
                workingDirectory: guestWorkingDirectory
            )
        case .bubblewrap:
            return Launch(
                executable: backendExecutable,
                arguments: bubblewrapArguments(
                    command: command,
                    workingDirectory: guestWorkingDirectory
                ),
                workingDirectory: guestWorkingDirectory
            )
        }
    }

    /// Builds the one shared policy plan used by shell, MCP, LSP, Git, PTY,
    /// provider, and adapter subprocesses. The environment is pinned in the
    /// same operation as the OS wrapper, so a caller cannot accidentally use
    /// a sandboxed cwd with an unsanitized inherited environment.
    public func plan(
        role: Role = .shell,
        command: [String],
        workingDirectory: FilePath? = nil,
        environment: ShellEnvironment = .inherit,
        alsoUnsetting: Set<String> = []
    ) throws(DoMoError) -> LaunchPlan {
        let launch = try launch(command: command, workingDirectory: workingDirectory)
        return LaunchPlan(
            role: role,
            backend: backend,
            executable: launch.executable,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory,
            environment: environment.pinnedForSandbox(
                workspace: root,
                alsoUnsetting: alsoUnsetting
            )
        )
    }

    /// The root used when a caller did not provide a cwd. A sandboxed process
    /// never inherits the harness's possibly unrelated current directory.
    public func guestWorkingDirectory(for workingDirectory: FilePath?) throws(DoMoError) -> FilePath {
        let requested: FilePath
        if let workingDirectory {
            requested = if workingDirectory.string.hasPrefix("/") {
                workingDirectory
            } else {
                root.appending(workingDirectory.string)
            }
        } else {
            requested = root
        }

        let standardized = URL(fileURLWithPath: requested.string).standardizedFileURL.path
        let canonical = URL(fileURLWithPath: standardized)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard Self.isInside(canonical, root: canonicalRoot) else {
            throw DoMoError(
                .configuration,
                "sandboxed process working directory (requested) is outside the workspace (root)"
            )
        }
        guard FileManager.default.fileExists(atPath: standardized) else {
            throw DoMoError(
                .file(path: requested, errno: nil),
                "sandboxed process working directory does not exist: (requested)"
            )
        }
        return FilePath(standardized)
    }

    /// A deterministic environment for sandboxed children. It keeps the
    /// inherited base so callers can still pass ordinary configuration values,
    /// but removes credential/agent hooks and replaces ambient user-tool state
    /// with stable values.
    public static let sandboxSensitiveEnvironmentNames: Set<String> = [
        "SSH_AGENT_PID",
        "SSH_AUTH_SOCK",
        "SSH_ASKPASS",
        "GIT_ASKPASS",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "AZURE_CLIENT_ID",
        "AZURE_CLIENT_SECRET",
        "AZURE_TENANT_ID",
    ]

    private init(
        backend: Backend,
        root: FilePath,
        sourceRoot: FilePath,
        canonicalRoot: FilePath,
        backendExecutable: FilePath
    ) {
        self.backend = backend
        self.root = root
        self.sourceRoot = sourceRoot
        self.canonicalRoot = canonicalRoot
        self.backendExecutable = backendExecutable
    }

    /// Internal construction is used by pure launch-plan tests to exercise a
    /// backend unavailable on the host running the test suite.
    init(forTestingBackend backend: Backend, root: FilePath, executable: FilePath) throws(DoMoError) {
        let paths = try Self.validatedRoot(root)
        self.init(
            backend: backend,
            root: paths.display,
            sourceRoot: paths.canonical,
            canonicalRoot: paths.canonical,
            backendExecutable: executable
        )
    }

    private func bubblewrapArguments(command: [String], workingDirectory: FilePath) -> [String] {
        var arguments: [String] = [
            "--die-with-parent",
            "--new-session",
            "--unshare-ipc",
            "--unshare-net",
            "--unshare-pid",
            "--tmpfs", "/",
        ]

        // Only the system trees needed to execute ordinary command-line tools
        // are mounted back into the otherwise empty root. The project is the
        // sole writable host tree; the user's home directory is not mounted.
        for path in ["/bin", "/etc", "/lib", "/lib64", "/opt", "/sbin", "/usr"]
            where FileManager.default.fileExists(atPath: path)
        {
            arguments += ["--ro-bind", path, path]
        }
        arguments += ["--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"]

        let components = root.string.split(separator: "/", omittingEmptySubsequences: true)
        if components.count > 1 {
            var parent = ""
            for component in components.dropLast() {
                parent += "/" + component
                arguments += ["--dir", parent]
            }
        }
        arguments += [
            "--bind", sourceRoot.string, root.string,
            "--chdir", workingDirectory.string,
            "--",
        ]
        return arguments + command
    }

    private static func validatedRoot(_ root: FilePath) throws(DoMoError) -> (display: FilePath, canonical: FilePath) {
        let display = FilePath(URL(fileURLWithPath: root.string).standardizedFileURL.path)
        guard display.string != "/" else {
            throw DoMoError(.configuration, "--sandbox requires a workspace below the filesystem root")
        }
        let values = try? URL(fileURLWithPath: display.string)
            .resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            throw DoMoError.file(.noSuchFileOrDirectory, path: display, while: "prepare process sandbox")
        }
        let canonical = FilePath(
            URL(fileURLWithPath: display.string)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        )
        return (display, canonical)
    }

    private static func isExecutable(_ path: FilePath) -> Bool {
        FileManager.default.isExecutableFile(atPath: path.string)
    }

    private static func searchExecutable(named name: String) -> FilePath? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = FilePath(String(directory)).appending(name)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    private static func isInside(_ path: String, root: FilePath) -> Bool {
        let candidate = FilePath(path)
        return candidate == root || candidate.starts(with: root)
    }
}

public extension ShellEnvironment {
    /// The fixed PATH and non-interactive settings used by `--sandbox`.
    ///
    /// The values intentionally describe the child environment, not the host:
    /// `HOME` and XDG state point at workspace-owned state, pagers cannot take
    /// over the model turn, and locale output is stable for both parsing and tests.
    func pinnedForSandbox(
        workspace: FilePath? = nil,
        alsoUnsetting: Set<String> = []
    ) -> ShellEnvironment {
        var overrides = self.overrides
        let names = ProcessSandbox.sandboxSensitiveEnvironmentNames
            .union(Redaction.secretEnvironmentNames)
            .union(alsoUnsetting)
        // `subscript = nil` removes an entry even though the value itself is
        // optional. `updateValue` stores the nested nil that swift-subprocess
        // interprets as an explicit unset rather than inheriting the host value.
        for name in names { overrides.updateValue(nil, forKey: name) }

        overrides["PATH"] = Self.sandboxPath
        let stateRoot = workspace?.string ?? "/tmp"
        overrides["HOME"] = stateRoot
        overrides["TMPDIR"] = stateRoot
        overrides["XDG_CACHE_HOME"] = stateRoot + "/.cache"
        overrides["XDG_CONFIG_HOME"] = stateRoot + "/.config"
        overrides["XDG_STATE_HOME"] = stateRoot + "/.local/state"
        overrides["LC_ALL"] = "C"
        overrides["LANG"] = "C"
        overrides["PAGER"] = "cat"
        overrides["GIT_PAGER"] = "cat"
        overrides["MANPAGER"] = "cat"
        overrides["SYSTEMD_PAGER"] = "cat"
        overrides["TERM"] = "dumb"
        overrides["NO_COLOR"] = "1"
        return ShellEnvironment(base: base, overrides: overrides)
    }

    private static var sandboxPath: String {
        #if os(macOS)
        return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        #else
        return "/usr/local/bin:/usr/bin:/bin"
        #endif
    }
}
