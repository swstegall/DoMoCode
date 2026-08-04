// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import DoMoCore
import DoMoExec
import DoMoTools
import Foundation
import Subprocess
import SystemPackage

// MARK: - Content-Length framing

/// Incremental framing for the language-server protocol.
///
/// LSP uses HTTP-style headers followed by a UTF-8 byte body. The body length
/// is bytes, not Swift characters, and a single read may contain half a header,
/// several messages, or a header plus only part of a body.
public struct LSPContentLengthFramer: Sendable {
    public let maximumMessageBytes: Int
    private var buffer: [UInt8] = []
    private(set) public var overflowed = false

    public init(maximumMessageBytes: Int = 32 * 1024 * 1024) {
        self.maximumMessageBytes = max(1, maximumMessageBytes)
    }

    /// Feeds bytes and returns complete JSON bodies, without their headers.
    public mutating func feed(_ bytes: [UInt8]) -> [Data] {
        guard !overflowed else { return [] }
        buffer.append(contentsOf: bytes)
        var messages: [Data] = []

        while let delimiter = Self.delimiter(in: buffer) {
            guard delimiter <= 8 * 1024 else {
                overflowed = true
                buffer.removeAll(keepingCapacity: false)
                return messages
            }
            let header = buffer[..<delimiter]
            guard let length = Self.contentLength(in: header),
                  length >= 0,
                  length <= maximumMessageBytes
            else {
                overflowed = true
                buffer.removeAll(keepingCapacity: false)
                return messages
            }
            let bodyStart = delimiter + 4
            guard buffer.count - bodyStart >= length else { break }
            messages.append(Data(buffer[bodyStart..<(bodyStart + length)]))
            buffer.removeFirst(bodyStart + length)
        }

        if buffer.count > maximumMessageBytes,
           buffer.count - maximumMessageBytes > 8 * 1024
        {
            overflowed = true
            buffer.removeAll(keepingCapacity: false)
        }
        return messages
    }

    private static func delimiter(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) {
            if bytes[index] == 13,
               bytes[index + 1] == 10,
               bytes[index + 2] == 13,
               bytes[index + 3] == 10
            {
                return index
            }
        }
        return nil
    }

    private static func contentLength(in header: ArraySlice<UInt8>) -> Int? {
        let text = String(decoding: header, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Content-Length") == .orderedSame,
                  let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            return length
        }
        return nil
    }
}

// MARK: - Public configuration and provider

/// One local language-server command.
public struct LSPServerConfiguration: Sendable, Hashable {
    public let command: [String]
    public let languageID: String
    public let environment: ShellEnvironment
    public let timeout: Duration
    /// Optional OS-level confinement for the language server and its descendants.
    public let sandbox: ProcessSandbox?

    public init(
        command: [String],
        languageID: String,
        environment: ShellEnvironment = .inherit,
        timeout: Duration = .seconds(30),
        sandbox: ProcessSandbox? = nil
    ) {
        self.command = command
        self.languageID = languageID
        self.environment = environment
        self.timeout = timeout
        self.sandbox = sandbox
    }
}

/// A diagnostics provider backed by one pooled LSP process per project root
/// and server command.
public struct LSPDiagnosticsProvider: DiagnosticsProvider {
    public let root: FilePath
    public let configuration: LSPServerConfiguration
    private let pool: LSPClientPool

    public init(
        root: FilePath,
        configuration: LSPServerConfiguration,
        pool: LSPClientPool = LSPClientPool()
    ) {
        self.root = root
        self.configuration = configuration
        self.pool = pool
    }

    @concurrent
    public func check(changedPath: FilePath) async -> DiagnosticsReport {
        await pool.check(
            root: root,
            configuration: configuration,
            changedPath: changedPath
        )
    }

    public func shutdown() async {
        await pool.shutdown()
    }
}

