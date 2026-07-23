// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

import DoMoCore

// MARK: - Test doubles

/// A clock the test moves by hand. `Mutex` rather than a plain `var` only
/// because the closure has to be `@Sendable`.
private final class StubClock: Sendable {
    private let milliseconds: Mutex<UInt64>

    init(_ milliseconds: UInt64) { self.milliseconds = Mutex(milliseconds) }

    func set(_ value: UInt64) { milliseconds.withLock { $0 = value } }

    var read: UUIDv7Generator.Clock {
        { self.milliseconds.withLock { $0 } }
    }
}

/// Hands out a scripted sequence of random draws, then all-zero draws. Zeros
/// after the script make expected outputs readable: every bit in the id is then
/// either the timestamp or the counter.
private final class ScriptedRandom: Sendable {
    private let script: Mutex<[(high: UInt64, low: UInt64)]>

    init(_ draws: [(high: UInt64, low: UInt64)]) { script = Mutex(draws) }

    var read: UUIDv7Generator.RandomSource {
        {
            self.script.withLock { remaining in
                remaining.isEmpty ? (0, 0) : remaining.removeFirst()
            }
        }
    }
}

/// The shape pi's own test asserts, spelled out rather than as a `Regex`
/// literal: `Regex` is not `Sendable`, so it cannot be a global here.
private func matchesCanonicalForm(_ text: String) -> Bool {
    let characters = Array(text)
    guard characters.count == 36 else { return false }
    for (index, character) in characters.enumerated() {
        switch index {
        case 8, 13, 18, 23: guard character == "-" else { return false }
        case 14: guard character == "7" else { return false }
        case 19: guard "89ab".contains(character) else { return false }
        default: guard "0123456789abcdef".contains(character) else { return false }
        }
    }
    return true
}

// MARK: - Tests

@Suite("UUIDv7")
struct UUIDv7Tests {
    /// Ported from pi's `packages/ai/test/uuid.test.ts`. The exact strings are
    /// the contract: DoMoCode and pi must produce interchangeable session ids
    /// for the same clock and random material.
    @Test("Reproduces pi's RFC 9562 layout vector")
    func piVector() throws {
        let clock = StubClock(0x0123_4567_89AB)
        // pi's vector seeds the counter with bytes 6..9 = 0xfffffffe and leaves
        // 0x01 in byte 10 plus 0x1122334455 in bytes 11..15.
        let random = ScriptedRandom([(high: 0xFFFF_FFFE << 32, low: 0x0111_2233_4455)])
        let generator = UUIDv7Generator(clock: clock.read, random: random.read)

        let first = generator.next()
        let second = generator.next()
        let third = generator.next()

        #expect(first.description == "01234567-89ab-7fff-bfff-f91122334455")
        #expect(second.description == "01234567-89ab-7fff-bfff-fc0000000000")
        #expect(third.description == "01234567-89ac-7000-8000-000000000000")

        #expect(first.unixTimeMilliseconds == 0x0123_4567_89AB)
        #expect(second.unixTimeMilliseconds == 0x0123_4567_89AB)
        #expect(third.unixTimeMilliseconds == 0x0123_4567_89AB + 1)

        #expect(first < second)
        #expect(second < third)
    }

    @Test("Version, variant and canonical formatting hold for generated ids")
    func layout() {
        let generator = UUIDv7Generator()
        for _ in 0..<1000 {
            let id = generator.next()
            #expect(matchesCanonicalForm(id.description), "bad form: \(id)")
            #expect((id.high >> 12) & 0xF == 7)
            #expect(id.low >> 62 == 0b10)
        }
    }

    @Test("The embedded timestamp tracks the injected clock")
    func timestampReadback() {
        let clock = StubClock(1_767_225_600_000)  // 2026-01-01T00:00:00Z
        let generator = UUIDv7Generator(clock: clock.read, random: ScriptedRandom([]).read)

        let id = generator.next()

        #expect(id.unixTimeMilliseconds == 1_767_225_600_000)
        #expect(id.timestamp == Date(timeIntervalSince1970: 1_767_225_600))
    }

