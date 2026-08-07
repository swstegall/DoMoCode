// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Where this process's diagnostics go while the full-screen client owns the
// terminal.
//
// Every mode bootstraps logging to stderr (``DoMoCodeCommand/bootstrapLogging(level:)``),
// and the DEFAULT surface runs the runtime server in the SAME process as the
// client painting the alternate screen. So one `domo.server` warning is written
// to the very terminal the renderer addresses by absolute row, and it lands
// wherever the cursor happens to be — which is the prompt, because parking the
// cursor there is the last thing every frame does. A 500 from the server, or the
// session-client journal being set aside, therefore prints a paragraph across
// the prompt area and the renderer never repaints those cells, since nothing in
// its model changed. That is the "breaks the tui at the prompt area" the user
// reported, reproduced on a pty by giving the child the same terminal for stdout
// and stderr that a real shell gives it.
//
// **`dup2`, not a swift-log handler swap.** A handler swap only moves the writers
// that go through swift-log, and the ones that paint the frame are not all of
// them:
//
//  * ``DoMoCodeCommand``'s own `writeStderr` — resolution warnings, the MCP
//    server `log:` closure, the `--serve` handshake — writes to
//    `FileHandle.standardError` and never sees a `LogHandler`.
//  * NIO, AsyncHTTPClient and the Swift runtime write to fd 2 directly
//    (allocation failures, precondition traces, `Fatal error:`), and no
//    swift-log configuration can reach them.
//  * `LoggingSystem.bootstrap` may only be called once per process, so a swap
//    would additionally need the bootstrapped factory to consult a mutable
//    global — more machinery, catching strictly less.
//
// Replacing file descriptor 2 catches every one of those, including a subprocess
// that inherits it, because it moves the *destination* rather than one library's
// idea of where the destination is.
//
// The restore is registered process-globally and run from `atexit`, the same
// shape ``DoMoTermIO/TerminalLifecycle`` uses to guarantee `?1049l`. It
// deliberately does NOT install signal handlers, and that is a difference in the
// hazard, not an oversight: a terminal left in the alternate screen outlives the
// process and strands the user's shell, whereas a redirected descriptor is
// destroyed with the process's descriptor table. Adding a second
// `SIGINT`/`SIGTERM`/`SIGHUP` source would also be actively harmful — those
// handlers must re-raise to let the process die with the right status, and a
// second one racing `TerminalLifecycle`'s could re-raise FIRST and kill the
// process before the alternate screen was ever left.

import Foundation
import Synchronization
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What restoring the redirect needs, held process-globally.
///
/// Global for the same reason ``DoMoTermIO/TerminalLifecycle``'s registration
/// is: `atexit` takes a bare C function pointer that can capture nothing, so the
/// saved descriptor has to be reachable without an instance. The `Mutex` makes
/// the register/restore race safe and — `Mutex` being unconditionally `Sendable`
/// — lets this be a `nonisolated let`.
private struct StderrRedirect {
    /// A `dup` of the original stderr: what fd 2 is pointed back at on restore.
    let savedDescriptor: Int32
    /// Where the redirected diagnostics are being written.
    let logPath: FilePath
}

private let activeRedirect = Mutex<StderrRedirect?>(nil)

/// Whether the `atexit` restore has been registered. Once per process; a second
/// ``FullScreenLogRedirect/begin(configDirectory:)`` re-arms the registration but
/// must not stack another handler.
private let restoreRegistered = Mutex<Bool>(false)

/// Put fd 2 back, exactly once.
///
/// Idempotent: the registration is cleared under the lock *before* the work runs,
/// so an ordinary ``FullScreenLogRedirect/end()`` followed by the `atexit`
/// restore closes the saved descriptor once rather than twice — a double `close`
/// would not merely be wasted, it could close a descriptor some later part of the
/// process had since been handed the same number for.
private func performStderrRestore() {
    let redirect: StderrRedirect? = activeRedirect.withLock { slot in
        defer { slot = nil }
        return slot
    }
    guard let redirect else { return }
    _ = dup2(redirect.savedDescriptor, STDERR_FILENO)
    _ = close(redirect.savedDescriptor)
}

/// Sends stderr to a file for as long as the full-screen client owns the
/// terminal, and puts it back afterwards.
public enum FullScreenLogRedirect {

    /// How many per-run log files a config directory keeps. Enough to compare the
    /// run that failed with the one before it, few enough that a user who never
    /// looks does not accumulate a file per session forever.
    static let retainedLogFiles = 5

