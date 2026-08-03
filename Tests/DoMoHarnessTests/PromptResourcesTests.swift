import DoMoHarness
import Foundation
import SystemPackage
import Testing

@Suite("Prompt resources", .serialized)
struct PromptResourcesTests {
    @Test("built-in context controls are advertised as local commands")
    func builtInContextCommands() {
        #expect(CommandRegistry.builtIn.command(named: "compact")?.action == .compact)
        #expect(CommandRegistry.builtIn.command(named: "context")?.action == .context)
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
        #expect(workspace.baseSystemPrompt.contains("Be precise about this repository."))
        #expect(workspace.baseSystemPrompt.contains("Use the project vocabulary."))
        #expect(workspace.systemPrompt(for: "review this Swift concurrency code").contains("actor isolation"))
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
}