    /// The property everything downstream relies on: sorting the string forms
    /// must recover generation order. Run against the real clock so the
    /// millisecond-rollover path is exercised too.
    @Test("A large batch sorts lexicographically in generation order")
    func lexicographicOrder() {
        let generator = UUIDv7Generator()
        let ids = (0..<50_000).map { _ in generator.next().description }

        #expect(ids.sorted() == ids)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Ids minted inside one millisecond still ascend")
    func monotonicWithinAMillisecond() {
        let clock = StubClock(1_767_225_600_000)
        let generator = UUIDv7Generator(clock: clock.read)

        let ids = (0..<10_000).map { _ in generator.next() }

        #expect(ids.allSatisfy { $0.unixTimeMilliseconds == 1_767_225_600_000 })
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0 < $1 })
        #expect(ids.map(\.description).sorted() == ids.map(\.description))
    }

    /// `Comparable` is only useful if it agrees with string sorting, since some
    /// call sites compare ids and others compare the strings they were written
    /// to disk as.
    @Test("Value ordering agrees with string ordering")
    func orderingAgreesWithStrings() {
        let generator = UUIDv7Generator()
        let ids = (0..<2000).map { _ in generator.next() }

        for (left, right) in zip(ids, ids.dropFirst()) {
            #expect((left < right) == (left.description < right.description))
        }
    }

    @Test("An NTP step backwards never yields a regressing id")
    func clockGoesBackwards() {
        let clock = StubClock(1_767_225_600_000)
        let generator = UUIDv7Generator(clock: clock.read)

        let before = (0..<50).map { _ in generator.next() }
        clock.set(1_767_225_540_000)  // a minute into the past
        let after = (0..<50).map { _ in generator.next() }

        let all = before + after
        #expect(zip(all, all.dropFirst()).allSatisfy { $0 < $1 })
        // The stale timestamp is retained rather than rewound; that is the only
        // way to stay ordered without inventing a future timestamp.
        #expect(after.allSatisfy { $0.unixTimeMilliseconds == 1_767_225_600_000 })
    }

    @Test("The clock catching up again resumes tracking wall time")
    func clockRecovers() {
        let clock = StubClock(1_000)
        let generator = UUIDv7Generator(clock: clock.read)

        _ = generator.next()
        clock.set(500)
        let stalled = generator.next()
        clock.set(2_000)
        let recovered = generator.next()

        #expect(stalled.unixTimeMilliseconds == 1_000)
        #expect(recovered.unixTimeMilliseconds == 2_000)
        #expect(stalled < recovered)
    }

    /// Counter overflow borrows a millisecond from the future. Seeding the
    /// counter at its maximum makes the second id in the millisecond overflow.
    @Test("Counter overflow borrows a millisecond instead of repeating")
    func counterOverflow() {
        let clock = StubClock(1_767_225_600_000)
        let random = ScriptedRandom([(high: 0xFFFF_FFFF << 32, low: 0)])
        let generator = UUIDv7Generator(clock: clock.read, random: random.read)

        let last = generator.next()
        let wrapped = generator.next()
        let next = generator.next()

        #expect(last.unixTimeMilliseconds == 1_767_225_600_000)
        #expect(wrapped.unixTimeMilliseconds == 1_767_225_600_001)
        // The counter restarts at 0 in the borrowed millisecond, so the id is
        // the smallest one that millisecond can hold — still greater than
        // everything before it.
        #expect(wrapped.description == "019b76da-a801-7000-8000-000000000000")
        #expect(last < wrapped)
        #expect(wrapped < next)
        #expect(next.unixTimeMilliseconds == 1_767_225_600_001)
    }

    /// Regression: an unclamped `last &+ 1` at the top of the 48-bit field
    /// shifts straight out of `timestamp << 16`, so the borrowed millisecond
    /// lands at 0 — and because the generator then holds that as
    /// `lastTimestamp`, *every* later id is stamped 1970 and sorts below
    /// everything already issued. Saturating keeps the id space exhausted in
    /// place instead of rewinding ten thousand years.
    @Test("Counter overflow at the 48-bit ceiling does not wrap to 1970")
    func counterOverflowAtTimestampCeiling() {
        let ceiling: UInt64 = 0xFFFF_FFFF_FFFF
        let clock = StubClock(ceiling)
        let random = ScriptedRandom([(high: 0xFFFF_FFFF << 32, low: 0)])
        let generator = UUIDv7Generator(clock: clock.read, random: random.read)

        let ids = (0..<4).map { _ in generator.next() }

        #expect(ids.allSatisfy { $0.unixTimeMilliseconds == ceiling })
        #expect(ids.allSatisfy { $0.description.hasPrefix("ffffffff-ffff-7") })
    }

    @Test("Round-trips through its canonical string")
    func stringRoundTrip() throws {
        let generator = UUIDv7Generator()
        for _ in 0..<500 {
            let id = generator.next()
            let parsed = try UUIDv7(parsing: id.description)
            #expect(parsed == id)
            #expect(parsed.description == id.description)
            #expect(UUIDv7(id.description) == id)
        }
    }

    @Test("Round-trips through Codable as a bare string")
    func codableRoundTrip() throws {
        let id = UUIDv7.generate()
        let data = try JSONEncoder().encode(["id": id])
        #expect(String(decoding: data, as: UTF8.self) == "{\"id\":\"\(id)\"}")
        #expect(try JSONDecoder().decode([String: UUIDv7].self, from: data)["id"] == id)
    }

    @Test("Rejects a non-UUIDv7 payload when decoding")
    func codableRejectsGarbage() {
        let data = Data(#"{"id":"not-a-uuid"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([String: UUIDv7].self, from: data)
        }
    }

    @Test("Accepts uppercase hex but normalizes to lowercase")
    func uppercaseInput() throws {
        let parsed = try UUIDv7(parsing: "01234567-89AB-7FFF-BFFF-F91122334455")
        #expect(parsed.description == "01234567-89ab-7fff-bfff-f91122334455")
    }

    @Test("Rejects malformed input", arguments: [
        // Too short, too long, unhyphenated.
        ("", UUIDv7Error.invalidLength(0)),
        ("01234567-89ab-7fff-bfff-f9112233445", .invalidLength(35)),
        ("01234567-89ab-7fff-bfff-f911223344556", .invalidLength(37)),
        ("0123456789ab7fffbffff91122334455", .invalidLength(32)),
        // Right length, hyphens in the wrong places.
        ("012345678-9ab-7fff-bfff-f91122334455", .invalidFormat),
        ("01234567+89ab-7fff-bfff-f91122334455", .invalidFormat),
        // Non-hex payload.
        ("0123456g-89ab-7fff-bfff-f91122334455", .invalidCharacter("g", at: 7)),
        ("01234567-89ab-7fff-bfff-f9112233445 ", .invalidCharacter(" ", at: 35)),
        // Structurally fine, but not a version 7 / variant 10 UUID.
        ("01234567-89ab-4fff-bfff-f91122334455", .unsupportedVersion(4)),
        ("01234567-89ab-1fff-bfff-f91122334455", .unsupportedVersion(1)),
        ("01234567-89ab-7fff-cfff-f91122334455", .unsupportedVariant(0b11)),
        ("01234567-89ab-7fff-7fff-f91122334455", .unsupportedVariant(0b01)),
    ])
    func malformedInput(text: String, expected: UUIDv7Error) {
        #expect(throws: expected) { try UUIDv7(parsing: text) }
        #expect(UUIDv7(text) == nil)
    }

    @Test("Raw halves are validated")
    func rawInitValidation() {
        #expect(UUIDv7(high: 0x0123_4567_89AB_7000, low: 0x8000_0000_0000_0000) != nil)
        #expect(UUIDv7(high: 0x0123_4567_89AB_4000, low: 0x8000_0000_0000_0000) == nil)
        #expect(UUIDv7(high: 0x0123_4567_89AB_7000, low: 0xC000_0000_0000_0000) == nil)
    }

    /// The shared generator is the one real global; concurrent hammering is the
    /// case its `Mutex` exists for.
    @Test("The shared generator stays monotonic under concurrent callers")
    func concurrentGeneration() async {
        let slices = await withTaskGroup(of: [UUIDv7].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<2_000).map { _ in UUIDv7.generate() } }
            }
            return await group.reduce(into: [[UUIDv7]]()) { $0.append($1) }
        }

        let all = slices.flatMap(\.self)
        #expect(all.count == 16_000)
        #expect(Set(all).count == all.count)
        // Each task's own ids must ascend even though the tasks interleave, and
        // the string forms have to ascend with them.
        for slice in slices {
            #expect(zip(slice, slice.dropFirst()).allSatisfy { $0 < $1 })
            #expect(slice.map(\.description).sorted() == slice.map(\.description))
        }
    }
}
