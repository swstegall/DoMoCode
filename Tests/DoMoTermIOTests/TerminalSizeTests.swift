// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing

import DoMoTermIO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(Darwin)
private let requestTIOCSWINSZ: UInt = 0x8008_7467
#else
private let requestTIOCSWINSZ: UInt = 0x5414
#endif

@Suite("Terminal size")
struct TerminalSizeTests {

    // MARK: Resolution precedence (no TTY)

    @Test("The kernel size wins when present")
    func kernelWins() {
        let resolved = TerminalSize.resolve(
            ioctl: TerminalSize(columns: 120, rows: 40),
            environment: ["COLUMNS": "200", "LINES": "50"]
        )
        #expect(resolved == TerminalSize(columns: 120, rows: 40))
    }

    @Test("Environment overrides the default when the kernel cannot answer")
    func environmentOverridesDefault() {
        let resolved = TerminalSize.resolve(
            ioctl: nil,
            environment: ["COLUMNS": "100", "LINES": "30"]
        )
        #expect(resolved == TerminalSize(columns: 100, rows: 30))
    }

    @Test("The 80x24 fallback applies when nothing is known")
    func fallbackApplies() {
        let resolved = TerminalSize.resolve(ioctl: nil, environment: [:])
        #expect(resolved == TerminalSize.fallback)
        #expect(resolved == TerminalSize(columns: 80, rows: 24))
    }

    @Test("Non-numeric and non-positive environment values are ignored")
    func environmentGarbageIgnored() {
        #expect(
            TerminalSize.resolve(ioctl: nil, environment: ["COLUMNS": "wide", "LINES": "0"])
                == TerminalSize.fallback
        )
        #expect(
            TerminalSize.resolve(ioctl: nil, environment: ["COLUMNS": "-5"])
                == TerminalSize.fallback
        )
    }

    @Test("Columns and rows resolve independently")
    func dimensionsIndependent() {
        // Kernel knows columns via a partial ioctl result modeled here as a full
        // size; the env fills a dimension the kernel lacks in the nil case.
        let resolved = TerminalSize.resolve(ioctl: nil, environment: ["COLUMNS": "132"])
        #expect(resolved.columns == 132)
        #expect(resolved.rows == 24)
    }

    // MARK: winsize decode (PTY)

    @Test("query decodes the winsize a pty reports")
    func queryDecodesWinsize() {
        guard let pty = PTYPair() else {
            withKnownIssue("no pty available") { Issue.record("pty unavailable") }
            return
        }
        defer { pty.cleanup() }

        var window = winsize()
        window.ws_col = 132
        window.ws_row = 43
        window.ws_xpixel = 0
        window.ws_ypixel = 0
        #expect(ioctl(pty.slave, requestTIOCSWINSZ, &window) == 0)

        let size = TerminalSize.query(fileDescriptor: pty.slave)
        #expect(size == TerminalSize(columns: 132, rows: 43))
    }

    @Test("query returns nil on a non-tty descriptor")
    func queryNilOnPipe() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        #expect(TerminalSize.query(fileDescriptor: fds[0]) == nil)
    }

    // MARK: Resize stream

    @Test("The resize stream yields an initial size")
    func resizeStreamInitialValue() async {
        var iterator = TerminalSize.resizeStream(fileDescriptor: STDOUT_FILENO).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first != nil)
        if let first {
            #expect(first.columns > 0)
            #expect(first.rows > 0)
        }
    }
}
