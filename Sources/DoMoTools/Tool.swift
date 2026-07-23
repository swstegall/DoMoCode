// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/coding-agent/src/core/tools/index.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
//
// The tool surface — the seven built-in tools, their names, descriptions and
// parameter schemas — is ported from `packages/coding-agent/src/core/tools/`.
// The `ToolDefinition` shape (name/description/parameters/execute returning
// content plus structured details) is from `core/extensions/types.ts`; the
// byte/line truncation helpers from `tools/truncate.ts`.

import DoMoCore
import DoMoExec
import Foundation
import SystemPackage

// MARK: - Result

/// One block of a tool result: text the model reads, or an image attachment.
///
/// Mirrors pi's `content: (TextContent | ImageContent)[]`. Images exist because
/// ``ReadTool`` returns a supported image as an attachment rather than as a wall
/// of decoded bytes.
public enum ToolContent: Sendable, Hashable {
    case text(String)
    case image(mediaType: String, data: Data)
}

/// What a tool produced.
///
/// ## Errors are results, not throws
///
/// A tool failure the model should see and correct — a missing file, an
/// ambiguous edit, a bad argument — comes back as ``ToolResult`` with
/// ``isError`` set, never as a thrown Swift error. pi's tools `throw` and let
/// the agent loop turn the throw into an error tool result; the same effect is
/// achieved here by returning the error result directly, which keeps a bad
/// argument from ever escaping as an exception that could end the turn. The one
/// thing that *does* throw out of ``Tool/execute(_:in:)`` is
/// ``DoMoError/Kind/cancelled``, because a cancelled turn is not a tool result.
///
/// ``details`` carries structured data for the renderer in DoMoToolsUI — diffs,
/// truncation metadata, match counts — kept separate from ``content`` so this
/// module never has to know how any of it is drawn.
public struct ToolResult: Sendable, Hashable {
    public var content: [ToolContent]
    public var isError: Bool
    public var details: JSONValue

    public init(content: [ToolContent], isError: Bool = false, details: JSONValue = .null) {
        self.content = content
        self.isError = isError
        self.details = details
    }

    /// The concatenation of every text block — what the model reads.
    public var text: String {
        content.compactMap {
            if case .text(let value) = $0 { return value }
            return nil
        }
        .joined(separator: "\n")
    }

    /// The image attachments, in order.
    public var images: [(mediaType: String, data: Data)] {
        content.compactMap {
            if case .image(let mediaType, let data) = $0 { return (mediaType, data) }
            return nil
        }
    }

    public static func text(_ text: String, details: JSONValue = .null) -> ToolResult {
        ToolResult(content: [.text(text)], isError: false, details: details)
    }

    /// An error result the model is expected to read and recover from.
    public static func error(_ message: String, details: JSONValue = .null) -> ToolResult {
        ToolResult(content: [.text(message)], isError: true, details: details)
    }

    /// Turns a ``DoMoError`` into an error result, using its full cause chain as
    /// the message.
    public static func failure(_ error: DoMoError) -> ToolResult {
        ToolResult(content: [.text(error.description)], isError: true)
    }

    /// Runs `body`, converting any non-cancellation failure it throws into an
    /// error result. Cancellation is re-thrown as ``DoMoError/Kind/cancelled``,
    /// because a cancelled turn is not something to feed back to the model.
    ///
    /// This is the invariant that makes ``isError`` — rather than a throw — the
    /// tool failure channel: every path a built-in tool takes runs inside one of
    /// these. The closure is untyped-throws (`throws`, not `throws(DoMoError)`)
    /// because a multi-statement closure does not reliably infer its thrown type
    /// from a typed-throws parameter; catching `any Error` here costs nothing,
    /// since the built-in tools only ever throw ``DoMoError`` anyway.
    static func capturing(
        tool: String,
        _ body: () async throws -> ToolResult
    ) async throws(DoMoError) -> ToolResult {
        do {
            return try await body()
        } catch let error as DoMoError {
            if error.isCancellation { throw error }
            return ToolResult.failure(error)
        } catch is CancellationError {
            throw DoMoError(.cancelled, "\(tool) cancelled")
        } catch {
            return ToolResult.failure(
                DoMoError(wrapping: error, as: .toolExecution(tool: tool), "\(tool) failed")
            )
        }
    }
}

