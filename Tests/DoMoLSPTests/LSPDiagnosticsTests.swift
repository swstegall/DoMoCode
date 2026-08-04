import DoMoCore
import Foundation
import SystemPackage
import Testing

import DoMoLSP

private struct LSPFixture {
    let root: FilePath
    let directory: URL

    static func make() throws -> LSPFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("domolsp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return LSPFixture(root: FilePath(directory.path), directory: directory)
    }

    func path(_ relative: String) -> String {
        root.appending(relative).string
    }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let path = path(relative)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func removeCleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("LSP framing")
struct LSPContentLengthFramerTests {

    @Test("frames split headers and bodies by UTF-8 byte count")
    func splitFrames() {
        var framer = LSPContentLengthFramer()
        let first = #"{"jsonrpc":"2.0","id":1}"#
        let second = #"{"jsonrpc":"2.0","id":2,"result":"é"}"#
        let payload = Array(
            ("Content-Length: \(first.utf8.count)\r\n\r\n\(first)"
                + "Content-Length: \(second.utf8.count)\r\n\r\n\(second)").utf8
        )

        var messages: [Data] = []
        for chunk in stride(from: 0, to: payload.count, by: 3) {
            messages.append(contentsOf: framer.feed(Array(payload[chunk..<min(chunk + 3, payload.count)])))
        }

        #expect(messages.map { String(decoding: $0, as: UTF8.self) } == [first, second])
        #expect(!framer.overflowed)
    }

    @Test("header names are case insensitive and malformed frames stop safely")
    func malformedHeaders() {
        var framer = LSPContentLengthFramer(maximumMessageBytes: 8)
        let valid = Array("content-length: 2\r\n\r\nok".utf8)
        #expect(framer.feed(valid).count == 1)
        #expect(framer.feed(Array("Content-Length: 99\r\n\r\n".utf8)).isEmpty)
        #expect(framer.overflowed)

        var negative = LSPContentLengthFramer()
        #expect(negative.feed(Array("Content-Length: -1\r\n\r\n".utf8)).isEmpty)
        #expect(negative.overflowed)
    }

