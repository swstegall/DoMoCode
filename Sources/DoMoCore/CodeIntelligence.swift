// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// Operations exposed by a code-intelligence provider. The names follow the
/// LSP vocabulary, but the contract is transport-neutral so MCP/ACP adapters
/// can expose the same permission and freshness behavior.
public enum CodeIntelligenceOperation: String, Sendable, Codable, Hashable, CaseIterable {
    case definition
    case declaration
    case references
    case implementation
    case documentSymbols
    case workspaceSymbols
    case callHierarchy
    case diagnostics
    case rename
    case relatedLocations

    public var requiresPath: Bool {
        switch self {
        case .workspaceSymbols:
            false
        case .definition, .declaration, .references, .implementation,
             .documentSymbols, .callHierarchy, .diagnostics, .rename,
             .relatedLocations:
            true
        }
    }

    public var requiresPosition: Bool {
        switch self {
        case .definition, .declaration, .references, .implementation,
             .callHierarchy, .rename, .relatedLocations:
            true
        case .documentSymbols, .workspaceSymbols, .diagnostics:
            false
        }
    }

    public var isMutation: Bool {
        self == .rename
    }
}

public struct CodeIntelligencePosition: Sendable, Codable, Hashable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = max(0, line)
        self.column = max(0, column)
    }
}

public struct CodeIntelligenceRequest: Sendable, Codable, Hashable {
    public var operation: CodeIntelligenceOperation
    public var rootPath: String
    public var path: String?
    public var position: CodeIntelligencePosition?
    public var query: String?
    public var newName: String?
    public var limit: Int
    public var metadata: [String: JSONValue]

    public init(
        operation: CodeIntelligenceOperation,
        rootPath: String,
        path: String? = nil,
        position: CodeIntelligencePosition? = nil,
        query: String? = nil,
        newName: String? = nil,
        limit: Int = 100,
        metadata: [String: JSONValue] = [:]
    ) {
        self.operation = operation
        self.rootPath = rootPath
        self.path = path
        self.position = position
        self.query = query
        self.newName = newName
        self.limit = max(1, limit)
        self.metadata = metadata
    }
}

public struct CodeIntelligenceDiagnostic: Sendable, Codable, Hashable {
    public var message: String
    public var location: IndexLocation?
    public var severity: String
    public var source: String?

    public init(
        message: String,
        location: IndexLocation? = nil,
        severity: String = "error",
        source: String? = nil
    ) {
        self.message = message
        self.location = location
        self.severity = severity
        self.source = source
    }
}

public struct CodeIntelligenceTextEdit: Sendable, Codable, Hashable {
    public var path: String
    public var start: CodeIntelligencePosition
    public var end: CodeIntelligencePosition
    public var newText: String

    public init(
        path: String,
        start: CodeIntelligencePosition,
        end: CodeIntelligencePosition,
        newText: String
    ) {
        self.path = path
        self.start = start
        self.end = end
        self.newText = newText
    }
}

public struct CodeIntelligenceResult: Sendable, Codable, Hashable {
    public var operation: CodeIntelligenceOperation
    public var providerID: String
    public var items: [IndexSymbol]
    public var diagnostics: [CodeIntelligenceDiagnostic]
    public var edits: [CodeIntelligenceTextEdit]
    public var freshness: IndexFreshness
    public var warning: String?

    public init(
        operation: CodeIntelligenceOperation,
        providerID: String,
        items: [IndexSymbol] = [],
        diagnostics: [CodeIntelligenceDiagnostic] = [],
        edits: [CodeIntelligenceTextEdit] = [],
        freshness: IndexFreshness = .current,
        warning: String? = nil
    ) {
        self.operation = operation
        self.providerID = providerID
        self.items = items
        self.diagnostics = diagnostics
        self.edits = edits
        self.freshness = freshness
        self.warning = warning
    }
}

public protocol DoMoCodeIntelligenceProvider: Sendable {
    var codeIntelligenceID: String { get }

    func perform(_ request: CodeIntelligenceRequest) async throws -> CodeIntelligenceResult
}

public struct CodeIntelligencePolicy: Sendable, Codable, Hashable {
    public var allowedOperations: Set<CodeIntelligenceOperation>
    public var maxResults: Int
    public var maxDiagnostics: Int
    public var maxEdits: Int

