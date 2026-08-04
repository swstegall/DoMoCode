// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import Testing

@Suite("Resource reload coordination", .serialized)
struct ResourceReloadTests {
    @Test("events coalesce and touching an active snapshot requires a prompt")
    func coalescesDuringTurn() async throws {
        let coordinator = ResourceReloadCoordinator(debounceMilliseconds: 60_000)
        let snapshot = try await coordinator.beginTurn(
            id: "turn-1",
            resourceIDs: ["skill-review"]
        )
        #expect(snapshot.generation == 0)

        await coordinator.observe(ResourceReloadEvent(
            path: "/project/.domocode/skills/review.md",
            kind: .skill,
            resourceID: "skill-review",
            contentDigest: "old",
            observedAt: "1"
        ))
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/.domocode/skills/review.md",
            kind: .skill,
            resourceID: "skill-review",
            contentDigest: "new",
            observedAt: "2"
        ))
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/.domocode/themes/dark.json",
            kind: .theme,
            resourceID: "theme-dark",
            observedAt: "2"
        ))

        let notice = try #require(await coordinator.flush())
        #expect(notice.generation == 1)
        #expect(notice.changes.count == 2)
        #expect(notice.changes.first?.contentDigest == "new")
        #expect(notice.requiresPrompt)
        #expect(notice.activeTurnID == "turn-1")
        #expect(await coordinator.currentGeneration() == 1)
    }

    @Test("changes outside the active snapshot can reload without interrupting it")
    func ignoresUnrelatedResourceForPromptBoundary() async throws {
        let coordinator = ResourceReloadCoordinator(debounceMilliseconds: 60_000)
        _ = try await coordinator.beginTurn(id: "turn-2", resourceIDs: ["skill-review"])
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/.domocode/themes/dark.json",
            kind: .theme,
            resourceID: "theme-dark",
            observedAt: "3"
        ))

        let notice = try #require(await coordinator.flush())
        #expect(!notice.requiresPrompt)
        #expect(notice.activeTurnID == nil)
    }

    @Test("cancellation removes pending changes and late debounce work")
    func cancellationIsQuiet() async throws {
        let notices = NoticeSink()
        let coordinator = ResourceReloadCoordinator(
            debounceMilliseconds: 1,
            onNotice: { notice in await notices.append(notice) }
        )
        await coordinator.observe(ResourceReloadEvent(
            path: "/project/file.swift",
            kind: .workspace,
            observedAt: "4"
        ))
        await coordinator.cancelPending()
        #expect(await coordinator.flush() == nil)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await notices.values.isEmpty)
    }

    @Test("turn ownership is explicit")
    func turnOwnership() async throws {
        let coordinator = ResourceReloadCoordinator(debounceMilliseconds: 60_000)
        _ = try await coordinator.beginTurn(id: "turn-3")
        await #expect(throws: ResourceReloadError.turnAlreadyActive("turn-3")) {
            _ = try await coordinator.beginTurn(id: "turn-4")
        }
        await #expect(throws: ResourceReloadError.wrongTurn("turn-4")) {
            try await coordinator.endTurn(id: "turn-4")
        }
        try await coordinator.endTurn(id: "turn-3")
        await #expect(throws: ResourceReloadError.noActiveTurn) {
            try await coordinator.endTurn(id: "turn-3")
        }
    }
}

private actor NoticeSink {
    private(set) var values: [ResourceReloadNotice] = []

    func append(_ notice: ResourceReloadNotice) {
        values.append(notice)
    }
}