// MARK: - Tool

/// A model-callable tool.
///
/// `@concurrent` on ``execute(_:in:)`` because this protocol is a module seam:
/// the agent loop dispatches tools from whatever actor it runs on, and file I/O
/// and subprocesses must not ride the caller's actor. See the README,
/// "Concurrency and isolation".
public protocol Tool: Sendable {
    /// The name the model calls, e.g. `read`. Stable — it is part of the wire
    /// contract with the model.
    var name: String { get }

    /// The description the model reads. The single highest-leverage string in a
    /// tool definition; ported verbatim from pi, whose wording is tuned.
    var description: String { get }

    /// The parameter schema, as DoMoCore's ``JSONSchema``.
    var parameters: JSONSchema { get }

    /// Runs the tool against raw, undecoded arguments.
    ///
    /// `arguments` is whatever the model sent — possibly the wrong shape, missing
    /// fields, or carrying extras. Decoding is the tool's own job and every
    /// decoding failure is a ``ToolResult`` with ``ToolResult/isError``, not a
    /// throw. Only ``DoMoError/Kind/cancelled`` escapes.
    @concurrent
    func execute(_ arguments: JSONValue, in context: ToolContext) async throws(DoMoError) -> ToolResult
}

// MARK: - Registry

/// The set of tools available to a turn, keyed by name.
public struct ToolRegistry: Sendable {

    private var byName: [String: any Tool]
    /// Registration order, so ``all`` and ``names`` are stable rather than
    /// hash-ordered — a tool list that reshuffles between runs breaks prompt
    /// caching.
    private var order: [String]

    public init(_ tools: [any Tool] = []) {
        self.byName = [:]
        self.order = []
        for tool in tools { register(tool) }
    }

    /// Adds a tool, replacing any existing one of the same name in place.
    public mutating func register(_ tool: any Tool) {
        if byName.updateValue(tool, forKey: tool.name) == nil {
            order.append(tool.name)
        }
    }

    public func tool(named name: String) -> (any Tool)? {
        byName[name]
    }

    public var all: [any Tool] { order.compactMap { byName[$0] } }

    public var names: [String] { order }

    /// The read/write/edit/bash set — pi's `createCodingTools`.
    public static var coding: ToolRegistry {
        ToolRegistry([ReadTool(), BashTool(), EditTool(), WriteTool()])
    }

    /// The read-only search set — pi's `createReadOnlyTools`.
    public static var readOnly: ToolRegistry {
        ToolRegistry([ReadTool(), GrepTool(), FindTool(), LsTool()])
    }

    /// All seven built-in tools.
    public static var builtin: ToolRegistry {
        ToolRegistry([ReadTool(), BashTool(), EditTool(), WriteTool(), GrepTool(), FindTool(), LsTool()])
    }

    /// Dispatches by name. An unknown name is an error result rather than a
    /// throw: the model was told which tools exist, and a call to one that does
    /// not is a mistake it can correct.
    @concurrent
    public func execute(
        _ name: String,
        arguments: JSONValue,
        in context: ToolContext
    ) async throws(DoMoError) -> ToolResult {
        guard let tool = byName[name] else {
            return ToolResult.error("Unknown tool: \(name)")
        }
        return try await tool.execute(arguments, in: context)
    }
}

// MARK: - Context

/// Everything a tool needs to touch the outside world, all of it confined to the
/// sandbox root.
///
/// ``fileSystem`` is a ``SandboxedFileSystem``, so `read`/`write`/`edit`/`ls`
/// cannot address anything outside the root — every call re-resolves through the
/// realpath sandbox. ``shell`` runs `bash`, `rg` and `fd`; the search tools
/// additionally resolve their search root through the sandbox before invoking
/// anything, so an escape attempt fails before a subprocess starts. ``mutations``
/// serializes concurrent writes to one file so a parallel `write`+`edit` in one
/// turn cannot interleave.
public struct ToolContext: Sendable {