    public init(
        allowedOperations: Set<CodeIntelligenceOperation> = Set(CodeIntelligenceOperation.allCases),
        maxResults: Int = 200,
        maxDiagnostics: Int = 100,
        maxEdits: Int = 2_000
    ) {
        self.allowedOperations = allowedOperations
        self.maxResults = max(1, maxResults)
        self.maxDiagnostics = max(1, maxDiagnostics)
        self.maxEdits = max(1, maxEdits)
    }
}

public enum CodeIntelligenceCoordinatorError: Error, Sendable, Equatable {
    case invalidRoot(String)
    case pathOutsideRoot(String)
    case missingPath(CodeIntelligenceOperation)
    case missingPosition(CodeIntelligenceOperation)
    case missingQuery(CodeIntelligenceOperation)
    case invalidRenameName
    case permissionDenied(CodeIntelligenceOperation)
    case provider(String)
    case cancelled
}

/// Validates and bounds code-intelligence requests before they reach an LSP,
/// MCP, or ACP adapter. It never treats a stale provider result as current and
/// never lets a provider turn a read-only request into a rename.
public actor CodeIntelligenceCoordinator {
    private let rootPath: String
    private let provider: any DoMoCodeIntelligenceProvider
    private let policy: CodeIntelligencePolicy

    public init(
        rootPath: String,
        provider: any DoMoCodeIntelligenceProvider,
        policy: CodeIntelligencePolicy = CodeIntelligencePolicy()
    ) throws(CodeIntelligenceCoordinatorError) {
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty, trimmedRoot.hasPrefix("/"), !trimmedRoot.contains("\0") else {
            throw .invalidRoot(rootPath)
        }
        let normalized = Self.normalizePath(rootPath)
        guard Self.isAbsolute(normalized) else { throw .invalidRoot(rootPath) }
        self.rootPath = normalized
        self.provider = provider
        self.policy = policy
    }

    public func perform(
        _ request: CodeIntelligenceRequest
    ) async throws(CodeIntelligenceCoordinatorError) -> CodeIntelligenceResult {
        do {
            try Task.checkCancellation()
        } catch {
            throw .cancelled
        }
        guard policy.allowedOperations.contains(request.operation) else {
            throw .permissionDenied(request.operation)
        }
        if request.operation.requiresPath, request.path == nil {
            throw .missingPath(request.operation)
        }
        if request.operation.requiresPosition, request.position == nil {
            throw .missingPosition(request.operation)
        }
        if request.operation == .workspaceSymbols,
           request.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            throw .missingQuery(request.operation)
        }
        if request.operation == .rename {
            guard let newName = request.newName,
                  Self.isSafeRenameName(newName)
            else { throw .invalidRenameName }
        }

        var normalizedRequest = request
        normalizedRequest.rootPath = rootPath
        if let path = request.path {
            let normalizedPath = Self.normalizePath(path)
            guard Self.isWithinRoot(normalizedPath, root: rootPath) else {
                throw .pathOutsideRoot(path)
            }
            normalizedRequest.path = normalizedPath
        }
        normalizedRequest.limit = min(request.limit, policy.maxResults)

        do {
            let result = try await provider.perform(normalizedRequest)
            try Task.checkCancellation()
            guard result.operation == request.operation else {
                throw CodeIntelligenceCoordinatorError.provider("Provider returned a mismatched operation.")
            }
            guard result.providerID == provider.codeIntelligenceID else {
                throw CodeIntelligenceCoordinatorError.provider("Provider returned a mismatched identity.")
            }
            var bounded = result
            bounded.items = Array(result.items.prefix(policy.maxResults))
            bounded.diagnostics = Array(result.diagnostics.prefix(policy.maxDiagnostics))
            bounded.edits = Array(result.edits.prefix(policy.maxEdits))
            return bounded
        } catch let error as CodeIntelligenceCoordinatorError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .provider(String(describing: error))
        }
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL.path
    }

    private static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
    }

    private static func isWithinRoot(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func isSafeRenameName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { return false }
        guard let first = trimmed.unicodeScalars.first,
              isIdentifierStart(first)
        else { return false }
        return trimmed.unicodeScalars.dropFirst().allSatisfy(isIdentifierContinuation)
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x5f
            || scalar.value == 0x24
            || (scalar.value >= 0x41 && scalar.value <= 0x5a)
            || (scalar.value >= 0x61 && scalar.value <= 0x7a)
    }

    private static func isIdentifierContinuation(_ scalar: Unicode.Scalar) -> Bool {
        isIdentifierStart(scalar)
            || (scalar.value >= 0x30 && scalar.value <= 0x39)
    }
}
