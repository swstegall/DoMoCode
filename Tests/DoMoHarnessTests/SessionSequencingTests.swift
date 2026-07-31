import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import SystemPackage
import Testing

/// Seeding the per-file `seq` counter, and the fork's renumbering rule.
///
/// The interesting cases all involve files that were written before `seq`
/// existed, because those are the only ones the seeding heuristic has to guess
/// about — and guessing with `readEntries().count` is the specific wrong answer
/// this suite pins down.
@Suite("Session sequencing")
struct SessionSequencingTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func fixedClock(_ date: Date) -> @Sendable () -> Date { { date } }

    private func makeSessionDirectory() -> FilePath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("domocode-seq-tests-\(UUID().uuidString)")
        return FilePath(base.path)
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Writes a session file by hand: a real header, then whatever raw line text
    /// is given. Raw text rather than encoded values so a line can be malformed,
    /// blank, or truncated — none of which an encoder will produce.
    private func writeRawSession(lines: [String], truncatedTail: String? = nil) throws -> FilePath {
        let dir = makeSessionDirectory()
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        let filePath = dir.appending("hand-\(UUID().uuidString).jsonl")
        let header = SessionHeader(id: "sess-1", timestamp: "2026-07-23T12:00:00.000Z", cwd: "/w")

        var bytes = Data()
        bytes.append(try encoder.encode(header))
        bytes.append(0x0A)
        for line in lines {
            bytes.append(Data(line.utf8))
            bytes.append(0x0A)
        }
        if let truncatedTail {
            bytes.append(Data(truncatedTail.utf8))
        }
        try bytes.write(to: URL(fileURLWithPath: filePath.string))
        return filePath
    }

    private func encodedLine(_ entry: SessionTreeEntry) throws -> String {
        String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    private func message(_ id: String, parent: String?, seq: Int? = nil, elapsedMs: Int? = nil) -> SessionTreeEntry {
        SessionTreeEntry(
            id: id,
            parentId: parent,
            timestamp: "2026-07-23T12:00:00.000Z",
            payload: .message(.user(id)),
            seq: seq,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - Seeding: the legacy (no seq anywhere) path

    @Test("a file with only a header seeds the first seq at 0")
    func headerOnlySeedsZero() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        #expect(try store.nextSequenceNumber() == 0)
    }

    @Test("a legacy file with no seq anywhere seeds from its raw entry-line count")
    func legacyFileSeedsFromLineCount() throws {
        let path = try writeRawSession(lines: [
            try encodedLine(message("a", parent: nil)),
            try encodedLine(message("b", parent: "a")),
            try encodedLine(message("c", parent: "b")),
        ])
        let store = try JSONLSessionStore.open(path: path)
        let entries = try store.readEntries()
        #expect(entries.map(\.seq) == [nil, nil, nil])
        #expect(try store.nextSequenceNumber() == 3)
    }

    @Test("a malformed middle line still consumes a number, so seeding does not reuse it")
    func malformedLineIsCountedForSeeding() throws {
        // The load-bearing case. `readEntries` is tolerant and drops the broken
        // line, so counting parsed entries would answer 2 — and the next entry
        // appended would take a number the broken line on disk already spent.
        let path = try writeRawSession(lines: [
            try encodedLine(message("a", parent: nil)),
            #"{"type":"message","id":"broken""#,
            try encodedLine(message("c", parent: "a")),
        ])
        let store = try JSONLSessionStore.open(path: path)
        let entries = try store.readEntries()
        #expect(entries.map(\.id) == ["a", "c"])
        #expect(entries.count == 2)
        #expect(try store.nextSequenceNumber() == 3)
    }

    @Test("a crash-truncated trailing fragment is counted for seeding")
    func truncatedTailIsCountedForSeeding() throws {
        let path = try writeRawSession(
            lines: [try encodedLine(message("a", parent: nil))],
            truncatedTail: #"{"type":"message","id":"m2","parentId":"#
        )
        let store = try JSONLSessionStore.open(path: path)
        let entries = try store.readEntries()
        #expect(entries.map(\.id) == ["a"])
        #expect(try store.nextSequenceNumber() == 2)
    }

    @Test("blank lines are not entries and do not inflate the seed")
    func blankLinesAreNotCounted() throws {
        let path = try writeRawSession(lines: [
            try encodedLine(message("a", parent: nil)),
            "",
            "   ",
            try encodedLine(message("b", parent: "a")),
        ])
        let store = try JSONLSessionStore.open(path: path)
        let entries = try store.readEntries()
        #expect(entries.map(\.id) == ["a", "b"])
        #expect(try store.nextSequenceNumber() == 2)
    }

    // MARK: - Seeding: the max + 1 path

    @Test("a mixed old/new file seeds from the largest seq present, not the entry count")
    func mixedFileSeedsFromMaxPlusOne() throws {
        // Three entries but the highest seq is 5: counting would answer 3 and
        // hand out numbers already on disk.
        let path = try writeRawSession(lines: [
            try encodedLine(message("a", parent: nil)),
            try encodedLine(message("b", parent: "a", seq: 5)),
            try encodedLine(message("c", parent: "b")),
        ])
        let store = try JSONLSessionStore.open(path: path)
        let entries = try store.readEntries()
        #expect(entries.map(\.seq) == [nil, 5, nil])
        #expect(try store.nextSequenceNumber() == 6)
    }

    @Test("seeding takes the largest seq, not the last one written")
    func seedingUsesMaxNotLast() throws {
        // A second writer, or a fork's renumbering, can leave the file's final
        // line holding a smaller number than an earlier line.
        let path = try writeRawSession(lines: [
            try encodedLine(message("a", parent: nil, seq: 9)),
            try encodedLine(message("b", parent: "a", seq: 2)),
        ])
        let store = try JSONLSessionStore.open(path: path)
        let entries = try store.readEntries()
        // The last line's number is smaller than an earlier one, so "seed from
        // the last entry" would answer 3 here.
        #expect(entries.map(\.seq) == [9, 2])
        #expect(try store.nextSequenceNumber() == 10)
    }

    @Test("a malformed line is ignored once any entry carries a seq")
    func malformedLineIgnoredOnTheMaxPath() throws {
        // Deliberately different from the legacy path: with a real number to
        // continue from there is no need to guess, and the broken line's own
        // number is unknowable anyway.
        let path = try writeRawSession(lines: [
            try encodedLine(message("a", parent: nil, seq: 0)),
            #"{"type":"message","id":"broken""#,
            try encodedLine(message("c", parent: "a", seq: 2)),
        ])
        let store = try JSONLSessionStore.open(path: path)
        #expect(try store.nextSequenceNumber() == 3)
    }

    // MARK: - Round-trip through the store

    @Test("seq and elapsedMs survive an append and a tolerant re-read")
    func appendRoundTripsBothFields() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        var parent: String? = nil
        var written: [SessionTreeEntry] = []
        for index in 0..<3 {
            let entry = SessionTreeEntry(
                id: store.createEntryID(),
                parentId: parent,
                timestamp: "2026-07-23T12:00:00.000Z",
                payload: .message(.user("m\(index)")),
                seq: index,
                elapsedMs: index * 100
            )
            try store.appendEntry(entry)
            written.append(entry)
            parent = entry.id
        }
        let read = try store.readEntries()
        #expect(read == written)
        #expect(read.map(\.seq) == [0, 1, 2])
        #expect(read.map(\.elapsedMs) == [0, 100, 200])
        #expect(try store.nextSequenceNumber() == 3)
    }

    @Test("moveLeaf forwards a supplied seq onto the leaf record")
    func moveLeafCarriesSeq() throws {
        let dir = makeSessionDirectory()
        let store = try JSONLSessionStore.create(cwd: "/w", sessionDirectory: dir, now: fixedClock(fixedDate))
        let first = SessionTreeEntry(
            id: store.createEntryID(),
            parentId: nil,
            timestamp: "t",
            payload: .message(.user("one")),
            seq: 0
        )
        try store.appendEntry(first)
        let leafRecordID = try store.moveLeaf(to: first.id, timestamp: "t", seq: 1)

        let entries = try store.readEntries()
        #expect(entries.map(\.id) == [first.id, leafRecordID])
        #expect(entries.map(\.seq) == [0, 1])
        // A leaf move is not a timed turn, so it claims no duration.
        #expect(entries.map(\.elapsedMs) == [nil, nil])
        #expect(try store.nextSequenceNumber() == 2)
    }

    // MARK: - Fork

    @Test("a fork renumbers seq contiguously from 0 and preserves elapsedMs")
    func forkRenumbersAndPreservesElapsed() throws {
        let dir = makeSessionDirectory()
        let source = try JSONLSessionStore.create(cwd: "/w/proj", sessionDirectory: dir, now: fixedClock(fixedDate))

        // Source numbers are deliberately sparse and out of step with position:
        // 4, 9, (label 10), 11. If the fork copied them, the new file would open
        // with gaps and a first entry numbered 4.
        let a = SessionTreeEntry(
            id: source.createEntryID(), parentId: nil, timestamp: "t",
            payload: .message(.user("one")), seq: 4, elapsedMs: 1_500
        )
        try source.appendEntry(a)
        let b = SessionTreeEntry(
            id: source.createEntryID(), parentId: a.id, timestamp: "t",
            payload: .message(.user("two")), seq: 9, elapsedMs: 2_500
        )
        try source.appendEntry(b)
        let label = SessionTreeEntry(
            id: source.createEntryID(), parentId: b.id, timestamp: "t",
            payload: .label(targetId: a.id, label: "mark"), seq: 10
        )
        try source.appendEntry(label)
        let c = SessionTreeEntry(
            id: source.createEntryID(), parentId: label.id, timestamp: "t",
            payload: .message(.user("three")), seq: 11
        )
        try source.appendEntry(c)

        let forked = try source.createBranchedSession(
            leafID: c.id,
            sessionDirectory: dir,
            now: fixedClock(fixedDate)
        )

        let entries = try forked.readEntries()
        #expect(entries.map(\.id) == [a.id, b.id, c.id])
        // Renumbered contiguously from 0: the label was dropped, so carrying the
        // source numbers would have left a hole where 10 was.
        #expect(entries.map(\.seq) == [0, 1, 2])
        // Preserved: a real measurement of the original turns, not re-derivable.
        #expect(entries.map(\.elapsedMs) == [1_500, 2_500, nil])

        // The source file is untouched by the fork: its sparse numbering and its
        // dropped label are both still there.
        let sourceEntries = try source.readEntries()
        #expect(sourceEntries.map(\.seq) == [4, 9, 10, 11])
        #expect(sourceEntries.map(\.elapsedMs) == [1_500, 2_500, nil, nil])
    }

    @Test("a fork of a legacy file gives the new file numbers the old one never had")
    func forkOfLegacyFileNumbersFromZero() throws {
        let dir = makeSessionDirectory()
        let source = try JSONLSessionStore.create(cwd: "/w/proj", sessionDirectory: dir, now: fixedClock(fixedDate))
        var parent: String? = nil
        var ids: [String] = []
        for index in 0..<3 {
            let entry = SessionTreeEntry(
                id: source.createEntryID(),
                parentId: parent,
                timestamp: "t",
                payload: .message(.user("m\(index)"))
            )
            try source.appendEntry(entry)
            ids.append(entry.id)
            parent = entry.id
        }
        let sourceEntries = try source.readEntries()
        #expect(sourceEntries.map(\.seq) == [nil, nil, nil])

        let forked = try source.createBranchedSession(
            leafID: ids[2],
            sessionDirectory: dir,
            now: fixedClock(fixedDate)
        )
        let forkedEntries = try forked.readEntries()
        #expect(forkedEntries.map(\.seq) == [0, 1, 2])
        // And the forked file now seeds off those numbers rather than counting lines.
        #expect(try forked.nextSequenceNumber() == 3)
    }
}
