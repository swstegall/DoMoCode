// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoHarness
import DoMoLLM
import Foundation
import Testing

@Suite("Session metadata")
struct SessionMetadataTests {
    @Test("the latest session_info update can explicitly clear an older name")
    func latestNamePreservesClear() {
        let entries = [
            SessionTreeEntry(
                id: "named",
                parentId: nil,
                timestamp: "t1",
                payload: .sessionInfo(name: "Old title")
            ),
            SessionTreeEntry(
                id: "cleared",
                parentId: "named",
                timestamp: "t2",
                payload: .sessionInfo(name: nil)
            ),
        ]

        #expect(SessionTree.latestSessionName(in: entries) == nil)
    }

    @Test("a later session_info name replaces an earlier clear")
    func latestNameCanBeRestored() {
        let entries = [
            SessionTreeEntry(
                id: "cleared",
                parentId: nil,
                timestamp: "t1",
                payload: .sessionInfo(name: nil)
            ),
            SessionTreeEntry(
                id: "named",
                parentId: "cleared",
                timestamp: "t2",
                payload: .sessionInfo(name: "New title")
            ),
        ]

        #expect(SessionTree.latestSessionName(in: entries) == "New title")
    }

    @Test("an auto-title usage value round-trips on session_info")
    func titleUsageRoundTrips() throws {
        let usage = Usage(input: 12, output: 4)
        let entry = SessionTreeEntry(
            id: "title",
            parentId: nil,
            timestamp: "t",
            payload: .sessionInfo(name: "A useful title"),
            metadataUsage: usage
        )
        let data = try JSONEncoder().encode(entry)
        #expect(String(decoding: data, as: UTF8.self).contains("\"usage\""))
        let decoded = try JSONDecoder().decode(SessionTreeEntry.self, from: data)
        #expect(decoded == entry)
        #expect(decoded.metadataUsage == usage)
    }
}
