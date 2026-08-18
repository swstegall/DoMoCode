import DoMoCore
import DoMoHarness
import DoMoLLM
import Foundation
import Testing

@Suite("SessionEntry and SessionHeader Codable")
struct SessionEntryTests {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    private func roundTrip(_ entry: SessionTreeEntry) throws -> SessionTreeEntry {
        try decoder.decode(SessionTreeEntry.self, from: encoder.encode(entry))
    }

    private func roundTrip(_ header: SessionHeader) throws -> SessionHeader {
        try decoder.decode(SessionHeader.self, from: encoder.encode(header))
    }

    // MARK: - Header

    @Test("Root session header round-trips")
    func rootHeaderRoundTrips() throws {
        let header = SessionHeader(
            id: "0190a0c1-2233-7000-8000-000000000001",
            timestamp: "2026-07-23T12:00:00.000Z",
            cwd: "/Users/dev/project"
        )
        let decoded = try roundTrip(header)
        #expect(decoded == header)
        #expect(decoded.parentSession == nil)
        #expect(decoded.type == "session")
        #expect(decoded.version == SessionHeader.currentVersion)
    }

    @Test("Forked session header carries parentSession")
    func forkedHeaderRoundTrips() throws {
        let header = SessionHeader(
            id: "0190a0c1-2233-7000-8000-000000000002",
            timestamp: "2026-07-23T12:05:00.000Z",
            cwd: "/Users/dev/project",
            parentSession: "/Users/dev/.domocode/sessions/--Users-dev-project--/orig.jsonl"
        )
        let decoded = try roundTrip(header)
        #expect(decoded == header)
        #expect(decoded.parentSession == header.parentSession)
    }

    @Test("Header decode rejects a non-session type")
    func headerRejectsWrongType() throws {
        let json = Data(#"{"type":"message","version":1,"id":"x","timestamp":"t","cwd":"/c"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(SessionHeader.self, from: json)
        }
    }

    @Test("Header decode rejects an unsupported version")
    func headerRejectsWrongVersion() throws {
        let json = Data(#"{"type":"session","version":999,"id":"x","timestamp":"t","cwd":"/c"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(SessionHeader.self, from: json)
        }
    }

    // MARK: - Entry envelope

    @Test("Root entry encodes parentId as explicit null")
    func rootEntryEncodesNullParent() throws {
        let entry = SessionTreeEntry(
            id: "a1",
            parentId: nil,
            timestamp: "2026-07-23T12:00:01.000Z",
            payload: .sessionInfo(name: "root")
        )
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(json.contains("\"parentId\":null"))
        #expect(try roundTrip(entry) == entry)
    }

    // MARK: - Every payload round-trips