    /// The sandboxed filesystem. All path-addressed operations go through it.
    public let fileSystem: SandboxedFileSystem

    /// Runs shell commands and the external search tools.
    public let shell: any Shell

    /// Per-path write serialization for `write` and `edit`.
    public let mutations: FileMutationCoordinator

    /// Finds `rg` and `fd` on the host. Injectable so a test can force the
    /// pure-Swift fallback path.
    public let toolLocator: ExternalToolLocator

    /// The environment `bash` runs under.
    public let environment: ShellEnvironment

    public init(
        fileSystem: SandboxedFileSystem,
        shell: any Shell,
        mutations: FileMutationCoordinator? = nil,
        toolLocator: ExternalToolLocator = .pathSearch,
        environment: ShellEnvironment = .inherit
    ) {
        self.fileSystem = fileSystem
        self.shell = shell
        self.mutations = mutations ?? FileMutationCoordinator(fileSystem: fileSystem)
        self.toolLocator = toolLocator
        self.environment = environment
    }

    /// Builds a context confined to `root`, resolving the root through the base
    /// filesystem so a symlinked root (e.g. macOS `/tmp`) contains itself.
    @concurrent
    public static func rooted(
        at root: FilePath,
        shell: any Shell,
        base: some FileSystem = POSIXFileSystem(),
        toolLocator: ExternalToolLocator = .pathSearch,
        environment: ShellEnvironment = .inherit
    ) async throws(DoMoError) -> ToolContext {
        let sandboxed = try await SandboxedFileSystem.rooted(at: root, using: base)
        return ToolContext(
            fileSystem: sandboxed,
            shell: shell,
            toolLocator: toolLocator,
            environment: environment
        )
    }

    public var sandbox: PathSandbox { fileSystem.sandbox }
    public var base: any FileSystem { fileSystem.base }
    public var workingDirectory: FilePath { fileSystem.workingDirectory }
}

// MARK: - External tool location

/// Finds an external binary such as `rg` or `fd`.
///
/// pi's `ensureTool` downloads a missing binary; nothing here does, on purpose —
/// a coding agent that silently fetches executables is a supply-chain surprise.
/// When the tool is absent the caller uses a pure-Swift fallback instead.
public struct ExternalToolLocator: Sendable {

    private let find: @Sendable (String) -> FilePath?

    public init(_ find: @escaping @Sendable (String) -> FilePath?) {
        self.find = find
    }

    /// The located path, or `nil` when the binary is not installed.
    public func locate(_ name: String) -> FilePath? { find(name) }

    /// Scans `PATH` in-process. No subprocess is spawned to find a subprocess.
    public static let pathSearch = ExternalToolLocator { name in
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = FilePath(String(directory)).appending(name)
            if FileManager.default.isExecutableFile(atPath: candidate.string) {
                return candidate
            }
        }
        return nil
    }

    /// Reports every tool as missing, forcing the fallback. For tests.
    public static let unavailable = ExternalToolLocator { _ in nil }
}

// MARK: - Argument decoding

/// Reads a tool's arguments defensively.
///
/// Models send the wrong types, omit required fields, add extras, and encode
/// numbers and booleans as strings. Every one of those is a mistake the model
/// can correct if it is told, so each failure here throws a
/// ``DoMoError/Kind/toolExecution`` whose message names the problem — and the
/// tool's ``ToolResult/capturing(_:)`` turns that throw into an error result the
/// model reads. Extra keys are simply ignored, as pi ignores them.
struct ArgumentReader {

    let tool: String
    private let object: [String: JSONValue]

    init(tool: String, arguments: JSONValue) throws(DoMoError) {
        guard case .object(let object) = arguments else {
            throw DoMoError(
                .toolExecution(tool: tool),
                "\(tool): arguments must be a JSON object"
            )
        }
        self.tool = tool
        self.object = object
    }

