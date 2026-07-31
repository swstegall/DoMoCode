// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// settings.json is read twice — by `JSONDecoder` for `Settings`, and by
// `parseOrderedJSON` for the `permission` block. These tests pin the two readers to
// the same grammar, because the failure when they drift is silent and total: the
// permission block vanishes, no rule is enforced, and every "Allow always" is refused
// persistence, while `model` and `baseUrl` load as if nothing were wrong.
//
// The parity suite deliberately runs the REAL pair — `JSONDecoder` into a struct of
// optionals shaped like `Settings`, against `permissionConfig(parsingSettingsText:)` —
// rather than comparing parsers in the abstract, so what is asserted is what
// production does.

import DoMoCore
import DoMoPermissions
import Foundation
import Testing

/// A stand-in for `Settings` (which lives in DoMoCLI and is not a dependency here):
/// all-optional fields, so it accepts any JSON object and rejects anything else,
/// exactly as `Settings` does.
private struct SettingsShape: Decodable {
    var model: String?
    var baseURL: String?
}

private func foundationAccepts(_ text: String) -> Bool {
    (try? JSONDecoder().decode(SettingsShape.self, from: Data(text.utf8))) != nil
}

private func orderedParserAccepts(_ text: String) -> Bool {
    (try? permissionConfig(parsingSettingsText: text)) != nil
}

/// One named document. A struct rather than a tuple so the parameterized tests take a
/// single argument, and `description` names the case in the test report.
private struct GrammarCase: Sendable, CustomStringConvertible {
    let name: String
    let text: String
    init(_ name: String, _ text: String) {
        self.name = name
        self.text = text
    }
    var description: String { name }
}

@Suite("settings.json grammar parity")
struct OrderedJSONGrammarTests {

    // MARK: - The two readers accept the same documents