    @Test("a pooled language server answers pull diagnostics over stdio")
    func providerRoundTrip() async throws {
        let fixture = try LSPFixture.make()
        defer { fixture.removeCleanup() }
        try fixture.write("main.swift", "let value = broken")
        let mainURI = URL(fileURLWithPath: fixture.path("main.swift")).absoluteString
        let script = """
            #!/usr/bin/env python3
            import json
            import sys

            def send(value):
                body = json.dumps(value, separators=(",", ":")).encode("utf-8")
                sys.stdout.buffer.write(
                    f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("ascii") + body
                )
                sys.stdout.buffer.flush()

            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    break
                headers = {}
                while line not in (b"\\r\\n", b"\\n"):
                    key, value = line.decode("ascii").split(":", 1)
                    headers[key.lower()] = value.strip()
                    line = sys.stdin.buffer.readline()
                length = int(headers["content-length"])
                message = json.loads(sys.stdin.buffer.read(length))
                method = message.get("method")
                if method == "initialize":
                    send({
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": {
                            "capabilities": {
                                "diagnosticProvider": {
                                    "interFileDependencies": False,
                                    "workspaceDiagnostics": False
                                }
                            }
                        }
                    })
                elif method == "workspace/symbol":
                    send({
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": [{
                            "name": "value",
                            "kind": 13,
                            "location": {
                                "uri": "\(mainURI)",
                                "range": {
                                    "start": {"line": 0, "character": 4},
                                    "end": {"line": 0, "character": 9}
                                }
                            },
                            "containerName": "main"
                        }]
                    })
                elif method == "textDocument/documentSymbol":
                    send({
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": [{
                            "name": "value",
                            "kind": 13,
                            "range": {
                                "start": {"line": 0, "character": 4},
                                "end": {"line": 0, "character": 9}
                            },
                            "selectionRange": {
                                "start": {"line": 0, "character": 4},
                                "end": {"line": 0, "character": 9}
                            }
                        }]
                    })
                elif method == "textDocument/definition":
                    send({
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": [{
                            "uri": "\(mainURI)",
                            "range": {
                                "start": {"line": 0, "character": 4},
                                "end": {"line": 0, "character": 9}
                            }
                        }]
                    })
                elif method == "textDocument/rename":
                    send({
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": {
                            "changes": {
                                "\(mainURI)": [{
                                    "range": {
                                        "start": {"line": 0, "character": 4},
                                        "end": {"line": 0, "character": 9}
                                    },
                                    "newText": message["params"]["newName"]
                                }]
                            }
                        }
                    })
                elif method == "textDocument/diagnostic":
                    send({
                        "jsonrpc": "2.0",
                        "id": message["id"],
                        "result": {
                            "kind": "full",
                            "items": [{
                                "range": {
                                    "start": {"line": 2, "character": 4},
                                    "end": {"line": 2, "character": 10}
                                },
                                "severity": 1,
                                "source": "fixture",
                                "message": "cannot find 'broken' in scope"
                            }]
                        }
                    })
            """
        let command = try fixture.write("fixture-lsp.py", script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: command
        )
        let pool = LSPClientPool()
        let provider = LSPDiagnosticsProvider(
            root: fixture.root,
            configuration: LSPServerConfiguration(
                command: [command],
                languageID: "swift",
                environment: .inherit,
                timeout: .seconds(2)
            ),
            pool: pool
        )

        let report = await provider.check(changedPath: FilePath("main.swift"))
        await provider.shutdown()

        #expect(report.status == .errors)
        #expect(report.diagnostics.first?.file == fixture.path("main.swift"))
        #expect(report.diagnostics.first?.line == 3)
        #expect(report.diagnostics.first?.column == 5)
        #expect(report.diagnostics.first?.message == "cannot find 'broken' in scope")
        #expect(report.diagnostics.first?.source == "fixture")

        let index = LSPIndexProvider(
            root: fixture.root,
            configuration: LSPServerConfiguration(
                command: [command],
                languageID: "swift",
                environment: .inherit,
                timeout: .seconds(2)
            ),
            pool: pool
        )
        let symbols = try await index.search(IndexSearchQuery(text: "value", rootPath: fixture.root.string))
        #expect(symbols.freshness == .current)
        #expect(symbols.symbols.first?.name == "value")
        #expect(symbols.symbols.first?.kind == .variable)
        #expect(symbols.symbols.first?.location.path == fixture.path("main.swift"))
        let refresh = try await index.refresh(paths: [fixture.path("main.swift")])
        #expect(refresh.paths == [fixture.path("main.swift")])
        #expect(refresh.freshness == .current)
        let codeProvider = LSPCodeIntelligenceProvider(
            root: fixture.root,
            configuration: LSPServerConfiguration(
                command: [command],
                languageID: "swift",
                environment: .inherit,
                timeout: .seconds(2)
            ),
            pool: pool
        )
        #expect(codeProvider.codeIntelligenceID == "swift-lsp-code")
        let code = try CodeIntelligenceCoordinator(
            rootPath: fixture.root.string,
            provider: codeProvider
        )
        let definition = try await code.perform(CodeIntelligenceRequest(
            operation: .definition,
            rootPath: fixture.root.string,
            path: fixture.path("main.swift"),
            position: .init(line: 0, column: 4)
        ))
        #expect(definition.items.first?.location.path == fixture.path("main.swift"))
        let documentSymbols = try await code.perform(CodeIntelligenceRequest(
            operation: .documentSymbols,
            rootPath: fixture.root.string,
            path: fixture.path("main.swift")
        ))
        #expect(documentSymbols.items.first?.name == "value")
        let rename = try await code.perform(CodeIntelligenceRequest(
            operation: .rename,
            rootPath: fixture.root.string,
            path: fixture.path("main.swift"),
            position: .init(line: 0, column: 4),
            newName: "renamed"
        ))
        #expect(rename.edits.first?.newText == "renamed")
        await codeProvider.shutdown()
        await index.shutdown()
    }
}