/// A symbol/search index backed by the same bounded LSP process used for
/// diagnostics. The index provider deliberately has no watcher of its own;
/// ``IndexCoordinator`` owns invalidation and passes the changed paths here.
/// This keeps file watching, freshness, and permission policy outside the
/// language-server transport.
public struct LSPIndexProvider: DoMoIndexProvider {
    public let root: FilePath
    public let configuration: LSPServerConfiguration
    public let descriptor: IndexProviderDescriptor
    private let pool: LSPClientPool

    public init(
        root: FilePath,
        configuration: LSPServerConfiguration,
        pool: LSPClientPool = LSPClientPool(),
        providerID: String? = nil
    ) {
        self.root = root
        self.configuration = configuration
        self.pool = pool
        let id = providerID ?? "\(configuration.languageID)-lsp-index"
        self.descriptor = IndexProviderDescriptor(
            id: id,
            displayName: "\(configuration.languageID) LSP index",
            capabilities: ["search", "symbols", "workspace-symbols"],
            supportsIncrementalRefresh: true
        )
    }

    public func search(_ query: IndexSearchQuery) async throws -> IndexSearchResult {
        try await pool.search(root: root, configuration: configuration, query: query)
    }

    public func refresh(paths: [String]) async throws -> IndexRefreshResult {
        try await pool.refresh(root: root, configuration: configuration, paths: paths)
    }

    public func shutdown() async {
        await pool.shutdown()
    }
}

/// Maps the bounded code-intelligence contract onto LSP requests. The caller
/// still owns authorization through ``CodeIntelligenceCoordinator``; this
/// adapter only translates values and parses the server response.
public struct LSPCodeIntelligenceProvider: DoMoCodeIntelligenceProvider {
    public let root: FilePath
    public let configuration: LSPServerConfiguration
    public let codeIntelligenceID: String
    private let pool: LSPClientPool

    public init(
        root: FilePath,
        configuration: LSPServerConfiguration,
        pool: LSPClientPool = LSPClientPool(),
        providerID: String? = nil
    ) {
        self.root = root
        self.configuration = configuration
        self.pool = pool
        self.codeIntelligenceID = providerID ?? "(configuration.languageID)-lsp-code"
    }

    public func perform(_ request: CodeIntelligenceRequest) async throws -> CodeIntelligenceResult {
        try await pool.performCodeIntelligence(
            root: root,
            configuration: configuration,
            request: request,
            providerID: codeIntelligenceID
        )
    }

    public func shutdown() async {
        await pool.shutdown()
    }
}

/// Owns one LSP client per root/command key. Keeping the pool outside the
/// provider makes it possible for several tools or sessions to share a warm
/// language server without sharing diagnostics between roots.
public actor LSPClientPool {
    private struct Key: Sendable, Hashable {
        let root: String
        let command: [String]
        let languageID: String
        let sandbox: ProcessSandbox?
    }

    private var clients: [Key: LSPClient] = [:]

    public init() {}

    public func check(
        root: FilePath,
        configuration: LSPServerConfiguration,
        changedPath: FilePath
    ) async -> DiagnosticsReport {
        guard let client = client(root: root, configuration: configuration) else {
            return DiagnosticsReport(
                provider: "\(configuration.languageID)-lsp",
                status: .unavailable,
                note: "no language-server command was configured"
            )
        }
        return await client.check(changedPath: changedPath)
    }

    public func search(
        root: FilePath,
        configuration: LSPServerConfiguration,
        query: IndexSearchQuery
    ) async throws -> IndexSearchResult {
        guard let client = client(root: root, configuration: configuration) else {
            throw IndexCoordinatorError.unavailable
        }
        return try await client.searchSymbols(query)
    }

    public func refresh(
        root: FilePath,
        configuration: LSPServerConfiguration,
        paths: [String]
    ) async throws -> IndexRefreshResult {
        guard let client = client(root: root, configuration: configuration) else {
            throw IndexCoordinatorError.unavailable
        }
        return try await client.refreshIndex(paths: paths)
    }

    public func performCodeIntelligence(
        root: FilePath,
        configuration: LSPServerConfiguration,
        request: CodeIntelligenceRequest,
        providerID: String
    ) async throws -> CodeIntelligenceResult {
        guard let client = client(root: root, configuration: configuration) else {
            throw IndexCoordinatorError.unavailable
        }
        return try await client.performCodeIntelligence(request, providerID: providerID)
    }

    public func shutdown() async {
        let clients = Array(self.clients.values)
        self.clients.removeAll()
        for client in clients {
            await client.shutdown()
        }
    }

    private func client(
        root: FilePath,
        configuration: LSPServerConfiguration
    ) -> LSPClient? {
        guard !configuration.command.isEmpty else { return nil }
        let key = Key(
            root: root.string,
            command: configuration.command,
            languageID: configuration.languageID,
            sandbox: configuration.sandbox
        )
        if let existing = clients[key] { return existing }
        let created = LSPClient(root: root, configuration: configuration)
        clients[key] = created
        return created
    }
}