    /// The file this process's diagnostics are being written to, or `nil` when
    /// nothing is redirected.
    ///
    /// Non-`nil` exactly while stderr is redirected, which is what makes it usable
    /// as the "and the details are in …" hint on an error the user is being shown:
    /// when it is `nil`, stderr is still the terminal and there is no other file to
    /// point at.
    public static var currentLogPath: FilePath? {
        activeRedirect.withLock { $0?.logPath }
    }

    /// Point stderr at a file under `configDirectory`, and return where it went.
    ///
    /// Answers `nil` — leaving stderr exactly as it was — whenever the redirect
    /// would be wrong rather than merely unnecessary:
    ///
    ///  * stdout and stderr are not the same terminal. That covers `-p`/`--json`
    ///    piped runs (which never reach this call at all, but must not be
    ///    silently reliant on that), a deliberate `2>run.log`, and the operator
    ///    who parked stderr on a second terminal to watch it — stealing that
    ///    would be taking away a diagnostic the user explicitly arranged.
    ///  * the log file cannot be created. A read-only config directory is not a
    ///    reason to lose diagnostics altogether.
    ///
    /// Calling it twice does not redirect twice; the second call answers the file
    /// the first one opened.
    @discardableResult
    public static func begin(configDirectory: FilePath) -> FilePath? {
        guard sharesTerminal(STDOUT_FILENO, STDERR_FILENO) else { return nil }

        // Opened outside the lock: the `Mutex` guards the registration, and
        // holding it across `open(2)` and a directory listing would put blocking
        // filesystem work inside a lock the exit path also takes.
        let directory = logDirectory(configDirectory: configDirectory)
        guard let opened = openLogFile(in: directory) else { return nil }

        let path: FilePath? = activeRedirect.withLock { slot -> FilePath? in
            // Already redirected — a second caller's descriptor is surplus, and
            // it names the same file, so nothing is lost by dropping it.
            if let existing = slot {
                try? opened.descriptor.close()
                return existing.logPath
            }
            // The order is: save first, then swap. A `dup2` onto fd 2 closes what
            // was there, so failing to save the original before that point is
            // unrecoverable — the terminal would be gone with nothing to restore.
            let saved = dup(STDERR_FILENO)
            guard saved >= 0 else {
                try? opened.descriptor.close()
                return nil
            }
            guard dup2(opened.descriptor.rawValue, STDERR_FILENO) >= 0 else {
                _ = close(saved)
                try? opened.descriptor.close()
                return nil
            }
            // fd 2 now refers to the file; the descriptor `open` handed back is a
            // second reference to the same open file and is not needed. Leaving it
            // open would leak one descriptor per full-screen session.
            try? opened.descriptor.close()

            slot = StderrRedirect(savedDescriptor: saved, logPath: opened.path)
            registerRestoreOnExit()
            return opened.path
        }

        if let path {
            pruneOldLogs(in: directory, keeping: retainedLogFiles, except: path)
        }
        return path
    }

    /// Put stderr back on the terminal.
    ///
    /// Must run before anything reports a failure to the user — a `DoMoError`
    /// rendered by ``DoMoCodeCommand/run()`` after the client returns has to reach
    /// the shell, not the file nobody is going to read. Idempotent, and a no-op
    /// when ``begin(configDirectory:)`` declined.
    public static func end() {
        performStderrRestore()
    }

    // MARK: Paths

    /// Where per-run diagnostics live: `<config-dir>/logs`.
    static func logDirectory(configDirectory: FilePath) -> FilePath {
        configDirectory.appending("logs")
    }

    /// The file name for one run.
    ///
    /// Keyed by process id rather than being one shared `fullscreen.log`, because
    /// two full-screen clients running side by side would otherwise interleave
    /// their diagnostics into one file — and the whole value of the file is being
    /// able to read one session's story in order.
    static func logFileName(processID: Int32) -> String {
        "fullscreen-\(processID).log"
    }

    /// Whether a name is one of this scheme's log files, and therefore something
    /// ``pruneOldLogs(in:keeping:except:)`` may delete. Deliberately strict: the
    /// pruner deletes files, and a config directory is the user's.
    static func isLogFileName(_ name: String) -> Bool {
        name.hasPrefix("fullscreen-") && name.hasSuffix(".log")
    }

    /// Create the log directory if needed and open this run's file for append.
    ///
    /// `0600`: a diagnostic log carries prompts, paths and gateway errors, and
    /// this project's other durable files under the config directory are
    /// owner-only for the same reason. Append rather than truncate so a rerun with
    /// a recycled pid adds to the record instead of erasing it.
    private static func openLogFile(in directory: FilePath) -> (descriptor: FileDescriptor, path: FilePath)? {
        do {
            try FileManager.default.createDirectory(
                atPath: directory.string,
                withIntermediateDirectories: true
            )
            let path = directory.appending(logFileName(processID: getpid()))
            let descriptor = try FileDescriptor.open(
                path,
                .writeOnly,
                options: [.create, .append],
                permissions: .ownerReadWrite
            )
            return (descriptor, path)
        } catch {
            return nil
        }
    }

