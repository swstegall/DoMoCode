// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoHarness
import Testing

@testable import DoMoCLI

@Suite("Skill provider")
struct SkillProviderTests {
    @Test("the model-facing provider omits skills marked disable-model-invocation")
    func providerOmitsDisabledSkills() async throws {
        let workspace = PromptWorkspace(
            baseSystemPrompt: "",
            commands: .builtIn,
            skills: [
                PromptSkill(name: "served", body: "Served body."),
                PromptSkill(name: "withheld", body: "Withheld body.", disableModelInvocation: true),
            ]
        )
        let provider = makeSkillProvider(workspace)
        #expect(await provider("served")?.body == "Served body.")
        #expect(await provider("withheld") == nil)
        #expect(await provider("WITHHELD") == nil)
    }
}