    /// The raw value for a key, trying each alias in turn.
    func value(_ keys: String...) -> JSONValue? {
        for key in keys {
            if let value = object[key], value != .null { return value }
        }
        return nil
    }

    func requiredString(_ keys: String...) throws(DoMoError) -> String {
        for key in keys {
            guard let value = object[key], value != .null else { continue }
            guard let string = value.stringValue else {
                throw fault("\(key) must be a string")
            }
            return string
        }
        throw fault("missing required string argument \"\(keys[0])\"")
    }

    func optionalString(_ keys: String...) throws(DoMoError) -> String? {
        for key in keys {
            guard let value = object[key], value != .null else { continue }
            guard let string = value.stringValue else {
                throw fault("\(key) must be a string")
            }
            return string
        }
        return nil
    }

    /// An optional integer, accepting an integral number or a numeric string —
    /// models routinely send `"5"` for a numeric parameter.
    func optionalInt(_ key: String) throws(DoMoError) -> Int? {
        guard let value = object[key], value != .null else { return nil }
        if let int = value.intValue { return int }
        if let string = value.stringValue, let int = Int(string.trimmingCharacters(in: .whitespaces)) {
            return int
        }
        throw fault("\(key) must be an integer")
    }

    /// An optional number, accepting a JSON number or a numeric string. Kept as
    /// `Double` for parameters like `timeout` that pi types as `Number` and may
    /// be fractional.
    func optionalDouble(_ key: String) throws(DoMoError) -> Double? {
        guard let value = object[key], value != .null else { return nil }
        if let number = value.doubleValue { return number }
        if let string = value.stringValue, let number = Double(string.trimmingCharacters(in: .whitespaces)) {
            return number
        }
        throw fault("\(key) must be a number")
    }

    /// An optional boolean, accepting `true`/`false` or the strings `"true"`/`"false"`.
    func optionalBool(_ key: String) throws(DoMoError) -> Bool? {
        guard let value = object[key], value != .null else { return nil }
        if let bool = value.boolValue { return bool }
        if let string = value.stringValue {
            switch string.lowercased() {
            case "true": return true
            case "false": return false
            default: break
            }
        }
        throw fault("\(key) must be a boolean")
    }

    /// The raw array for a key, or `nil` when absent. A present-but-non-array
    /// value is a fault.
    func optionalArray(_ key: String) throws(DoMoError) -> [JSONValue]? {
        guard let value = object[key], value != .null else { return nil }
        guard let array = value.arrayValue else {
            throw fault("\(key) must be an array")
        }
        return array
    }

    func fault(_ message: String) -> DoMoError {
        DoMoError(.toolExecution(tool: tool), "\(tool): \(message)")
    }
}

// MARK: - Truncation

/// Byte- and line-bounded truncation of tool output.
///
/// Ported from pi's `truncate.ts`. Two independent limits — 2000 lines and 50KB
/// — and whichever is hit first wins. Complete lines only: a file is never cut
/// mid-line, and a single first line that alone blows the byte budget is
/// reported specially so ``ReadTool`` can point the model at a `bash`/`sed`
/// fallback.
enum OutputTruncation {

    static let defaultMaxLines = 2000
    static let defaultMaxBytes = 50 * 1024

    enum By: Sendable, Hashable {
        case lines
        case bytes
    }

    struct Result: Sendable, Hashable {
        var content: String
        var truncated: Bool
        var truncatedBy: By?
        var totalLines: Int
        var totalBytes: Int
        var outputLines: Int
        var outputBytes: Int
        var firstLineExceedsLimit: Bool
        var maxLines: Int
        var maxBytes: Int
    }