// MARK: - Process

private actor PersistentLSPProcess {
    let chunks: AsyncStream<[UInt8]>
    private let chunksContinuation: AsyncStream<[UInt8]>.Continuation
    private let outgoing: AsyncStream<[UInt8]>
    private let outgoingContinuation: AsyncStream<[UInt8]>.Continuation
    private var runTask: Task<Void, Never>?

    init() {
        (chunks, chunksContinuation) = AsyncStream.makeStream(of: [UInt8].self)
        (outgoing, outgoingContinuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    func start(
        command: [String],
        environment: ShellEnvironment,
        workingDirectory: FilePath,
        sandbox: ProcessSandbox?
    ) throws(DoMoError) {
        guard runTask == nil, let executable = command.first else { return }
        let plan = try sandbox?.plan(
            role: .lsp,
            command: command,
            workingDirectory: workingDirectory,
            environment: environment
        )
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(2))
        ]
        let executableForm: Subprocess.Executable = if let plan {
            .path(.init(plan.executable.string))
        } else {
            executable.hasPrefix("/") ? .path(.init(executable)) : .name(executable)
        }
        let configuration = Subprocess.Configuration(
            executable: executableForm,
            arguments: Subprocess.Arguments(plan?.arguments ?? Array(command.dropFirst())),
            environment: plan?.environment.subprocessEnvironment ?? environment.subprocessEnvironment,
            workingDirectory: .init((plan?.workingDirectory ?? workingDirectory).string),
            platformOptions: platformOptions
        )
        let outgoing = self.outgoing
        let chunksContinuation = self.chunksContinuation

        runTask = Task {
            _ = try? await Subprocess.run(
                configuration,
                input: .inputWriter,
                output: .sequence,
                error: .sequence
            ) { execution in
                let writerTask = Task {
                    let writer = execution.standardInputWriter
                    for await bytes in outgoing {
                        var offset = 0
                        while offset < bytes.count {
                            let written = (try? await writer.write(Array(bytes[offset...]))) ?? 0
                            guard written > 0 else { break }
                            offset += written
                        }
                    }
                    try? await writer.finish()
                }
                let stdoutTask = Task {
                    do {
                        for try await chunk in execution.standardOutput {
                            let bytes: [UInt8] = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                            chunksContinuation.yield(bytes)
                        }
                    } catch {}
                }
                let stderrTask = Task {
                    do {
                        for try await chunk in execution.standardError {
                            _ = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
                        }
                    } catch {}
                }
                await writerTask.value
                await stdoutTask.value
                await stderrTask.value
            }
            chunksContinuation.finish()
        }
    }

    func send(_ bytes: [UInt8]) {
        outgoingContinuation.yield(bytes)
    }

    func shutdown() async {
        guard let task = runTask else { return }
        runTask = nil
        outgoingContinuation.finish()
        task.cancel()
        await task.value
        chunksContinuation.finish()
    }

}

