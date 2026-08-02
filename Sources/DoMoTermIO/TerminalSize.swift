// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The per-platform TIOCGWINSZ constants follow the shape of
// swift-argument-parser's internal Platform.swift (Apache-2.0), which hardcodes
// them for the same reason: the values come from the `_IOR` macro and are not
// reliably surfaced by the Swift platform overlays.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A terminal's usable character grid.
///
/// Columns and rows, not pixels: everything above measures text in cells, and a
/// width bug corrupts every following column on a line, so the renderer needs the
/// cell count and nothing else.
public struct TerminalSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// The 80×24 DEC VT100 default, used when neither the kernel nor the
    /// environment can say. A sane grid is always better than zero, which would
    /// make the renderer divide by the width.
    public static let fallback = TerminalSize(columns: 80, rows: 24)
}

/// The pixel size of one terminal cell — what inline image display needs to turn
/// an image's pixel dimensions into a cell footprint. Reported by the kernel
/// (`ws_xpixel`/`ws_ypixel` ÷ the grid) or by a terminal cell-size query; many
/// terminals report neither, so a consumer keeps a sane default (9×18).
public struct CellPixelSize: Sendable, Hashable {
    public var widthPx: Int
    public var heightPx: Int
    public init(widthPx: Int, heightPx: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

// MARK: - Platform constant

#if canImport(Darwin)
/// `_IOR('t', 104, struct winsize)` on the BSD/Darwin ABI.
private let requestTIOCGWINSZ: UInt = 0x4008_7468
#else
/// `0x5413` on the Linux ABI (glibc and musl agree).
private let requestTIOCGWINSZ: UInt = 0x5413
#endif

// MARK: - Query and resolution

extension TerminalSize {
    /// Ask the kernel for the descriptor's window size, or `nil` if it cannot
    /// answer.
    ///
    /// Returns `nil` — rather than a fabricated size — when the `ioctl` fails
    /// (the descriptor is a pipe, or there is no terminal), and also when it
    /// succeeds but reports a zero dimension, which some environments do. Both
    /// mean "the kernel does not know", and ``resolve(ioctl:environment:)`` is
    /// what turns "does not know" into a concrete grid.
    public static func query(fileDescriptor: Int32) -> TerminalSize? {
        var window = winsize()
        guard ioctl(fileDescriptor, requestTIOCGWINSZ, &window) == 0 else { return nil }
        let columns = Int(window.ws_col)
        let rows = Int(window.ws_row)
        guard columns > 0, rows > 0 else { return nil }
        return TerminalSize(columns: columns, rows: rows)
    }

    /// Layer the kernel size over environment overrides over the default.
    ///
    /// Precedence per dimension, matching pi's `stdout.columns || COLUMNS || 80`:
    /// the kernel wins when it answered, then `COLUMNS`/`LINES`, then
    /// ``fallback``. The environment path is what makes the size usable with no
    /// TTY at all — a piped invocation with `COLUMNS=100` set — which is also the
    /// only path a test can exercise without a real terminal.
    ///
    /// Pure: `ioctl` and `environment` are both supplied, so the whole precedence
    /// ladder is testable without touching a descriptor.
    public static func resolve(
        ioctl kernelSize: TerminalSize?,
        environment: [String: String]
    ) -> TerminalSize {
        let columns =
            kernelSize?.columns
            ?? positiveInt(environment["COLUMNS"])
            ?? fallback.columns
        let rows =
            kernelSize?.rows
            ?? positiveInt(environment["LINES"])
            ?? fallback.rows
        return TerminalSize(columns: columns, rows: rows)
    }

    /// The resolved size right now, reading the kernel and the process
    /// environment.
    public static func current(fileDescriptor: Int32 = STDOUT_FILENO) -> TerminalSize {
        resolve(
            ioctl: query(fileDescriptor: fileDescriptor),
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// One cell's pixel size from the kernel: `ws_xpixel`/`ws_ypixel` divided by
    /// the grid. Returns nil when the terminal reports no pixel size (common — many
    /// terminals leave `ws_xpixel`/`ws_ypixel` zero) or has no window at all, in
    /// which case a caller falls back to a cell-size query or a fixed default.
    public static func cellPixelSize(fileDescriptor: Int32 = STDOUT_FILENO) -> CellPixelSize? {
        var window = winsize()
        guard ioctl(fileDescriptor, requestTIOCGWINSZ, &window) == 0 else { return nil }
        let columns = Int(window.ws_col)
        let rows = Int(window.ws_row)
        let pixelWidth = Int(window.ws_xpixel)
        let pixelHeight = Int(window.ws_ypixel)
        guard columns > 0, rows > 0, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CellPixelSize(widthPx: pixelWidth / columns, heightPx: pixelHeight / rows)
    }

    /// Whether `fileDescriptor` is an interactive terminal. Print mode consults this
    /// before emitting inline-image escapes: a piped or redirected stdout must stay
    /// byte-clean (a base64 graphics escape written into a file would corrupt it),
    /// so images render only to a real tty.
    public static func isTerminal(fileDescriptor: Int32 = STDOUT_FILENO) -> Bool {
        isatty(fileDescriptor) == 1
    }

    private static func positiveInt(_ value: String?) -> Int? {
        guard let value, let parsed = Int(value), parsed > 0 else { return nil }
        return parsed
    }
}

// MARK: - Resize stream

extension TerminalSize {
    /// An async stream that yields the size now and on every `SIGWINCH`.
    ///
    /// Delivered as an `AsyncStream` so a terminal resize composes with keyboard
    /// input and stream events under one `for await`, instead of being a
    /// callback the render loop has to thread separately.
    ///
    /// `SIGWINCH` is first set to `SIG_IGN` and then observed through a
    /// `DispatchSource`, never a C signal handler: the handler body reads the new
    /// size with `ioctl` and yields it, and neither is remotely async-signal-safe,
    /// so it must run on a dispatch queue rather than in signal context. The
    /// source lives as long as the stream is consumed and is cancelled when the
    /// consumer stops.
    ///
    /// The first value is emitted eagerly, because a consumer needs a size before
    /// the first resize — pi refreshes on start for exactly this reason, since a
    /// `SIGWINCH` sent while the process was suspended is simply lost.
    public static func resizeStream(
        fileDescriptor: Int32 = STDOUT_FILENO,
        queue: DispatchQueue = DispatchQueue(label: "domo.termio.sigwinch")
    ) -> AsyncStream<TerminalSize> {
        AsyncStream { continuation in
            signal(SIGWINCH, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
            source.setEventHandler {
                continuation.yield(TerminalSize.current(fileDescriptor: fileDescriptor))
            }
            let box = DispatchSourceBox(source)
            continuation.onTermination = { _ in
                box.source.cancel()
            }

            continuation.yield(TerminalSize.current(fileDescriptor: fileDescriptor))
            source.resume()
        }
    }
}