    /// Human-readable byte size, matching pi's `formatSize` (one decimal, binary
    /// units). `51200` renders `50.0KB`.
    ///
    /// Formatted by hand rather than with `String(format:)`, whose varargs
    /// initializer is `unsafe` under `.strictMemorySafety()`.
    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes)B"
        }
        if bytes < 1024 * 1024 {
            return "\(oneDecimal(Double(bytes) / 1024))KB"
        }
        return "\(oneDecimal(Double(bytes) / (1024 * 1024)))MB"
    }

    /// One fixed decimal place, e.g. `50.0`, `1.5`, without `String(format:)`.
    private static func oneDecimal(_ value: Double) -> String {
        let scaled = Int((value * 10).rounded())
        return "\(scaled / 10).\(abs(scaled % 10))"
    }

    /// Lines for counting: split on `\n`, dropping the empty element a trailing
    /// newline produces. Matches pi's `splitLinesForCounting`.
    private static func splitLinesForCounting(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// Keeps the first N lines/bytes. Ported from `truncateHead`.
    static func head(
        _ content: String,
        maxLines: Int = defaultMaxLines,
        maxBytes: Int = defaultMaxBytes
    ) -> Result {
        let totalBytes = content.utf8.count
        let lines = splitLinesForCounting(content)
        let totalLines = lines.count

        if totalLines <= maxLines && totalBytes <= maxBytes {
            return Result(
                content: content,
                truncated: false,
                truncatedBy: nil,
                totalLines: totalLines,
                totalBytes: totalBytes,
                outputLines: totalLines,
                outputBytes: totalBytes,
                firstLineExceedsLimit: false,
                maxLines: maxLines,
                maxBytes: maxBytes
            )
        }

        let firstLineBytes = lines.first.map { $0.utf8.count } ?? 0
        if firstLineBytes > maxBytes {
            return Result(
                content: "",
                truncated: true,
                truncatedBy: .bytes,
                totalLines: totalLines,
                totalBytes: totalBytes,
                outputLines: 0,
                outputBytes: 0,
                firstLineExceedsLimit: true,
                maxLines: maxLines,
                maxBytes: maxBytes
            )
        }

        var kept: [String] = []
        var keptBytes = 0
        var truncatedBy: By = .lines
        for (index, line) in lines.enumerated() {
            if index >= maxLines { break }
            let lineBytes = line.utf8.count + (index > 0 ? 1 : 0)
            if keptBytes + lineBytes > maxBytes {
                truncatedBy = .bytes
                break
            }
            kept.append(line)
            keptBytes += lineBytes
        }
        if kept.count >= maxLines && keptBytes <= maxBytes {
            truncatedBy = .lines
        }

        let outputContent = kept.joined(separator: "\n")
        return Result(
            content: outputContent,
            truncated: true,
            truncatedBy: truncatedBy,
            totalLines: totalLines,
            totalBytes: totalBytes,
            outputLines: kept.count,
            outputBytes: outputContent.utf8.count,
            firstLineExceedsLimit: false,
            maxLines: maxLines,
            maxBytes: maxBytes
        )
    }

    /// pi's `GREP_MAX_LINE_LENGTH`: a grep match line is capped so one enormous
    /// line does not dominate the output.
    static let grepMaxLineLength = 500

    /// Truncates a single line to `maxChars`, appending pi's `... [truncated]`
    /// marker. Counts `Character`s; pi counts UTF-16 units, so a multi-scalar
    /// grapheme is one here and can be two there.
    static func truncateLine(
        _ line: String,
        maxChars: Int = grepMaxLineLength
    ) -> (text: String, wasTruncated: Bool) {
        guard line.count > maxChars else { return (line, false) }
        return ("\(line.prefix(maxChars))... [truncated]", true)
    }
}

// MARK: - Shell quoting

/// Wraps `argument` in single quotes so a shell run through `<shell> -c` treats
/// it as one literal token — no glob, no word split, no substitution.
///
/// The search tools build a command line for `rg`/`fd` and pass it to
/// ``Shell``, which only offers `<shell> -c <string>`; there is no argv exec.
/// Everything user- or model-supplied that lands on that line goes through here.
func singleQuoted(_ argument: String) -> String {
    "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