// MARK: - JSON-RPC client

private actor LSPClient {
    private enum LSPError: Error, Sendable {
        case timedOut
        case closed
        case invalidResponse
        case protocolError(String)
    }

    private let root: FilePath
    private let configuration: LSPServerConfiguration
    private let providerName: String
    private let process = PersistentLSPProcess()
    private var readerTask: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var openDocuments: Set<String> = []
    private var versions: [String: Int] = [:]
    private var pushed: [String: [CodeDiagnostic]] = [:]
    private var indexGeneration = 0
    private var initialized = false
    private var closed = false

    init(root: FilePath, configuration: LSPServerConfiguration) {
        self.root = root
        self.configuration = configuration
        self.providerName = "\(configuration.languageID)-lsp"
    }

    func check(changedPath: FilePath) async -> DiagnosticsReport {
        do {
            try await startIfNeeded()
            let absolutePath = Self.absolutePath(changedPath, root: root)
            let uri = Self.fileURI(absolutePath)
            guard let content = try? String(contentsOfFile: absolutePath, encoding: .utf8) else {
                return DiagnosticsReport(
                    provider: providerName,
                    status: .unavailable,
                    note: "the changed file could not be read as UTF-8"
                )
            }
            try await publishDocument(uri: uri, content: content)

            // A push notification may arrive before or after the pull response.
            // The short settling window avoids returning a stale push snapshot
            // from servers that compile asynchronously.
            try? await Task.sleep(for: .milliseconds(50))
            var pullError: String?
            var pullDiagnostics: [CodeDiagnostic] = []
            do {
                let response = try await request(
                    "textDocument/diagnostic",
                    params: .object(["textDocument": .object(["uri": .string(uri)])])
                )
                pullDiagnostics = Self.parseDiagnostics(
                    response["items"]?.arrayValue ?? [],
                    uri: uri,
                    source: providerName
                )
            } catch {
                pullError = String(describing: error)
            }

            var combined = pushed[uri] ?? []
            combined.append(contentsOf: pullDiagnostics)
            var unique: [CodeDiagnostic] = []
            var seen = Set<CodeDiagnostic>()
            for diagnostic in combined where seen.insert(diagnostic).inserted {
                unique.append(diagnostic)
            }

            if unique.isEmpty, let pullError, pushed[uri] == nil {
                return DiagnosticsReport(
                    provider: providerName,
                    command: configuration.command.joined(separator: " "),
                    status: .unavailable,
                    note: pullError
                )
            }
            return DiagnosticsReport(
                provider: providerName,
                command: configuration.command.joined(separator: " "),
                status: unique.isEmpty ? .clean : .errors,
                diagnostics: Array(unique.prefix(20)),
                totalDiagnostics: unique.count,
                truncated: unique.count > 20
            )
        } catch {
            return DiagnosticsReport(
                provider: providerName,
                command: configuration.command.joined(separator: " "),
                status: .unavailable,
                note: String(describing: error)
            )
        }
    }

    func refreshIndex(paths: [String]) async throws -> IndexRefreshResult {
        try await startIfNeeded()
        let normalizedPaths = paths
            .map { Self.absolutePath(FilePath($0), root: root) }
            .map(Self.normalizedPath)
            .filter { !$0.isEmpty }
            .sorted()

        var refreshed: [String] = []
        for path in normalizedPaths {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            try await publishDocument(uri: Self.fileURI(path), content: content)
            refreshed.append(path)
        }
        indexGeneration += 1
        return IndexRefreshResult(
            paths: refreshed,
            indexedGeneration: indexGeneration,
            freshness: .current
        )
    }

    func searchSymbols(_ query: IndexSearchQuery) async throws -> IndexSearchResult {
        try await startIfNeeded()
        let response = try await request(
            "workspace/symbol",
            params: .object(["query": .string(query.text)])
        )
        let symbols = Self.parseWorkspaceSymbols(
            response.arrayValue ?? [],
            query: query,
            root: root.string
        )
        return IndexSearchResult(
            symbols: Array(symbols.prefix(query.limit)),
            freshness: .current,
            indexedGeneration: indexGeneration
        )
    }

    func performCodeIntelligence(
        _ codeRequest: CodeIntelligenceRequest,
        providerID: String
    ) async throws -> CodeIntelligenceResult {
        try await startIfNeeded()
        switch codeRequest.operation {
        case .diagnostics:
            guard let path = codeRequest.path else { throw LSPError.invalidResponse }
            let report = await check(changedPath: FilePath(path))
            let diagnostics = report.diagnostics.map { diagnostic in
                CodeIntelligenceDiagnostic(
                    message: diagnostic.message,
                    location: diagnostic.file.flatMap { file in
                        guard let line = diagnostic.line else { return nil }
                        return IndexLocation(
                            path: Self.normalizedPath(file),
                            line: max(0, line - 1),
                            column: max(0, (diagnostic.column ?? 1) - 1)
                        )
                    },
                    source: diagnostic.source
                )
            }
            return CodeIntelligenceResult(
                operation: codeRequest.operation,
                providerID: providerID,
                diagnostics: diagnostics,
                freshness: report.status == .unavailable ? .unavailable : .current,
                warning: report.note
            )

        case .workspaceSymbols:
            let query = IndexSearchQuery(
                text: codeRequest.query ?? "",
                rootPath: codeRequest.rootPath,
                limit: codeRequest.limit
            )
            let response = try await request(
                "workspace/symbol",
                params: .object(["query": .string(query.text)])
            )
            let symbols = Self.parseWorkspaceSymbols(
                response.arrayValue ?? [],
                query: query,
                root: codeRequest.rootPath
            )
            return CodeIntelligenceResult(
                operation: codeRequest.operation,
                providerID: providerID,
                items: Array(symbols.prefix(codeRequest.limit)),
                freshness: .current
            )

        case .documentSymbols:
            let params = try Self.textDocumentParams(codeRequest, root: root)
            let response = try await request("textDocument/documentSymbol", params: params)
            let symbols = Self.parseSymbolLocations(
                response.arrayValue ?? [],
                root: codeRequest.rootPath,
                defaultPath: codeRequest.path
            )
            return CodeIntelligenceResult(
                operation: codeRequest.operation,
                providerID: providerID,
                items: Array(symbols.prefix(codeRequest.limit)),
                freshness: .current
            )

        case .rename:
            let params = try Self.textDocumentParams(codeRequest, root: root)
            let object: JSONValue = .object([
                "textDocument": params["textDocument"] ?? .null,
                "position": params["position"] ?? .null,
                "newName": .string(codeRequest.newName ?? "")
            ])
            let response = try await request("textDocument/rename", params: object)
            return CodeIntelligenceResult(
                operation: codeRequest.operation,
                providerID: providerID,
                edits: Self.parseWorkspaceEdits(response, root: codeRequest.rootPath),
                freshness: .current
            )

        case .definition, .declaration, .references, .implementation,
             .callHierarchy, .relatedLocations:
            let params = try Self.textDocumentParams(codeRequest, root: root)
            let method: String
            switch codeRequest.operation {
            case .definition: method = "textDocument/definition"
            case .declaration: method = "textDocument/declaration"
            case .references, .relatedLocations: method = "textDocument/references"
            case .implementation: method = "textDocument/implementation"
            case .callHierarchy: method = "textDocument/prepareCallHierarchy"
            default: method = "textDocument/definition"
            }
            let requestParams: JSONValue
            if codeRequest.operation == .references || codeRequest.operation == .relatedLocations {
                requestParams = .object([
                    "textDocument": params["textDocument"] ?? .null,
                    "position": params["position"] ?? .null,
                    "context": .object(["includeDeclaration": .bool(true)])
                ])
            } else {
                requestParams = params
            }
            let response = try await request(method, params: requestParams)
            let values = response.arrayValue ?? (response == .null ? [] : [response])
            let symbols = Self.parseSymbolLocations(values, root: codeRequest.rootPath)
            return CodeIntelligenceResult(
                operation: codeRequest.operation,
                providerID: providerID,
                items: Array(symbols.prefix(codeRequest.limit)),
                freshness: .current
            )
        }
    }

    func shutdown() async {
        readerTask?.cancel()
        readerTask = nil
        closed = true
        failAll(LSPError.closed)
        await process.shutdown()
    }

    private func startIfNeeded() async throws {
        if initialized { return }
        guard !closed else { throw LSPError.closed }
        try await process.start(
            command: configuration.command,
            environment: configuration.environment,
            workingDirectory: root,
            sandbox: configuration.sandbox
        )
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
        let rootURI = Self.fileURI(root.string)
        let initialize = try await request(
            "initialize",
            params: .object([
                "processId": .null,
                "rootUri": .string(rootURI),
                "capabilities": .object([
                    "textDocument": .object([
                        "publishDiagnostics": .object([:]),
                    ]),
                    "workspace": .object([
                        "symbol": .object(["dynamicRegistration": .bool(false)]),
                    ]),
                ]),
                "workspaceFolders": .array([
                    .object(["uri": .string(rootURI), "name": .string(root.lastComponent?.string ?? "workspace")]),
                ]),
            ])
        )
        _ = initialize
        try await notify("initialized", params: .object([:]))
        initialized = true
    }

    private func publishDocument(uri: String, content: String) async throws {
        let version = (versions[uri] ?? 0) + 1
        versions[uri] = version
        if openDocuments.insert(uri).inserted {
            try await notify(
                "textDocument/didOpen",
                params: .object([
                    "textDocument": .object([
                        "uri": .string(uri),
                        "languageId": .string(configuration.languageID),
                        "version": .int(version),
                        "text": .string(content),
                    ]),
                ])
            )
        } else {
            try await notify(
                "textDocument/didChange",
                params: .object([
                    "textDocument": .object([
                        "uri": .string(uri),
                        "version": .int(version),
                    ]),
                    "contentChanges": .array([
                        .object(["text": .string(content)]),
                    ]),
                ])
            )
        }
    }

    private func nextRequestID() -> Int {
        nextID += 1
        return nextID
    }

    private func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        guard !closed else { throw LSPError.closed }
        let id = nextRequestID()
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        let frame = try Self.frame(for: .object(object))
        let timeoutDuration = configuration.timeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = continuation
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: timeoutDuration) } catch { return }
                    await self?.timeout(id: id)
                }
                timeoutTasks[id] = timeout
                let process = self.process
                Task { await process.send(frame) }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func notify(_ method: String, params: JSONValue?) async throws {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        try await process.send(Self.frame(for: .object(object)))
    }

    private func timeout(id: Int) {
        guard let continuation = takePending(id) else { return }
        continuation.resume(throwing: LSPError.timedOut)
    }

    private func cancel(id: Int) {
        guard let continuation = takePending(id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func takePending(_ id: Int) -> CheckedContinuation<JSONValue, any Error>? {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        return pending.removeValue(forKey: id)
    }

    private func failAll(_ error: any Error) {
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
    }

    private func readLoop() async {
        var framer = LSPContentLengthFramer()
        for await chunk in process.chunks {
            for data in framer.feed(chunk) {
                guard let message = try? JSONValue(parsing: data) else { continue }
                dispatch(message)
            }
            if framer.overflowed { break }
        }
        closed = true
        failAll(LSPError.closed)
    }

    private func dispatch(_ message: JSONValue) {
        if let id = message["id"]?.intValue, message["method"] == nil {
            guard let continuation = takePending(id) else { return }
            if let error = message["error"] {
                continuation.resume(
                    throwing: LSPError.protocolError(error["message"]?.stringValue ?? "language server error")
                )
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }

        guard let method = message["method"]?.stringValue else { return }
        if method == "textDocument/publishDiagnostics",
           let params = message["params"],
           let uri = params["uri"]?.stringValue
        {
            pushed[uri] = Self.parseDiagnostics(
                params["diagnostics"]?.arrayValue ?? [],
                uri: uri,
                source: providerName
            )
            return
        }

        // Servers commonly ask for configuration or dynamic registration even
        // when the client advertised no meaningful capability. Answering null
        // keeps the server's request queue moving without pretending to support
        // a feature.
        if let id = message["id"] {
            let response: JSONValue = .object([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .null,
            ])
            if let frame = try? Self.frame(for: response) {
                let process = self.process
                Task { await process.send(frame) }
            }
        }
    }
}

private extension LSPClient {
    static func frame(for value: JSONValue) throws -> [UInt8] {
        let body = try value.encoded()
        let header = Array("Content-Length: \(body.count)\r\n\r\n".utf8)
        return header + body
    }

    static func absolutePath(_ path: FilePath, root: FilePath) -> String {
        if path.string.hasPrefix("/") { return path.string }
        return root.appending(path.string).string
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func textDocumentParams(
        _ request: CodeIntelligenceRequest,
        root: FilePath
    ) throws -> JSONValue {
        guard let path = request.path,
              let position = request.position
        else { throw LSPClient.LSPError.invalidResponse }
        let absolutePath = normalizedPath(absolutePath(FilePath(path), root: root))
        return .object([
            "textDocument": .object(["uri": .string(fileURI(absolutePath))]),
            "position": .object([
                "line": .int(position.line),
                "character": .int(position.column)
            ])
        ])
    }

    static func fileURI(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    static func parseDiagnostics(
        _ values: [JSONValue],
        uri: String,
        source: String
    ) -> [CodeDiagnostic] {
        let file = URL(string: uri)?.path.removingPercentEncoding
        return values.compactMap { value in
            guard let message = value["message"]?.stringValue else { return nil }
            let severity = value["severity"]?.intValue ?? 1
            guard severity == 1 else { return nil }
            let start = value["range"]?["start"]
            let line = start?["line"]?.intValue.map { $0 + 1 }
            let column = start?["character"]?.intValue.map { $0 + 1 }
            return CodeDiagnostic(
                file: file,
                line: line,
                column: column,
                message: String(message.prefix(2_000)),
                source: value["source"]?.stringValue ?? source
            )
        }
    }

    static func parseWorkspaceSymbols(
        _ values: [JSONValue],
        query: IndexSearchQuery,
        root: String
    ) -> [IndexSymbol] {
        let normalizedRoot = normalizedPath(root)
        let allowedKinds = Set(query.kinds)
        return values.compactMap { value in
            guard let name = value["name"]?.stringValue,
                  let location = value["location"]
            else { return nil }
            let uri = location["uri"]?.stringValue ?? value["uri"]?.stringValue
            guard let uri else { return nil }
            let rawPath = URL(string: uri)?.path.removingPercentEncoding ?? uri
            let path = normalizedPath(rawPath)
            guard path == normalizedRoot || path.hasPrefix(normalizedRoot + "/") else {
                return nil
            }
            let kind = indexKind(value["kind"]?.intValue ?? 0)
            guard allowedKinds.isEmpty || allowedKinds.contains(kind) else { return nil }
            let range = location["range"] ?? value["range"]
            let start = range?["start"]
            let end = range?["end"]
            return IndexSymbol(
                name: name,
                kind: kind,
                location: IndexLocation(
                    path: path,
                    line: start?["line"]?.intValue ?? 0,
                    column: start?["character"]?.intValue ?? 0,
                    endLine: end?["line"]?.intValue,
                    endColumn: end?["character"]?.intValue
                ),
                containerName: value["containerName"]?.stringValue,
                detail: value["detail"]?.stringValue
            )
        }
    }

    static func parseSymbolLocations(
        _ values: [JSONValue],
        root: String,
        defaultPath: String? = nil
    ) -> [IndexSymbol] {
        let normalizedRoot = normalizedPath(root)
        return values.compactMap { value in
            let location = value["location"] ?? value
            let rawPath: String
            if let uri = location["uri"]?.stringValue {
                rawPath = URL(string: uri)?.path.removingPercentEncoding ?? uri
            } else if let defaultPath {
                rawPath = defaultPath
            } else {
                return nil
            }
            let path = normalizedPath(rawPath)
            guard path == normalizedRoot || path.hasPrefix(normalizedRoot + "/") else {
                return nil
            }
            let range = location["range"] ?? value["range"]
            let start = range?["start"]
            let end = range?["end"]
            return IndexSymbol(
                name: value["name"]?.stringValue ?? "location",
                kind: indexKind(value["kind"]?.intValue ?? 0),
                location: IndexLocation(
                    path: path,
                    line: start?["line"]?.intValue ?? 0,
                    column: start?["character"]?.intValue ?? 0,
                    endLine: end?["line"]?.intValue,
                    endColumn: end?["character"]?.intValue
                ),
                containerName: value["containerName"]?.stringValue,
                detail: value["detail"]?.stringValue
            )
        }
    }

    static func parseWorkspaceEdits(
        _ value: JSONValue,
        root: String
    ) -> [CodeIntelligenceTextEdit] {
        let normalizedRoot = normalizedPath(root)
        var edits: [CodeIntelligenceTextEdit] = []
        if let changes = value["changes"]?.objectValue {
            for (uri, fileEdits) in changes {
                let path = normalizedPath(URL(string: uri)?.path.removingPercentEncoding ?? uri)
                guard path == normalizedRoot || path.hasPrefix(normalizedRoot + "/") else { continue }
                edits.append(contentsOf: parseTextEdits(fileEdits, path: path))
            }
        }
        if let documentChanges = value["documentChanges"]?.arrayValue {
            for documentChange in documentChanges {
                guard let uri = documentChange["textDocument"]?["uri"]?.stringValue else { continue }
                let path = normalizedPath(URL(string: uri)?.path.removingPercentEncoding ?? uri)
                guard path == normalizedRoot || path.hasPrefix(normalizedRoot + "/") else { continue }
                edits.append(contentsOf: parseTextEdits(documentChange["edits"] ?? .null, path: path))
            }
        }
        return edits
    }

    static func parseTextEdits(
        _ value: JSONValue,
        path: String
    ) -> [CodeIntelligenceTextEdit] {
        (value.arrayValue ?? []).compactMap { edit in
            guard let range = edit["range"],
                  let newText = edit["newText"]?.stringValue,
                  let startLine = range["start"]?["line"]?.intValue,
                  let startColumn = range["start"]?["character"]?.intValue,
                  let endLine = range["end"]?["line"]?.intValue,
                  let endColumn = range["end"]?["character"]?.intValue
            else { return nil }
            return CodeIntelligenceTextEdit(
                path: path,
                start: CodeIntelligencePosition(line: startLine, column: startColumn),
                end: CodeIntelligencePosition(line: endLine, column: endColumn),
                newText: String(newText.prefix(1_000_000))
            )
        }
    }

    static func indexKind(_ value: Int) -> IndexSymbolKind {
        switch value {
        case 1: return .file
        case 2, 4: return .module
        case 3: return .namespace
        case 5, 10, 11, 23: return .type
        case 6, 9: return .method
        case 7, 8, 24: return .property
        case 12: return .function
        case 13: return .variable
        case 14, 22: return .constant
        default: return .unknown
        }
    }
}
