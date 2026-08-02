// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The result of one nonblocking descriptor read.
public enum NonblockingReadResult: Sendable, Equatable {
    /// Bytes were read. The buffer is non-empty.
    case bytes([UInt8])
    /// The peer closed the descriptor.
    case endOfFile
    /// No bytes are available yet; the caller should wait for the next event.
    case wouldBlock
    /// The read failed with this POSIX error number.
    case error(Int32)
}

/// POSIX operations needed by asynchronous terminal readers.
///
/// This is deliberately in ``DoMoTermIO``: it is the package's one raw POSIX
/// seam, built without strict memory safety. Higher layers receive typed values
/// and never have to spell an `unsafe` buffer operation just to read a tty.
public enum NonblockingFileDescriptor {
    /// The original descriptor flags, so a caller can put the descriptor back
    /// exactly as it found it when its asynchronous reader terminates.
    public struct Flags: Sendable, Equatable {
        fileprivate let descriptor: Int32
        fileprivate let value: Int32

        fileprivate init(descriptor: Int32, value: Int32) {
            self.descriptor = descriptor
            self.value = value
        }

        /// Restore the flags captured by ``makeNonblocking(_:)``.
        public func restore() {
            _ = fcntl(descriptor, F_SETFL, value)
        }
    }

    /// Set a descriptor to nonblocking mode and return its prior flags.
    public static func makeNonblocking(_ descriptor: Int32) -> Flags? {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return nil
        }
        return Flags(descriptor: descriptor, value: flags)
    }

    /// Read one available chunk without waiting for another event.
    public static func read(_ descriptor: Int32, maximumBytes: Int = 64 * 1024) -> NonblockingReadResult {
        guard maximumBytes > 0 else { return .error(EINVAL) }

        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return DarwinOrGlibcRead(descriptor, baseAddress, rawBuffer.count)
        }

        if count > 0 {
            return .bytes(Array(buffer.prefix(count)))
        }
        if count == 0 {
            return .endOfFile
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return .wouldBlock
        }
        return .error(errno)
    }
}

private func DarwinOrGlibcRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}