    /// Keep the `keeping` most recently modified log files and delete the rest.
    ///
    /// Two files are never deleted whatever the clock says:
    ///
    ///  * `except` — the file this run is about to write to. A filesystem with a
    ///    coarse or skewed modification time must not be able to make the pruner
    ///    remove the log out from under the live redirect.
    ///  * any file named for a process that still exists. A second `domo` that has
    ///    been sitting open all afternoon has an OLD log by mtime, and unlinking
    ///    it would leave that session writing to a file nobody can find — the
    ///    descriptor stays valid, so nothing fails and the diagnostics simply
    ///    cease to exist.
    ///
    /// Failures are ignored: housekeeping must never be the reason a session does
    /// not start.
    static func pruneOldLogs(in directory: FilePath, keeping: Int, except: FilePath? = nil) {
        guard keeping >= 0 else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.string) else { return }
        let dated = names.filter(isLogFileName).map { name -> (name: String, path: FilePath, modified: Date) in
            let path = directory.appending(name)
            let attributes = try? manager.attributesOfItem(atPath: path.string)
            let modified = attributes?[.modificationDate] as? Date ?? Date.distantPast
            return (name, path, modified)
        }
        // Newest first, so "the ones to keep" is a prefix. Ties break on the name
        // so the order is total and the same set survives on every run.
        let ordered = dated.sorted {
            $0.modified == $1.modified ? $0.name > $1.name : $0.modified > $1.modified
        }
        for entry in ordered.dropFirst(keeping) {
            guard entry.path != except else { continue }
            guard let owner = processID(inLogFileName: entry.name), !processExists(owner) else { continue }
            try? manager.removeItem(atPath: entry.path.string)
        }
    }

    /// The process id encoded in one of this scheme's file names.
    ///
    /// `nil` for anything that does not parse, and the pruner treats that as
    /// "leave it alone" — a file it cannot attribute is not a file it may delete.
    static func processID(inLogFileName name: String) -> Int32? {
        guard isLogFileName(name) else { return nil }
        let digits = name.dropFirst("fullscreen-".count).dropLast(".log".count)
        return Int32(digits)
    }

    /// Whether a process with this id is still around.
    ///
    /// Signal 0 performs the existence and permission checks without delivering
    /// anything. A process owned by another user answers `EPERM` rather than 0,
    /// but that case cannot arise for a file in *this* user's config directory,
    /// so the plain success test is the whole check.
    private static func processExists(_ id: Int32) -> Bool {
        guard id > 0 else { return false }
        return kill(id, 0) == 0
    }

    // MARK: The gate

    /// Whether two descriptors are the same terminal — the precise condition
    /// under which a write to one lands on the other's frame.
    ///
    /// Comparing tty NAMES rather than merely asking `isatty` twice is what
    /// distinguishes "stderr will paint over the UI" from "the operator pointed
    /// stderr at a second terminal on purpose". Both names are copied into Swift
    /// strings as they are read, because `ttyname` answers from a static buffer
    /// that the second call would overwrite.
    static func sharesTerminal(_ first: Int32, _ second: Int32) -> Bool {
        guard let firstName = terminalName(first) else { return false }
        guard let secondName = terminalName(second) else { return false }
        return firstName == secondName
    }

    /// The tty device path behind a descriptor, or `nil` when it is not a
    /// terminal.
    private static func terminalName(_ descriptor: Int32) -> String? {
        guard isatty(descriptor) == 1 else { return nil }
        guard let name = unsafe ttyname(descriptor) else { return nil }
        return unsafe String(cString: name)
    }

    // MARK: Crash safety

    /// Arm the `atexit` restore, once per process.
    ///
    /// `atexit` handlers run last-registered-first, and this one is registered
    /// before ``DoMoTermIO/TerminalLifecycle`` installs its own (which happens
    /// inside `enter()`, after the client has started). So on exit the terminal is
    /// taken out of the alternate screen FIRST and stderr is put back after —
    /// which is the order that leaves a dying process's last words on a normal
    /// screen the user can read.
    private static func registerRestoreOnExit() {
        let alreadyRegistered = restoreRegistered.withLock { registered -> Bool in
            if registered { return true }
            registered = true
            return false
        }
        guard !alreadyRegistered else { return }
        atexit {
            performStderrRestore()
        }
    }
}