    @Test("message entry round-trips a user message")
    func messageUserRoundTrips() throws {
        let entry = SessionTreeEntry(
            id: "m1",
            parentId: nil,
            timestamp: "2026-07-23T12:00:02.000Z",
            payload: .message(.user("hello world"))
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        #expect(decoded.entryType == .message)
    }

    @Test("session start entry round-trips the Git HEAD")
    func sessionStartRoundTrips() throws {
        let entry = SessionTreeEntry(
            id: "git1",
            parentId: nil,
            timestamp: "2026-07-23T12:00:02.500Z",
            payload: .sessionStart(head: "abc123")
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        #expect(decoded.entryType == .sessionStart)
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(json.contains(#""type":"session_start""#))
        #expect(json.contains(#""head":"abc123""#))
    }

    @Test("subagent metadata round-trips without entering message context")
    func subagentRoundTrips() throws {
        let event = SubagentTaskEvent(
            taskID: "task-1",
            childSessionID: "child",
            parentSessionID: "parent",
            description: "inspect parser",
            status: .completed,
            output: "done",
            depth: 1
        )
        let entry = SessionTreeEntry(
            id: "delegation-1",
            parentId: "m1",
            timestamp: "2026-07-23T12:00:02.750Z",
            payload: .subagent(event)
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        #expect(decoded.entryType == .subagent)
        #expect(ContextBuilder.messages(for: decoded).isEmpty)
    }

    @Test("typed recovery metadata round-trips without entering message context")
    func recoveryRoundTrips() throws {
        let envelope = RecoveryEnvelope(
            originalKind: "provider",
            status: 503,
            error: "upstream overloaded",
            model: "m",
            attemptedRemedies: ["retried"],
            diagnosis: "provider capacity was exhausted",
            userApprovedAction: false
        )
        let entry = SessionTreeEntry(
            id: "recovery-1",
            parentId: "m1",
            timestamp: "2026-07-23T12:00:02.900Z",
            payload: .recovery(envelope)
        )

        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        #expect(decoded.entryType == .recovery)
        #expect(ContextBuilder.messages(for: decoded).isEmpty)
    }

    @Test("message entry round-trips an assistant message with tool calls and usage")
    func messageAssistantRoundTrips() throws {
        let assistant = AssistantMessage(
            content: [
                .text("Let me look."),
                .toolCall(ToolCallBlock(id: "call_1", name: "bash", arguments: .object(["cmd": .string("ls")]))),
            ],
            model: "claude-sonnet-4-5",
            usage: Usage(input: 100, output: 20, cacheRead: 5, cacheWrite: 3),
            stopReason: .toolUse
        )
        let entry = SessionTreeEntry(
            id: "m2",
            parentId: "m1",
            timestamp: "2026-07-23T12:00:03.000Z",
            payload: .message(.assistant(assistant))
        )
        #expect(try roundTrip(entry) == entry)
    }

    @Test("message entry round-trips a tool result")
    func messageToolResultRoundTrips() throws {
        let entry = SessionTreeEntry(
            id: "m3",
            parentId: "m2",
            timestamp: "2026-07-23T12:00:04.000Z",
            payload: .message(.tool(ToolResultBlock(toolCallID: "call_1", toolName: "bash", output: "file.txt")))
        )
        #expect(try roundTrip(entry) == entry)
    }

    @Test("model_change entry round-trips")
    func modelChangeRoundTrips() throws {
        let entry = SessionTreeEntry(
            id: "mc",
            parentId: "m3",
            timestamp: "2026-07-23T12:05:00.000Z",
            payload: .modelChange(provider: "openai", modelId: "gpt-4o")
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(json.contains("\"type\":\"model_change\""))
        #expect(json.contains("\"modelId\":\"gpt-4o\""))
    }

    @Test("agent_change entry round-trips a selected and cleared profile")
    func agentChangeRoundTrips() throws {
        let selected = SessionTreeEntry(
            id: "ac",
            parentId: "mc",
            timestamp: "2026-07-23T12:06:00.000Z",
            payload: .agentChange(name: "review")
        )
        let cleared = SessionTreeEntry(
            id: "ac-clear",
            parentId: "ac",
            timestamp: "2026-07-23T12:07:00.000Z",
            payload: .agentChange(name: nil)
        )

        #expect(try roundTrip(selected) == selected)
        #expect(try roundTrip(cleared) == cleared)
        #expect(selected.entryType == .agentChange)
        let json = String(decoding: try encoder.encode(selected), as: UTF8.self)
        #expect(json.contains("\"type\":\"agent_change\""))
        #expect(json.contains("\"agent\":\"review\""))
        let clearedJSON = String(decoding: try encoder.encode(cleared), as: UTF8.self)
        #expect(clearedJSON.contains("\"agent\":null"))
    }

    @Test("compaction entry round-trips with retainedTail and usage")
    func compactionRoundTrips() throws {
        let compaction = Compaction(
            summary: "User asked about X, Y, Z.",
            tokensBefore: 50_000,
            retainedTail: [.user("latest request")],
            usage: Usage(input: 200, output: 40)
        )
        let entry = SessionTreeEntry(
            id: "cp",
            parentId: "mc",
            timestamp: "2026-07-23T12:10:00.000Z",
            payload: .compaction(compaction)
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        #expect(decoded.entryType == .compaction)
    }

    @Test("compaction entry round-trips the legacy firstKeptEntryId form")
    func compactionLegacyRoundTrips() throws {
        let compaction = Compaction(summary: "older summary", tokensBefore: 12_000, firstKeptEntryId: "m2")
        let entry = SessionTreeEntry(
            id: "cp2",
            parentId: "cp",
            timestamp: "2026-07-23T12:11:00.000Z",
            payload: .compaction(compaction)
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(json.contains("\"firstKeptEntryId\":\"m2\""))
        #expect(!json.contains("retainedTail"))
    }

    @Test("branch_summary entry round-trips")
    func branchSummaryRoundTrips() throws {
        let entry = SessionTreeEntry(
            id: "bs",
            parentId: "m1",
            timestamp: "2026-07-23T12:15:00.000Z",
            payload: .branchSummary(BranchSummary(fromId: "cp", summary: "Branch explored approach A."))
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        #expect(decoded.entryType == .branchSummary)
    }

    @Test("label entry round-trips a set label")
    func labelSetRoundTrips() throws {
        let entry = SessionTreeEntry(
            id: "lb",
            parentId: "m1",
            timestamp: "2026-07-23T12:30:00.000Z",
            payload: .label(targetId: "m1", label: "checkpoint-1")
        )
        #expect(try roundTrip(entry) == entry)
    }

    @Test("label entry omits a cleared label")
    func labelClearedOmitsField() throws {
        let entry = SessionTreeEntry(
            id: "lb2",
            parentId: "lb",
            timestamp: "2026-07-23T12:31:00.000Z",
            payload: .label(targetId: "m1", label: nil)
        )
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        // The `label` *field* is absent (the value "label" still appears in
        // `"type":"label"`, so match the key form).
        #expect(!json.contains("\"label\":"))
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        if case .label(_, let label) = decoded.payload {
            #expect(label == nil)
        } else {
            Issue.record("expected label payload")
        }
    }

    @Test("session_info entry round-trips a name")
    func sessionInfoRoundTrips() throws {
        let entry = SessionTreeEntry(
            id: "si",
            parentId: "m1",
            timestamp: "2026-07-23T12:35:00.000Z",
            payload: .sessionInfo(name: "Refactor auth module")
        )
        #expect(try roundTrip(entry) == entry)
    }

    @Test("leaf entry round-trips both a target and a null target")
    func leafRoundTrips() throws {
        let toTarget = SessionTreeEntry(
            id: "lf1",
            parentId: "m3",
            timestamp: "2026-07-23T12:40:00.000Z",
            payload: .leaf(targetId: "m1")
        )
        #expect(try roundTrip(toTarget) == toTarget)
        #expect(toTarget.leafIdAfterEntry == "m1")

        let reset = SessionTreeEntry(
            id: "lf2",
            parentId: "lf1",
            timestamp: "2026-07-23T12:41:00.000Z",
            payload: .leaf(targetId: nil)
        )
        let json = String(decoding: try encoder.encode(reset), as: UTF8.self)
        #expect(json.contains("\"targetId\":null"))
        #expect(try roundTrip(reset) == reset)
        #expect(reset.leafIdAfterEntry == nil)
    }

    @Test("leafIdAfterEntry is the entry's own id for non-leaf entries")
    func leafIdAfterNonLeaf() {
        let entry = SessionTreeEntry(
            id: "x9",
            parentId: nil,
            timestamp: "t",
            payload: .sessionInfo(name: nil)
        )
        #expect(entry.leafIdAfterEntry == "x9")
    }

    @Test("Decoding an unknown entry type throws")
    func unknownTypeThrows() {
        let json = Data(#"{"type":"custom","id":"c1","parentId":null,"timestamp":"t","data":{}}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(SessionTreeEntry.self, from: json)
        }
    }

    // MARK: - seq / elapsedMs backward compatibility

    // The compatibility proof for the two envelope fields added after the format
    // shipped. The expected JSON is written out as a literal rather than
    // compared against this encoder's own output: comparing an encoder to itself
    // would still pass if `seq` were emitted unconditionally as `null`, which is
    // precisely the regression these tests exist to catch.

    @Test("an entry with neither seq nor elapsedMs encodes byte-identically to the pre-field format")
    func omittedWhenNilSessionInfo() throws {
        let entry = SessionTreeEntry(
            id: "a1",
            parentId: nil,
            timestamp: "2026-07-23T12:00:01.000Z",
            payload: .sessionInfo(name: "root")
        )
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(
            json == #"{"id":"a1","name":"root","parentId":null,"timestamp":"2026-07-23T12:00:01.000Z","type":"session_info"}"#
        )
    }

    @Test("a leaf entry with neither field keeps its explicit null targetId and gains nothing else")
    func omittedWhenNilLeaf() throws {
        let entry = SessionTreeEntry(
            id: "lf",
            parentId: "p",
            timestamp: "t",
            payload: .leaf(targetId: nil)
        )
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(json == #"{"id":"lf","parentId":"p","targetId":null,"timestamp":"t","type":"leaf"}"#)
    }

    @Test("a model_change entry with neither field encodes byte-identically")
    func omittedWhenNilModelChange() throws {
        let entry = SessionTreeEntry(
            id: "mc",
            parentId: "p",
            timestamp: "t",
            payload: .modelChange(provider: "openai", modelId: "gpt-4o")
        )
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(
            json == #"{"id":"mc","modelId":"gpt-4o","parentId":"p","provider":"openai","timestamp":"t","type":"model_change"}"#
        )
    }

    @Test("seq and elapsedMs are emitted when set and round-trip")
    func seqAndElapsedRoundTrip() throws {
        let entry = SessionTreeEntry(
            id: "a1",
            parentId: nil,
            timestamp: "t",
            payload: .sessionInfo(name: "root"),
            seq: 7,
            elapsedMs: 1234
        )
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(
            json == #"{"elapsedMs":1234,"id":"a1","name":"root","parentId":null,"seq":7,"timestamp":"t","type":"session_info"}"#
        )
        let decoded = try roundTrip(entry)
        #expect(decoded == entry)
        #expect(decoded.seq == 7)
        #expect(decoded.elapsedMs == 1234)
    }

    @Test("seq 0 and elapsedMs 0 survive the round trip as values, not as absence")
    func zeroIsNotAbsence() throws {
        let entry = SessionTreeEntry(
            id: "z",
            parentId: nil,
            timestamp: "t",
            payload: .message(.user("hi")),
            seq: 0,
            elapsedMs: 0
        )
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(json.contains(#""seq":0"#))
        #expect(json.contains(#""elapsedMs":0"#))
        let decoded = try roundTrip(entry)
        #expect(decoded.seq == 0)
        #expect(decoded.elapsedMs == 0)
    }

    @Test("a hand-written line from before the fields existed decodes with both nil")
    func legacyLineDecodesWithNilFields() throws {
        let json = Data(
            #"{"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#
                .utf8
        )
        let decoded = try decoder.decode(SessionTreeEntry.self, from: json)
        #expect(decoded.seq == nil)
        #expect(decoded.elapsedMs == nil)
        #expect(decoded.id == "m1")
        #expect(decoded.payload == .message(.user("hello")))
    }

    @Test("only one of the two fields present decodes independently")
    func partiallyPopulatedLineDecodes() throws {
        let seqOnly = Data(
            #"{"type":"session_info","id":"s1","parentId":null,"timestamp":"t","name":"n","seq":3}"#.utf8
        )
        let decodedSeq = try decoder.decode(SessionTreeEntry.self, from: seqOnly)
        #expect(decodedSeq.seq == 3)
        #expect(decodedSeq.elapsedMs == nil)

        let elapsedOnly = Data(
            #"{"type":"session_info","id":"s2","parentId":null,"timestamp":"t","name":"n","elapsedMs":42}"#.utf8
        )
        let decodedElapsed = try decoder.decode(SessionTreeEntry.self, from: elapsedOnly)
        #expect(decodedElapsed.seq == nil)
        #expect(decodedElapsed.elapsedMs == 42)
    }

    @Test("an unknown extra field is ignored, so forward compatibility is field-additive")
    func unknownFieldIsIgnored() throws {
        // Complements `unknownTypeThrows`: an unknown entry TYPE is fatal, an
        // unknown FIELD is not. That asymmetry is the whole forward-compatibility
        // story for this format and nothing pinned it before.
        let json = Data(
            #"{"type":"session_info","id":"f1","parentId":null,"timestamp":"t","name":"n","seq":2,"thinkingLevel":"high","extra":{"nested":[1,2]}}"#
                .utf8
        )
        let decoded = try decoder.decode(SessionTreeEntry.self, from: json)
        #expect(decoded.id == "f1")
        #expect(decoded.seq == 2)
        if case .sessionInfo(let name) = decoded.payload {
            #expect(name == "n")
        } else {
            Issue.record("expected sessionInfo payload")
        }
    }

    @Test("seq and elapsedMs participate in equality, so a mismatch is not silently equal")
    func fieldsAffectEquality() {
        let base = SessionTreeEntry(id: "e", parentId: nil, timestamp: "t", payload: .sessionInfo(name: nil))
        let withSeq = SessionTreeEntry(
            id: "e",
            parentId: nil,
            timestamp: "t",
            payload: .sessionInfo(name: nil),
            seq: 0
        )
        let withElapsed = SessionTreeEntry(
            id: "e",
            parentId: nil,
            timestamp: "t",
            payload: .sessionInfo(name: nil),
            elapsedMs: 0
        )
        #expect(base != withSeq)
        #expect(base != withElapsed)
        #expect(withSeq != withElapsed)
    }
}
