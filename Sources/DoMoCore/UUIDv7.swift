// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/ai/src/utils/uuid.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.

import Foundation
import Synchronization

/// An RFC 9562 version 7 UUID: a 48-bit millisecond timestamp followed by a
/// monotonic counter and randomness.
///
/// Session entry ids are UUIDv7 rather than UUIDv4 because the session tree,
/// branch materialization and JSONL replay all recover creation order by
/// sorting ids as strings. Anything that breaks the "byte order equals
/// generation order" property silently reorders a conversation.
///
/// Stored as two `UInt64` halves rather than 16 bytes so `Comparable` is a pair
/// of integer comparisons and so the type stays a trivial value with no
/// allocation. Because the halves are big-endian slices of the same 128 bits,
/// comparing `(high, low)` numerically is identical to comparing the canonical
/// lowercase hex strings lexicographically — that equivalence is what callers
/// depend on, and it is why `Comparable` is a stored-order comparison and not
/// something cleverer.
public struct UUIDv7: Sendable, Hashable {
    /// Bytes 0–7: 48-bit timestamp, 4-bit version, 12 bits of `rand_a`.
    public let high: UInt64

    /// Bytes 8–15: 2-bit variant, 62 bits of `rand_b`.
    public let low: UInt64

    /// Wraps raw halves, rejecting anything that is not a version 7, variant 10
    /// UUID.
    ///
    /// Validating here means every `UUIDv7` in the program really is one, so
    /// ``timestamp`` and the sort-order guarantee hold unconditionally.
    public init?(high: UInt64, low: UInt64) {
        guard (high >> 12) & 0xF == 7, (low >> 62) == 0b10 else { return nil }
        self.high = high
        self.low = low
    }

    fileprivate init(unchecked high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }
}

// MARK: - Time

extension UUIDv7 {
    /// Milliseconds since the Unix epoch, read out of the leading 48 bits.
    public var unixTimeMilliseconds: UInt64 { high >> 16 }

    /// The embedded creation time.
    ///
    /// Millisecond resolution only: the counter bits that disambiguate ids
    /// generated in the same millisecond are deliberately not folded in here,
    /// because two ids from the same millisecond must compare equal by time
    /// while still ordering by id.
    public var timestamp: Date {
        Date(timeIntervalSince1970: Double(unixTimeMilliseconds) / 1000)
    }
}

// MARK: - Ordering

extension UUIDv7: Comparable {
    public static func < (lhs: UUIDv7, rhs: UUIDv7) -> Bool {
        lhs.high == rhs.high ? lhs.low < rhs.low : lhs.high < rhs.high
    }
}

// MARK: - String form

extension UUIDv7: CustomStringConvertible, LosslessStringConvertible {
    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// The canonical 36-character lowercase hyphenated form.
    public var description: String {
        var characters = [Character]()
        characters.reserveCapacity(36)

        func append(_ value: UInt64, nibbles: Int) {
            for shift in stride(from: (nibbles - 1) * 4, through: 0, by: -4) {
                characters.append(Self.hexDigits[Int((value >> UInt64(shift)) & 0xF)])
            }
        }

        append(high >> 32, nibbles: 8)
        characters.append("-")
        append((high >> 16) & 0xFFFF, nibbles: 4)
        characters.append("-")
        append(high & 0xFFFF, nibbles: 4)
        characters.append("-")
        append(low >> 48, nibbles: 4)
        characters.append("-")
        append(low & 0xFFFF_FFFF_FFFF, nibbles: 12)

        return String(characters)
    }

    /// Parses the canonical form, returning `nil` on any malformed input.
    public init?(_ description: String) {
        guard let parsed = try? UUIDv7(parsing: description) else { return nil }
        self = parsed
    }

    /// Parses the canonical form.
    ///
    /// Uppercase hex is accepted on input — RFC 9562 requires readers to take
    /// either case — but ``description`` always emits lowercase, because ids
    /// are compared as strings and mixed case would break that ordering.
    public init(parsing string: String) throws(UUIDv7Error) {
        // Length is checked on the view, before any buffer is materialized: a
        // corrupt JSONL line can carry a multi-megabyte string, and copying it
        // out only to reject it hands an attacker an allocation for free.
        let utf8 = string.utf8
        guard utf8.count == 36 else { throw .invalidLength(utf8.count) }
        let ascii = Array(utf8)

        let hyphen = UInt8(ascii: "-")
        guard ascii[8] == hyphen, ascii[13] == hyphen, ascii[18] == hyphen, ascii[23] == hyphen
        else { throw .invalidFormat }

        var high: UInt64 = 0
        var low: UInt64 = 0
        var nibblesRead = 0

        for (position, byte) in ascii.enumerated() {
            if position == 8 || position == 13 || position == 18 || position == 23 { continue }
            guard let nibble = Self.nibble(byte) else {
                throw .invalidCharacter(Character(UnicodeScalar(byte)), at: position)
            }
            if nibblesRead < 16 {
                high = (high << 4) | UInt64(nibble)
            } else {
                low = (low << 4) | UInt64(nibble)
            }
            nibblesRead += 1
        }

        let version = UInt8((high >> 12) & 0xF)
        guard version == 7 else { throw .unsupportedVersion(version) }
        let variant = UInt8(low >> 62)
        guard variant == 0b10 else { throw .unsupportedVariant(variant) }

        self.init(unchecked: high, low: low)
    }

    private static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): ascii - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): ascii - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): ascii - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

// MARK: - Codable

