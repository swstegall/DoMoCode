import DoMoHarness
import DoMoPermissions
import Foundation
import SystemPackage
import Testing

@Suite("Prompt resources", .serialized)
struct PromptResourcesTests {
    @Test("built-in context controls are advertised as local commands")
    func builtInContextCommands() {
        #expect(CommandRegistry.builtIn.command(named: "compact")?.action == .compact)
        #expect(CommandRegistry.builtIn.command(named: "context")?.action == .context)
        #expect(CommandRegistry.builtIn.command(named: "memory")?.action == .memory)
        #expect(CommandRegistry.builtIn.command(named: "research")?.action == .workflow)
        #expect(CommandRegistry.builtIn.command(named: "synthesize")?.action == .workflow)
    }

    private func makeDirectory() throws -> FilePath {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("domocode-prompts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return FilePath(path.path)
    }

    private func write(_ text: String, to path: FilePath) throws {
        let parent = path.removingLastComponent()
        try FileManager.default.createDirectory(atPath: parent.string, withIntermediateDirectories: true)
        try text.write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    @Test("the builder loads instructions, skills, and project commands")
    func loadsWorkspaceResources() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write("Be precise about this repository.\n", to: project.appending("AGENTS.md"))
        try write("Use the project vocabulary.\n", to: project.appending("SYSTEM.md"))
        try write(
            """
            ---
            description: Swift review guidance
            keywords:
              - swift
              - concurrency
            ---
            Check actor isolation and cancellation paths.
            """,
            to: project.appending(".agents").appending("skills").appending("swift").appending("SKILL.md")
        )
        try write(
            """
            ---
            description: Project review command
            argument-hint: [focus]
            ---
            Review the changed files. Focus on $ARGUMENTS.
            """,
            to: project.appending(".domocode").appending("commands").appending("review.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: ["read"],
            projectTrusted: true
        ).build()
        #expect(workspace.commands.command(named: "review")?.description == "Project review command")
        // The unquoted [focus] spelling is a YAML flow sequence; the display
        // form is rebuilt.
        #expect(workspace.commands.command(named: "review")?.argumentHint == "[focus]")
        #expect(workspace.baseSystemPrompt.contains("Be precise about this repository."))
        #expect(workspace.baseSystemPrompt.contains("Use the project vocabulary."))
        #expect(workspace.systemPrompt(for: "review this Swift concurrency code").contains("actor isolation"))
    }

    @Test("agent files layer builtin, user, and trusted project values")
    func layersAgentProfiles() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            name: reviewer
            description: User reviewer
            model: user-model
            ---
            User persona.
            """,
            to: config.appending("agents").appending("reviewer.md")
        )
        try write(
            """
            ---
            name: reviewer
            description: Project reviewer
            model: project-model
            mode: plan
            permissions:
              - permission: write
                pattern: "*"
                action: allow
            ---
            Project persona.
            """,
            to: project.appending(".domocode").appending("agents").appending("reviewer.md")
        )

        let untrusted = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: false
        ).build()
        #expect(untrusted.agents.profile(named: "plan")?.mode == .plan)
        #expect(untrusted.agents.profile(named: "reviewer")?.model == "user-model")
        #expect(untrusted.agents.profile(named: "reviewer")?.source == .user)

        let trusted = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let reviewer = try #require(trusted.agents.profile(named: "reviewer"))
        #expect(reviewer.model == "project-model")
        #expect(reviewer.mode == .plan)
        #expect(reviewer.permissionRules == [
            PermissionRule(permission: "write", pattern: "*", action: .allow)
        ])
        let selected = try #require(trusted.selecting(agent: "reviewer"))
        #expect(selected.systemPrompt(for: "inspect").contains("<agent name=\"reviewer\">"))
        #expect(selected.systemPrompt(for: "inspect").contains("Project persona."))
    }

    @Test("command templates support arguments, defaults, and file inclusion")
    func expandsTemplateGrammar() async throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write("contents from notes\n", to: project.appending("notes.txt"))
        try write(
            "Read @notes.txt for $1; remaining ${2:-fallback}. All: $ARGUMENTS",
            to: project.appending(".domocode").appending("commands").appending("inspect.md")
        )
        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let processor = PromptCommandProcessor(workspace: workspace, workingDirectory: project)
        let resolution = try await processor.resolve("/inspect first second third")
        guard case .prompt(let text, _, _, _) = resolution else {
            Issue.record("expected a prompt resolution")
            return
        }
        #expect(text.contains("contents from notes"))
        #expect(text.contains("first"))
        #expect(text.contains("second third"))
        #expect(text.contains("All: first second third"))
    }

    @Test("inline shell expansion is trust-gated")
    func shellExpansionRequiresTrust() async throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write("Value: !`printf safe`", to: project.appending(".domocode").appending("commands").appending("shell.md"))
        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let processor = PromptCommandProcessor(workspace: workspace, workingDirectory: project)
        do {
            _ = try await processor.resolve("/shell")
            Issue.record("untrusted inline shell unexpectedly ran")
        } catch let error as PromptResourceError {
            #expect(error == .shellNotTrusted)
        }
    }

    @Test("skills, agents, and commands load from a trusted .github root")
    func loadsResourcesFromGitHubRoot() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            name: review-notes
            description: Structured review notes
            keywords:
              - stylecheck
            ---
            Collect findings as severity, location, evidence.
            """,
            to: project.appending(".github").appending("skills").appending("review-notes").appending("SKILL.md")
        )
        try write(
            """
            ---
            description: Triage an issue report
            ---
            Summarize the report and label it.
            """,
            to: project.appending(".github").appending("commands").appending("triage.md")
        )
        try write("Plan before editing.", to: project.appending(".github").appending("agents").appending("planner.md"))
        try write(
            """
            ---
            keywords:
              - flatword
            ---
            Flat-file skills load too.
            """,
            to: project.appending(".github").appending("skills").appending("field-notes.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let skill = try #require(workspace.skills.first { $0.name == "review-notes" })
        #expect(skill.source == .project)
        #expect(workspace.systemPrompt(for: "run a stylecheck pass").contains("severity, location, evidence"))
        #expect(workspace.commands.command(named: "triage")?.source == .project)
        #expect(workspace.agents.profile(named: "planner")?.systemPrompt == "Plan before editing.")
        #expect(workspace.skills.contains { $0.name == "field-notes" })
        #expect(workspace.systemPrompt(for: "check flatword here").contains("Flat-file skills load too."))
    }

    @Test("an untrusted project loads nothing from .github")
    func ignoresGitHubRootWithoutTrust() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            "Collect findings as severity, location, evidence.",
            to: project.appending(".github").appending("skills").appending("review-notes").appending("SKILL.md")
        )
        try write("Plan before editing.", to: project.appending(".github").appending("agents").appending("planner.md"))

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: false
        ).build()
        #expect(!workspace.skills.contains { $0.name == "review-notes" })
        #expect(workspace.agents.profile(named: "planner") == nil)
    }

    @Test("a .agent.md filename names the profile without the suffix")
    func agentSuffixIsStrippedFromTheFallbackName() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            "Coordinate the phases end to end.",
            to: project.appending(".github").appending("agents").appending("flow-lead.agent.md")
        )
        try write(
            """
            ---
            name: baz
            ---
            Named by frontmatter, not filename.
            """,
            to: project.appending(".github").appending("agents").appending("bar.agent.md")
        )

        // The `.agent` convention is a profile-filename rule only: commands
        // and skills keep their full stem.
        try write(
            "Release with the checklist.",
            to: project.appending(".github").appending("commands").appending("release.agent.md")
        )
        try write(
            "Skills keep the stem.",
            to: project.appending(".github").appending("skills").appending("notes.agent.md")
        )
        // A same-stem pair collapses to one name; the plain file wins the
        // registry's last-write-wins fold (sorted enumeration puts it last).
        try write("Dual: suffixed copy.", to: project.appending(".github").appending("agents").appending("dual.agent.md"))
        try write("Dual: plain copy.", to: project.appending(".github").appending("agents").appending("dual.md"))
        // A file named exactly `.agent.md` keeps its `.agent` stem.
        try write("Bare suffix file.", to: project.appending(".github").appending("agents").appending(".agent.md"))

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        #expect(workspace.agents.profile(named: "flow-lead")?.systemPrompt == "Coordinate the phases end to end.")
        #expect(workspace.agents.profile(named: "flow-lead.agent") == nil)
        #expect(workspace.agents.profile(named: "baz")?.systemPrompt == "Named by frontmatter, not filename.")
        #expect(workspace.agents.profile(named: "bar") == nil)
        #expect(workspace.agents.profile(named: "bar.agent") == nil)
        #expect(workspace.commands.command(named: "release.agent") != nil)
        #expect(workspace.commands.command(named: "release") == nil)
        #expect(workspace.skills.contains { $0.name == "notes.agent" })
        #expect(!workspace.skills.contains { $0.name == "notes" })
        #expect(workspace.agents.profile(named: "dual")?.systemPrompt == "Dual: plain copy.")
        #expect(workspace.agents.profile(named: "dual.agent") == nil)
        #expect(workspace.agents.profile(named: ".agent")?.systemPrompt == "Bare suffix file.")
    }

    @Test("disable-model-invocation suppresses keyword injection but not the catalogue")
    func disableModelInvocationSuppressesKeywordInjection() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            description: User-invoked checklist
            keywords:
              - quietword
            disable-model-invocation: true
            ---
            The quiet body must not be injected.
            """,
            to: project.appending(".github").appending("skills").appending("quiet").appending("SKILL.md")
        )
        try write(
            """
            ---
            description: Keyword-triggered checklist
            keywords:
              - loudword
            ---
            The loud body is injected on a match.
            """,
            to: project.appending(".github").appending("skills").appending("loud").appending("SKILL.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let quiet = try #require(workspace.skills.first { $0.name == "quiet" })
        #expect(quiet.disableModelInvocation)
        #expect(workspace.baseSystemPrompt.contains("- quiet: User-invoked checklist (not model-invocable)"))
        #expect(workspace.baseSystemPrompt.contains("- loud: Keyword-triggered checklist\n"))
        #expect(!workspace.systemPrompt(for: "please quietword now").contains("The quiet body must not be injected."))
        #expect(workspace.systemPrompt(for: "please loudword now").contains("The loud body is injected on a match."))
    }

    @Test("disable-model-invocation accepts camelCase and truthy scalar spellings")
    func disableModelInvocationAcceptsTruthySpellings() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        let spellings = [
            ("camel", "disableModelInvocation: true"),
            ("snake", "disable_model_invocation: true"),
            ("quoted", "disable-model-invocation: \"yes\""),
            ("numeric", "disable-model-invocation: 1"),
            // A restriction key that is present but unparseable fails closed.
            ("unparseable", "disable-model-invocation: maybe"),
        ]
        for (name, line) in spellings {
            try write(
                """
                ---
                keywords:
                  - marker-\(name)
                \(line)
                ---
                Body for \(name).
                """,
                to: project.appending(".domocode").appending("skills").appending(name).appending("SKILL.md")
            )
        }
        try write(
            """
            ---
            keywords:
              - marker-off
            disable-model-invocation: false
            ---
            Body for the explicit false control.
            """,
            to: project.appending(".domocode").appending("skills").appending("control").appending("SKILL.md")
        )
        try write(
            """
            ---
            keywords:
              - marker-quoted-no
            disable-model-invocation: "no"
            ---
            Body for the quoted falsy control.
            """,
            to: project.appending(".domocode").appending("skills").appending("quoted-no").appending("SKILL.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        for (name, _) in spellings {
            let skill = try #require(workspace.skills.first { $0.name == name })
            #expect(skill.disableModelInvocation, "spelling \(name) should disable injection")
            #expect(!workspace.systemPrompt(for: "hit marker-\(name)").contains("Body for \(name)."))
        }
        #expect(workspace.systemPrompt(for: "hit marker-off").contains("Body for the explicit false control."))
        #expect(workspace.systemPrompt(for: "hit marker-quoted-no").contains("Body for the quoted falsy control."))
    }

    @Test("a tools list round-trips verbatim, a mapping reduces to sorted truthy names; absence stays nil")
    func parsesToolsAllowlistVerbatim() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            tools: ['vscode', 'execute', 'read', 'agent', 'edit', 'search', 'web', 'todo', 'mcp', 'tracker-mcp-server/*']
            ---
            Orchestrate with the declared tools only.
            """,
            to: project.appending(".github").appending("agents").appending("flow-lead.agent.md")
        )
        try write(
            """
            ---
            tools: mcp
            ---
            A scalar becomes a one-element list.
            """,
            to: project.appending(".github").appending("skills").appending("scalar-tools").appending("SKILL.md")
        )
        try write(
            """
            ---
            tools: []
            ---
            A declared empty list is not the same as no list.
            """,
            to: project.appending(".github").appending("agents").appending("locked-down.agent.md")
        )
        try write("No tools key at all.", to: project.appending(".github").appending("agents").appending("plain.md"))
        try write(
            """
            ---
            tools:
            ---
            A declared key with a blank value is empty, not absent.
            """,
            to: project.appending(".github").appending("agents").appending("blank-tools.md")
        )
        try write(
            """
            ---
            tools: [web, on, 42]
            ---
            Unquoted names that YAML 1.1 would type stay literal text.
            """,
            to: project.appending(".github").appending("agents").appending("literal-tools.md")
        )
        try write(
            """
            ---
            base: &common
              tools: [read, on]
            <<: *common
            ---
            A list supplied through a YAML merge key still counts, verbatim.
            """,
            to: project.appending(".github").appending("agents").appending("merged-tools.md")
        )
        try write(
            """
            ---
            tools:
              write: true
              edit: false
              search: "on"
              weird: maybe
            ---
            Mapping spelling keeps the truthy names, sorted; unrecognizable flags exclude.
            """,
            to: project.appending(".github").appending("agents").appending("mapped-tools.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let flowLead = try #require(workspace.agents.profile(named: "flow-lead"))
        #expect(flowLead.toolAllowlist == [
            "vscode", "execute", "read", "agent", "edit", "search", "web", "todo", "mcp", "tracker-mcp-server/*",
        ])
        let scalar = try #require(workspace.skills.first { $0.name == "scalar-tools" })
        #expect(scalar.toolAllowlist == ["mcp"])
        #expect(try #require(workspace.agents.profile(named: "locked-down")).toolAllowlist == [])
        #expect(try #require(workspace.agents.profile(named: "plain")).toolAllowlist == nil)
        #expect(try #require(workspace.agents.profile(named: "blank-tools")).toolAllowlist == [])
        #expect(try #require(workspace.agents.profile(named: "literal-tools")).toolAllowlist == ["web", "on", "42"])
        #expect(try #require(workspace.agents.profile(named: "merged-tools")).toolAllowlist == ["read", "on"])
        #expect(try #require(workspace.agents.profile(named: "mapped-tools")).toolAllowlist == ["search", "write"])
    }

    @Test("an unparseable disable-model-invocation spelling fails closed even beside a parseable one")
    func unparseableRestrictionSpellingFailsClosed() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            keywords:
              - mixedword
            disable-model-invocation: false
            disableModelInvocation: maybe
            ---
            The mixed-spelling body must stay withheld.
            """,
            to: project.appending(".domocode").appending("skills").appending("mixed").appending("SKILL.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let mixed = try #require(workspace.skills.first { $0.name == "mixed" })
        #expect(mixed.disableModelInvocation)
        #expect(!workspace.systemPrompt(for: "hit mixedword").contains("The mixed-spelling body must stay withheld."))
        #expect(!workspace.hasModelInvocableSkills)

        let served = PromptWorkspace(
            baseSystemPrompt: "",
            commands: .builtIn,
            skills: [
                PromptSkill(name: "served", body: "Served."),
                PromptSkill(name: "withheld", body: "Withheld.", disableModelInvocation: true),
            ]
        )
        #expect(served.hasModelInvocableSkills)
    }

    @Test("a .domocode resource overrides a same-named .github resource")
    func domocodeRootOverridesGitHubRoot() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            description: Vendored pack copy
            keywords:
              - sharedword
            ---
            The vendored body loses the collision.
            """,
            to: project.appending(".github").appending("skills").appending("shared").appending("SKILL.md")
        )
        try write(
            """
            ---
            description: Repo-local override
            keywords:
              - sharedword
            ---
            The repo-local body wins the collision.
            """,
            to: project.appending(".domocode").appending("skills").appending("shared").appending("SKILL.md")
        )
        // Every DoMoCode-native root must outrank .github, not just .domocode.
        for (root, marker) in [(".claude", "claudeword"), (".agents", "agentsword")] {
            try write(
                """
                ---
                keywords:
                  - \(marker)
                ---
                The vendored \(marker) body loses.
                """,
                to: project.appending(".github").appending("skills").appending("shared-\(marker)").appending("SKILL.md")
            )
            try write(
                """
                ---
                keywords:
                  - \(marker)
                ---
                The \(root) \(marker) body wins.
                """,
                to: project.appending(root).appending("skills").appending("shared-\(marker)").appending("SKILL.md")
            )
        }

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let shared = try #require(workspace.skills.first { $0.name == "shared" })
        #expect(shared.description == "Repo-local override")
        #expect(workspace.systemPrompt(for: "use sharedword").contains("The repo-local body wins the collision."))
        #expect(!workspace.systemPrompt(for: "use sharedword").contains("The vendored body loses the collision."))
        for (root, marker) in [(".claude", "claudeword"), (".agents", "agentsword")] {
            #expect(workspace.systemPrompt(for: "use \(marker)").contains("The \(root) \(marker) body wins."))
            #expect(!workspace.systemPrompt(for: "use \(marker)").contains("The vendored \(marker) body loses."))
        }
    }

    @Test("skills are promoted to user-invocable prompt commands")
    func skillsArePromotedToCommands() async throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            description: Vendor the shared checklists
            argument-hint: [target-repo]
            disable-model-invocation: true
            ---
            Copy each checklist into the target repository.
            """,
            to: project.appending(".github").appending("skills").appending("setup-notes").appending("SKILL.md")
        )
        try write(
            """
            ---
            argument-hint: "add [item] | remove [item]"
            ---
            User-scope skills promote too.
            """,
            to: config.appending("skills").appending("user-notes").appending("SKILL.md")
        )
        try write(
            """
            ---
            description: Frontmatter-only stub
            ---
            """,
            to: project.appending(".github").appending("skills").appending("stub").appending("SKILL.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let promoted = try #require(workspace.commands.command(named: "setup-notes"))
        #expect(promoted.kind == .prompt)
        #expect(promoted.description == "Vendor the shared checklists")
        #expect(promoted.argumentHint == "[target-repo]")
        #expect(promoted.source == .project)
        #expect(workspace.commands.command(named: "user-notes")?.source == .user)
        // A quoted argument-hint string passes through unchanged.
        #expect(workspace.commands.command(named: "user-notes")?.argumentHint == "add [item] | remove [item]")
        // A frontmatter-only skill has nothing to inject and is not promoted,
        // but it stays a skill.
        #expect(workspace.commands.command(named: "stub") == nil)
        #expect(workspace.skills.contains { $0.name == "stub" })

        let processor = PromptCommandProcessor(workspace: workspace, workingDirectory: project)
        let resolution = try await processor.resolve("/setup-notes acme-app")
        guard case .prompt(let text, _, _, _) = resolution else {
            Issue.record("expected a prompt resolution")
            return
        }
        #expect(text == "Copy each checklist into the target repository.\n\nacme-app")
    }

    @Test("a promoted skill body is inert prose, injected once")
    func promotedSkillBodyIsInertProse() async throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write("readable project file\n", to: project.appending("README.md"))
        try write(
            """
            Never run !`rm -rf /` here. See @README.md for context.
            Use awk '{print $0}' with $1 and ${2} and $ARGUMENTS as literals.
            """,
            to: project.appending(".github").appending("skills").appending("field-guide").appending("SKILL.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let processor = PromptCommandProcessor(workspace: workspace, workingDirectory: project)
        let resolution = try await processor.resolve("/field-guide check the guide")
        guard case .prompt(let text, _, _, let systemPrompt) = resolution else {
            Issue.record("expected a prompt resolution")
            return
        }
        // The body survives verbatim: no shell ran, no file was inlined, no
        // argument substitution rewrote the examples.
        #expect(text.contains("!`rm -rf /`"))
        #expect(text.contains("See @README.md for context."))
        #expect(!text.contains("readable project file"))
        #expect(text.contains("awk '{print $0}' with $1 and ${2} and $ARGUMENTS as literals."))
        #expect(text.hasSuffix("\n\ncheck the guide"))
        // The invoked skill is excluded from keyword injection, so the body
        // arrives exactly once — but an ordinary prose prompt still triggers.
        #expect(!systemPrompt.contains("<active-skills>"))
        #expect(workspace.systemPrompt(for: "consult the field-guide please").contains("Never run"))
    }

    @Test("skill promotion never shadows built-ins or real command files")
    func skillPromotionNeverShadows() throws {
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        // A skill named after a built-in local command must not displace it.
        try write(
            "A skill that dares to call itself review.",
            to: project.appending(".github").appending("skills").appending("review").appending("SKILL.md")
        )
        // A same-named real command file must win over the promoted skill.
        try write(
            "Skill body that loses the collision.",
            to: project.appending(".github").appending("skills").appending("triage").appending("SKILL.md")
        )
        try write(
            """
            ---
            description: Real command file
            ---
            Command template that wins the collision.
            """,
            to: project.appending(".domocode").appending("commands").appending("triage.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        #expect(workspace.commands.command(named: "review")?.kind == .local)
        #expect(workspace.commands.command(named: "review")?.action == .review)
        #expect(workspace.commands.command(named: "triage")?.description == "Real command file")
        // Both skills still exist as skills; only the command surface defers.
        #expect(workspace.skills.contains { $0.name == "review" })
        #expect(workspace.skills.contains { $0.name == "triage" })
    }

    @Test("a trusted project .github resource overrides a user-scope one")
    func projectGitHubOverridesUserScope() throws {
        // DoMoCode layers builtin < user < project everywhere (see
        // layersAgentProfiles above); .github joins the project layer, so it
        // outranks the user config directory like any other project root.
        let project = try makeDirectory()
        let config = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: project.string)
            try? FileManager.default.removeItem(atPath: config.string)
        }
        try write(
            """
            ---
            description: User-scope copy
            ---
            The user-scope body loses to the project.
            """,
            to: config.appending("skills").appending("shared").appending("SKILL.md")
        )
        try write(
            """
            ---
            description: Project pack copy
            ---
            The project body wins over user scope.
            """,
            to: project.appending(".github").appending("skills").appending("shared").appending("SKILL.md")
        )

        let workspace = try SystemPromptBuilder(
            workingDirectory: project,
            configDirectory: config,
            toolNames: [],
            projectTrusted: true
        ).build()
        let shared = try #require(workspace.skills.first { $0.name == "shared" })
        #expect(shared.description == "Project pack copy")
        #expect(shared.source == .project)
    }
}
