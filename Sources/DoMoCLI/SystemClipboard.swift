// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The one place in the package that spawns a process to write the clipboard.
//
// It lives here, in the CLI, because DoMoCLI already depends on DoMoExec and
// DoMoClient deliberately does not: a right-click in the full-screen UI must not
// be the reason the client target learns to fork. The client sees only
// `ClipboardSink`; this is what gets injected into it at launch.
//
// Nothing here invents a spawn seam. `SubprocessShell` already runs a command
// with bytes on its stdin, with a session of its own, a timeout, a termination
// grace period and bounded output capture — every property a clipboard write
// wants — so this is a `ShellRequest` and nothing more.

import DoMoClient
import DoMoExec
import DoMoTermIO
import Foundation

/// A ``ClipboardSink`` that pipes text to the platform's clipboard helper through
/// the same `Shell` seam every tool spawn already uses.
///
/// The text travels on STDIN, never on the command line. That is what makes the
/// sink safe for arbitrary selected text — a selection can contain quotes,
/// newlines, backticks and `$(...)`, and none of it is ever parsed by a shell.
/// The command itself is built only from ``ClipboardCommand``'s compile-time
/// literals, so there is no interpolation to get wrong either.
struct SystemClipboard: ClipboardSink {
    let shell: any Shell
    let command: ClipboardCommand
    /// How long the helper gets. Generous for a program whose whole job is to
    /// read stdin and exit, and short enough that a wedged helper cannot leave a
    /// notice pending for the rest of the session.
    static let timeout: Duration = .seconds(5)

    func copy(_ text: String) async -> ClipboardOutcome {
        let request = ShellRequest(
            command.shellCommand,
            standardInput: .text(text),
            timeout: Self.timeout
        )
        guard let result = try? await shell.run(request) else {
            return .failed("\(command.program) could not be run")
        }
        guard result.isSuccess else {
            return .failed("\(command.program) exited \(result.exitCode.map(String.init) ?? "abnormally")")
        }
        return .copied(command.program)
    }

    /// Resolve a clipboard sink for this machine, or ``NoClipboardSink`` when no
    /// local helper exists.
    ///
    /// `NoClipboardSink` is not a fallback of last resort — over ssh it is the
    /// right answer, because the clipboard that matters is attached to the
    /// terminal on the other end and only OSC 52 can reach it. Resolution happens
    /// once at launch rather than per copy: `PATH` does not change under a running
    /// process in any way worth chasing, and a `stat` storm per right-click would
    /// be absurd.
    static func makeClipboardSink(environment: [String: String]) -> any ClipboardSink {
        guard let command = localClipboardCommand(
            environment: environment,
            isAvailable: { isExecutableOnPath($0, environment: environment) }
        ) else {
            return NoClipboardSink()
        }
        // A machine with no usable shell has no usable helper either — the OSC 52
        // path still stands, so this degrades to "no local helper" rather than
        // failing the launch over a clipboard.
        guard let shell = try? SubprocessShell() else { return NoClipboardSink() }
        return SystemClipboard(shell: shell, command: command)
    }

    /// Whether `program` is an executable file on `PATH`.
    ///
    /// Mirrors `SubprocessShell`'s own search, which is `private` and cannot be
    /// reused. An absolute or relative name containing `/` is checked directly, so
    /// the probe answers the same question `sh` would when it later runs the
    /// command. An empty or missing `PATH` yields nothing rather than falling back
    /// to a hard-coded default: guessing a search path is how a probe ends up
    /// disagreeing with the shell that does the spawning.
    static func isExecutableOnPath(_ program: String, environment: [String: String]) -> Bool {
        let fileManager = FileManager.default
        if program.contains("/") {
            return fileManager.isExecutableFile(atPath: program)
        }
        guard let path = environment["PATH"], !path.isEmpty else { return false }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            if fileManager.isExecutableFile(atPath: "\(directory)/\(program)") { return true }
        }
        return false
    }
}