extension UUIDv7: Codable {
    /// Encoded as the canonical string, not as a byte array: these ids are
    /// written into JSONL session files that pi and its tooling also read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            self = try UUIDv7(parsing: string)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a UUIDv7: \(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Errors

/// Why a string could not be read as a ``UUIDv7``.
public enum UUIDv7Error: Error, Sendable, Equatable {
    case invalidLength(Int)
    /// Hyphens were absent or in the wrong places for the 8-4-4-4-12 grouping.
    case invalidFormat
    case invalidCharacter(Character, at: Int)
    case unsupportedVersion(UInt8)
    case unsupportedVariant(UInt8)
}

// MARK: - Generation

extension UUIDv7 {
    /// Generates the next id from the process-wide generator.
    ///
    /// Monotonicity is a property of a *generator*, not of the algorithm, so
    /// everything that mints session ids must share one. Two generators running
    /// side by side will interleave within a millisecond.
    public static func generate() -> UUIDv7 { UUIDv7Generator.shared.next() }
}

/// Mints monotonically increasing ``UUIDv7`` values.
///
/// A reference type with an internal lock rather than a value type: the whole
/// point is shared mutable counter state, and hiding that behind value
/// semantics would just produce independent counters that collide.
///
/// The lock is a `Mutex` rather than an actor deliberately. The critical
/// section is a handful of integer operations with no suspension point in it,
/// and id generation is called from `MainActor` render code, from detached
/// storage tasks, and from synchronous parsing helpers — making it `async`
/// would force `await` into all of them for no benefit.
public final class UUIDv7Generator: Sendable {
    /// Milliseconds since the Unix epoch. Returning an integer rather than a
    /// `Date` keeps the injected clock exact: the encoded field *is* integer
    /// milliseconds, and round-tripping it through `TimeInterval` can land a
    /// test on the neighbouring millisecond.
    public typealias Clock = @Sendable () -> UInt64

    /// 128 fresh random bits per id. The high half seeds the counter on a fresh
    /// millisecond; 42 bits of the low half become the trailing randomness.
    public typealias RandomSource = @Sendable () -> (high: UInt64, low: UInt64)

    private struct State {
        /// `nil` until the first id, so a clock legitimately reporting 0 is not
        /// mistaken for "the clock went backwards".
        var lastTimestamp: UInt64?
        var counter: UInt32 = 0
    }

    /// The generator every DoMoCode module should use.
    public static let shared = UUIDv7Generator()

    /// The widest value the 48-bit timestamp field can hold (year 10889).
    private static let maxTimestamp: UInt64 = 0xFFFF_FFFF_FFFF

    private let state = Mutex(State())
    private let clock: Clock
    private let random: RandomSource

    public init(clock: @escaping Clock = UUIDv7Generator.systemClock,
                random: @escaping RandomSource = UUIDv7Generator.systemRandom) {
        self.clock = clock
        self.random = random
    }

    public static let systemClock: Clock = {
        let milliseconds = Date().timeIntervalSince1970 * 1000
        return milliseconds > 0 ? UInt64(milliseconds) : 0
    }

    public static let systemRandom: RandomSource = {
        var generator = SystemRandomNumberGenerator()
        return (generator.next(), generator.next())
    }

    /// Returns the next id, which is strictly greater than every id this
    /// generator has already returned.
    public func next() -> UUIDv7 {
        let bits = random()
        let now = clock() & Self.maxTimestamp

        let (timestamp, counter) = state.withLock { state -> (UInt64, UInt32) in
            var timestamp = now
            if let last = state.lastTimestamp, now <= last {
                // Covers both "same millisecond" and "the clock moved
                // backwards" — an NTP step must never be allowed to rewind
                // `lastTimestamp`, or ids minted after the step would sort
                // before ids minted before it. Staying on the stale timestamp
                // costs nothing but a little drift, which the wall clock
                // reabsorbs as soon as it catches up.
                timestamp = last
                let (bumped, overflowed) = state.counter.addingReportingOverflow(1)
                state.counter = bumped
                if overflowed {
                    // 2^32 ids inside one millisecond. Borrowing a millisecond
                    // from the future is the only way to keep going without
                    // reusing a counter value.
                    //
                    // Clamped to the field, because an unclamped bump at the
                    // ceiling shifts straight out of `timestamp << 16` and
                    // lands every later id at timestamp 0 — permanently below
                    // everything already issued, which is the one failure this
                    // type exists to prevent. Saturating trades uniqueness for
                    // ordering at the ceiling; ordering is the contract.
                    timestamp = min(last &+ 1, Self.maxTimestamp)
                }
            } else {
                // Seeding from randomness rather than 0 keeps the counter bits
                // from disclosing how many ids the process minted this
                // millisecond, and spreads concurrent generators across the
                // space so they collide less.
                state.counter = UInt32(truncatingIfNeeded: bits.high >> 32)
            }
            state.lastTimestamp = timestamp
            return (timestamp, state.counter)
        }

        // The 32-bit counter occupies the most significant bits available after
        // the version and variant nibbles: all 12 of `rand_a`, then the top 20
        // of `rand_b`. It has to sit above the random tail, otherwise two ids
        // from the same millisecond would be ordered by their random bits.
        let high = (timestamp << 16) | 0x7000 | UInt64(counter >> 20)
        let low = (1 << 63)
            | (UInt64(counter & 0x000F_FFFF) << 42)
            | (bits.low & 0x0000_03FF_FFFF_FFFF)

        return UUIDv7(unchecked: high, low: low)
    }
}