    /// Documents Foundation accepts and the ordered parser used to reject. Each one is
    /// a settings.json that loaded its `model` while dropping its whole permission
    /// block on the floor.
    @Test(
        "documents Foundation accepts are accepted",
        arguments: [
            GrammarCase("empty object", "{}"),
            GrammarCase("plain", #"{"model":"a"}"#),
            GrammarCase("trailing comma in an object", #"{"model":"a",}"#),
            GrammarCase("trailing comma nested twice", #"{"permission":{"bash":{"git *":"allow",},},}"#),
            GrammarCase("trailing comma in an array", #"{"model":"a","xs":[1,2,]}"#),
            GrammarCase("trailing comma before a newline", "{\n  \"model\": \"a\",\n}"),
            GrammarCase("leading byte-order mark", "\u{FEFF}{\"model\":\"a\"}"),
            GrammarCase("byte-order mark then whitespace", "\u{FEFF}\n{\"model\":\"a\"}"),
            GrammarCase("duplicated key", #"{"model":"a","model":"b"}"#),
        ]
    )
    fileprivate func acceptedByBoth(_ document: GrammarCase) {
        #expect(
            foundationAccepts(document.text),
            "Foundation should accept \(document.name); the premise of this test is wrong"
        )
        #expect(
            orderedParserAccepts(document.text),
            "the ordered parser rejects \(document.name), which Foundation accepts"
        )
    }

    /// Documents Foundation rejects. Accepting these would be the same bug pointing
    /// the other way — a permission block enforced out of a file the rest of the CLI
    /// refuses to load.
    @Test(
        "documents Foundation rejects are rejected",
        arguments: [
            GrammarCase("byte-order mark after whitespace", " \u{FEFF}{\"model\":\"a\"}"),
            GrammarCase("byte-order mark inside an object", "{\u{FEFF}\"model\":\"a\"}"),
            GrammarCase("trailing byte-order mark", "{\"model\":\"a\"}\u{FEFF}"),
            GrammarCase("two commas in an object", #"{"model":"a",,}"#),
            GrammarCase("a comma and nothing else", "{,}"),
            GrammarCase("a comma and nothing else in an array", #"{"xs":[,]}"#),
            GrammarCase("two commas in an array", #"{"xs":[1,,]}"#),
            GrammarCase("a // comment", "{\"model\":\"a\" // x\n}"),
            GrammarCase("single-quoted strings", "{'model':'a'}"),
            GrammarCase("an unquoted key", #"{model:"a"}"#),
            GrammarCase("an unterminated string", #"{"model":"a}"#),
            GrammarCase("trailing garbage", #"{"model":"a"} junk"#),
            GrammarCase("nothing at all", ""),
            GrammarCase("whitespace only", "   \n "),
            GrammarCase("a top-level array", "[1,2,3]"),
            GrammarCase("a top-level string", #""hi""#),
            GrammarCase("a top-level number", "42"),
            GrammarCase("NaN", #"{"n":NaN}"#),
        ]
    )
    fileprivate func rejectedByBoth(_ document: GrammarCase) {
        #expect(
            !foundationAccepts(document.text),
            "Foundation should reject \(document.name); the premise of this test is wrong"
        )
        #expect(
            !orderedParserAccepts(document.text),
            "the ordered parser accepts \(document.name), which Foundation rejects"
        )
    }

    /// A duplicated key has to resolve to the *same* occurrence in both readers, or
    /// the permission block the engine enforces is not the one the rest of the file
    /// was read from. Asserted as agreement rather than as a specific winner, so this
    /// fails loudly if Foundation ever changes its mind.
    @Test("a duplicated key resolves to the same occurrence in both readers")
    func duplicateKeyAgreement() throws {
        let text = #"{"model":"first","model":"second"}"#
        let foundation = try #require(try JSONDecoder().decode(SettingsShape.self, from: Data(text.utf8)).model)
        let ordered = try #require(parseOrderedJSON(text))
        #expect(ordered["model"] == .string(foundation))
        // Pinned so a silent flip to last-wins in either reader is visible in the
        // diff, not merely "they still agree".
        #expect(foundation == "first")
    }

    // MARK: - The bug this fixes, end to end

    @Test("a trailing comma yields BOTH a decoded settings object and a live permission block")
    func trailingCommaKeepsBothHalves() throws {
        let text = """
            {
              "model": "gpt-x",
              "permission": {
                "bash": { "*": "ask", "git *": "allow" },
              },
            }
            """
        let decoded = try JSONDecoder().decode(SettingsShape.self, from: Data(text.utf8))
        #expect(decoded.model == "gpt-x")

        let rules = fromConfig(permissionConfig(fromSettingsText: text), homeDirectory: "/home/tester")
        #expect(
            rules == [
                PermissionRule(permission: "bash", pattern: "*", action: .ask),
                PermissionRule(permission: "bash", pattern: "git *", action: .allow),
            ]
        )
    }

    @Test("a trailing comma does not disturb the authored key order that drives precedence")
    func trailingCommaPreservesOrder() throws {
        let reversed = fromConfig(
            permissionConfig(fromSettingsText: #"{"permission":{"bash":{"git *":"allow","*":"deny",},},}"#),
            homeDirectory: "/home/tester"
        )
        // Last match wins, so the order is the meaning: this file denies everything,
        // including git. Reading it in the other order would silently allow git.
        #expect(
            reversed == [
                PermissionRule(permission: "bash", pattern: "git *", action: .allow),
                PermissionRule(permission: "bash", pattern: "*", action: .deny),
            ]
        )
    }

    @Test("a leading byte-order mark is consumed rather than glued onto the first key")
    func byteOrderMarkIsNotPartOfTheFirstKey() throws {
        let value = try #require(parseOrderedJSON("\u{FEFF}{\"model\":\"a\"}"))
        #expect(value["model"] == .string("a"))
        #expect(value["\u{FEFF}model"] == nil)
    }

    // MARK: - Failures are reported, not swallowed

    @Test("a parse failure carries the key path and points at the offending byte")
    func diagnosticLocatesTheProblem() throws {
        let text = """
            {
              "permission": { "bash": { "git *": allow } }
            }
            """
        var caught: ConfigDiagnostic?
        do {
            _ = try permissionConfig(parsingSettingsText: text, file: "/c/settings.json")
        } catch {
            caught = error
        }
        let diagnostic = try #require(caught, "an unquoted action must be reported, not silently dropped")
        #expect(diagnostic.file == "/c/settings.json")
        #expect(diagnostic.keyPath == ["permission", "bash", "git *"])

        let location = try #require(diagnostic.location)
        #expect(location.line == 2)
        // The byte itself, so the assertion cannot pass on an offset that merely
        // happens to be on the right line.
        let bytes = Array(text.utf8)
        #expect(bytes[location.byteOffset] == UInt8(ascii: "a"))
        // A caret is only useful under the line it accuses.
        #expect(diagnostic.description.contains("\n"))
    }

    @Test("the byte offset is a BYTE offset, so a multi-byte key does not shift the caret")
    func diagnosticOffsetSurvivesNonASCII() throws {
        // "café" is five scalars and six bytes: a scalar offset would land one place
        // to the left of the `]` and put the caret under the space.
        let text = #"{"café": ]}"#
        var caught: ConfigDiagnostic?
        do { _ = try permissionConfig(parsingSettingsText: text) } catch { caught = error }
        let diagnostic = try #require(caught)
        #expect(diagnostic.keyPath == ["café"])
        let offset = try #require(diagnostic.location?.byteOffset)
        #expect(Array(text.utf8)[offset] == UInt8(ascii: "]"))
    }

    @Test("a non-object top level is reported as such rather than read as an empty config")
    func nonObjectRootIsReported() {
        #expect(throws: ConfigDiagnostic.self) {
            _ = try permissionConfig(parsingSettingsText: "[1,2,3]")
        }
        // The reportless spelling still yields an empty config, so the ~20 existing
        // call sites keep their meaning.
        #expect(permissionConfig(fromSettingsText: "[1,2,3]").isEmpty)
    }

    @Test("an absent permission key is not a failure")
    func absentPermissionKeyIsNotAnError() throws {
        #expect(try permissionConfig(parsingSettingsText: #"{"model":"x"}"#).isEmpty)
    }

    @Test("a malformed ENTRY is still skipped without failing the whole file")
    func malformedEntryStillSkipped() throws {
        // Entry-level tolerance is deliberate and unchanged: a bad rule must not brick
        // the CLI. Only a bad FILE is reported.
        let config = try permissionConfig(parsingSettingsText: #"{"permission":{"bash":"banana","edit":"deny"}}"#)
        #expect(
            fromConfig(config, homeDirectory: "/h")
                == [PermissionRule(permission: "edit", pattern: "*", action: .deny)]
        )
    }

    // MARK: - The writer reports too

    @Test("the writer explains a refusal instead of returning a bare nil")
    func writerReportsRefusal() throws {
        let grants = [PermissionRule(permission: "bash", pattern: "git *", action: .allow)]

        var caught: ConfigDiagnostic?
        do {
            _ = try settingsText(parsing: "this is { not json", mergingGrants: grants, file: "/c/settings.json")
        } catch {
            caught = error
        }
        let diagnostic = try #require(caught, "an unparseable file must be reported, not silently skipped")
        #expect(diagnostic.file == "/c/settings.json")

        var arrayCaught: ConfigDiagnostic?
        do { _ = try settingsText(parsing: "[1, 2, 3]", mergingGrants: grants) } catch { arrayCaught = error }
        #expect(try #require(arrayCaught).problem.contains("JSON object"))

        // The reportless spelling keeps its exact old contract.
        #expect(settingsText("this is { not json", mergingGrants: grants) == nil)
        #expect(settingsText("[1, 2, 3]", mergingGrants: grants) == nil)
        #expect(settingsText("   \n ", mergingGrants: grants) != nil)
    }

    @Test("a trailing comma no longer blocks a grant from being merged in")
    func writerMergesIntoATrailingCommaFile() throws {
        let existing = """
            {
              "model": "gpt-x",
              "permission": { "bash": { "*": "ask" } },
            }
            """
        let updated = try settingsText(
            parsing: existing,
            mergingGrants: [PermissionRule(permission: "bash", pattern: "git *", action: .allow)]
        )
        // The result is re-serialized strict JSON, so the comma is gone and both
        // readers keep agreeing on the way back in.
        #expect(foundationAccepts(updated))
        #expect(
            fromConfig(permissionConfig(fromSettingsText: updated), homeDirectory: "/h") == [
                PermissionRule(permission: "bash", pattern: "*", action: .ask),
                PermissionRule(permission: "bash", pattern: "git *", action: .allow),
            ]
        )
        #expect(parseOrderedJSON(updated)?["model"] == .string("gpt-x"))
    }
}