/// Reads the local clipboard through fixed platform helpers. The command line
/// never contains clipboard data; the only dynamic token is one of the small,
/// hard-coded image MIME strings below.
struct SystemClipboardPasteSource: ClipboardPasteSource {
    private enum Reader: Sendable, Hashable {
        case pngpaste
        case wayland
        case xclip
        case pbpaste
        case xsel
    }

    private static let imageTypes = [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
        "image/bmp",
    ]
    private static let timeout: Duration = .seconds(5)
    private static let imageOutputLimit = ShellOutputLimits(head: 5 << 20, tail: 0)
    private static let textOutputLimit = ShellOutputLimits(head: 1 << 20, tail: 0)

    let shell: any Shell
    private let readers: [Reader]

    func readImage() async -> ClipboardImage? {
        for reader in readers {
            switch reader {
            case .pngpaste:
                if let bytes = await capture("pngpaste -", limits: Self.imageOutputLimit),
                   let image = validatedImage(bytes) {
                    return image
                }
            case .wayland:
                guard let types = await capture("wl-paste --list-types", limits: Self.textOutputLimit)
                    .map({ String(decoding: $0, as: UTF8.self) })
                else { continue }
                let advertised = Set(types.split(whereSeparator: \.isNewline).map(String.init))
                for mediaType in Self.imageTypes where advertised.contains(mediaType) {
                    let command = "wl-paste --no-newline --type \(Self.shellQuote(mediaType))"
                    if let bytes = await capture(command, limits: Self.imageOutputLimit),
                       let image = validatedImage(bytes) {
                        return image
                    }
                }
            case .xclip:
                for mediaType in Self.imageTypes {
                    let command = "xclip -selection clipboard -t \(Self.shellQuote(mediaType)) -o"
                    if let bytes = await capture(command, limits: Self.imageOutputLimit),
                       let image = validatedImage(bytes) {
                        return image
                    }
                }
            case .pbpaste:
                if let bytes = await capture("pbpaste -Prefer png", limits: Self.imageOutputLimit),
                   let image = validatedImage(bytes) {
                    return image
                }
            case .xsel:
                continue
            }
        }
        return nil
    }

    func readText() async -> String? {
        for reader in readers {
            let command: String
            switch reader {
            case .pngpaste, .wayland:
                command = reader == .wayland ? "wl-paste --no-newline" : ""
            case .xclip:
                command = "xclip -selection clipboard -o"
            case .pbpaste:
                command = "pbpaste"
            case .xsel:
                command = "xsel --clipboard --output"
            }
            guard !command.isEmpty,
                  let bytes = await capture(command, limits: Self.textOutputLimit)
            else { continue }
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }

    /// Resolve all available read helpers once at launch, matching the write
    /// sink's no-surprises PATH policy.
    static func make(environment: [String: String]) -> any ClipboardPasteSource {
        let names = ["pngpaste", "wl-paste", "xclip", "pbpaste", "xsel"]
        let available = Set(names.filter {
            SystemClipboard.isExecutableOnPath($0, environment: environment)
        })
        guard !available.isEmpty, let shell = try? SubprocessShell() else {
            return NoClipboardPasteSource()
        }

        var readers: [Reader] = []
        if available.contains("pngpaste") { readers.append(.pngpaste) }
        if available.contains("wl-paste") { readers.append(.wayland) }
        if available.contains("xclip") { readers.append(.xclip) }
        if available.contains("pbpaste") { readers.append(.pbpaste) }
        if available.contains("xsel") { readers.append(.xsel) }
        return SystemClipboardPasteSource(shell: shell, readers: readers)
    }

    private func capture(_ command: String, limits: ShellOutputLimits) async -> [UInt8]? {
        let request = ShellRequest(
            command,
            standardInput: .none,
            timeout: Self.timeout,
            limits: limits
        )
        guard let result = try? await shell.run(request), result.isSuccess, !result.stdout.isTruncated else {
            return nil
        }
        return result.stdout.bytes
    }

    private func validatedImage(_ bytes: [UInt8]) -> ClipboardImage? {
        let data = Data(bytes)
        guard let mediaType = FileContentProbe.imageMediaType(data) else { return nil }
        return ClipboardImage(mediaType: mediaType, data: data)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
