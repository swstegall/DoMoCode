// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

import DoMoCore

@Suite("subagent contract")
struct SubagentTests {
    @Test("request result and lifecycle event round trip through Codable")
    func codableRoundTrip() throws {
        let request = SubagentTaskRequest(
            taskID: "task-1",
            parentSessionID: "parent",
            prompt: "inspect the parser",
            agent: "explore",
            background: true
        )
        let result = SubagentTaskResult(
            taskID: request.taskID,
            childSessionID: "child",
            status: .completed,
            output: "looks good"
        )
        let event = SubagentTaskEvent(
            taskID: request.taskID,
            childSessionID: "child",
            parentSessionID: request.parentSessionID,
            description: request.prompt,
            agent: request.agent,
            status: .completed,
            output: result.output,
            depth: 1
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SubagentTaskRequest.self, from: encoder.encode(request)) == request)
        #expect(try decoder.decode(SubagentTaskResult.self, from: encoder.encode(result)) == result)
        #expect(try decoder.decode(SubagentTaskEvent.self, from: encoder.encode(event)) == event)
    }

    @Test("coordinator forwards requests and lifecycle events")
    func coordinatorBridge() async {
        let coordinator = SubagentCoordinator()
        let emitted = Mutex<[SubagentTaskEvent]>([])
        coordinator.setRunner { request in
            SubagentTaskResult(
                taskID: request.taskID,
                childSessionID: "child",
                status: .completed,
                output: request.prompt
            )
        }
        coordinator.setEmitter { event in
            emitted.withLock { $0.append(event) }
        }

        let request = SubagentTaskRequest(taskID: "task-2", parentSessionID: "parent", prompt: "search")
        let result = await coordinator.run(request)
        let event = SubagentTaskEvent(
            taskID: request.taskID,
            childSessionID: result.childSessionID ?? "",
            parentSessionID: request.parentSessionID,
            description: request.prompt,
            status: result.status,
            output: result.output,
            depth: 0
        )
        await coordinator.emit(event)

        #expect(result.output == "search")
        #expect(emitted.withLock { $0 } == [event])
    }
}
