// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The permission policy core, proven against opencode's/kilocode's golden conformance
// corpus (next.test.ts, arity.test.ts, next.toConfig.test.ts, env-read.test.ts). Every
// row here is a case from those TypeScript test files, translated verbatim.

import Testing

@testable import DoMoPermissions

private let HOME = "/home/tester"

// MARK: - literal helpers

private func r(_ p: String, _ pat: String, _ a: PermissionAction) -> PermissionRule {
    PermissionRule(permission: p, pattern: pat, action: a)
}
private func act(_ a: PermissionAction) -> PermissionConfigValue { .action(a) }
private func pmap(_ pairs: (String, PermissionAction?)...) -> PermissionConfigValue {
    .map(pairs.map { PatternRule(pattern: $0.0, action: $0.1) })
}
private func cfg(_ entries: (String, PermissionConfigValue?)...) -> PermissionConfig {
    entries.map { PermissionConfigEntry(permission: $0.0, value: $0.1) }
}
/// DoMoCode's decision = opencode `evaluate` + kilocode `.env` `readHarden`.
private func decide(_ permission: String, _ pattern: String, _ rulesets: Ruleset...) -> PermissionAction {
    readHarden(permission, pattern, evaluate(permission, pattern, rulesets: rulesets)).action
}

// MARK: - wildcard

@Suite("Wildcard glob matcher")
struct WildcardTests {
    @Test("truth table (wildcard.test.ts + derived env/prefix rows)")
    func truthTable() {
        let cases: [(String, String, Bool)] = [
            ("file1.txt", "file?.txt", true),
            ("file12.txt", "file?.txt", false),   // ? is exactly one char
            ("foo+bar", "foo+bar", true),          // + escaped to literal
            ("ls", "ls *", true),                  // trailing " *" optional
            ("ls -la", "ls *", true),
            ("ls foo bar", "ls *", true),          // dotAll spans spaces
            ("lstmeval", "ls *", false),           // no space -> not matched by "ls *"
            ("lstmeval", "ls*", true),             // greedy "ls*" DOES match
            ("git", "git *", true),
            ("git status", "git *", true),
            ("bash", "*", true),
            ("anything at all", "*", true),
            ("a\\b\\c", "a/b/c", true),            // backslash normalized to slash
            (".env", "*.env", true),
            ("config/app.env", "*.env", true),
            ("project/.env", "*.env", true),
            ("project/.env.local", "*.env.*", true),
            ("project/.env.example", "*.env.example", true),
            ("project/.env", "*.env.*", false),    // nothing after ".env"
            ("README.md", "*.env", false),
        ]
        for (input, pattern, expected) in cases {
            #expect(wildcardMatch(input, pattern) == expected, "match(\(input), \(pattern))")
        }
    }
}

// MARK: - fromConfig  [next.test.ts F1..F12]

@Suite("fromConfig")
struct FromConfigTests {
    @Test("config -> ordered Ruleset")
    func rows() {
        #expect(fromConfig(cfg(("bash", act(.allow))), homeDirectory: HOME) == [r("bash", "*", .allow)])                 // F1
        #expect(
            fromConfig(cfg(("bash", pmap(("*", .allow), ("rm", .deny)))), homeDirectory: HOME)
                == [r("bash", "*", .allow), r("bash", "rm", .deny)])                                                     // F2
        #expect(
            fromConfig(cfg(("bash", pmap(("*", .allow), ("rm", .deny))), ("edit", act(.allow)), ("webfetch", act(.ask))),
                       homeDirectory: HOME)
                == [r("bash", "*", .allow), r("bash", "rm", .deny), r("edit", "*", .allow), r("webfetch", "*", .ask)])   // F3
        #expect(fromConfig(cfg(), homeDirectory: HOME) == [])                                                            // F4
        #expect(
            fromConfig(cfg(("external_directory", pmap(("~/projects/*", .allow)))), homeDirectory: HOME)
                == [r("external_directory", "\(HOME)/projects/*", .allow)])                                              // F5
        #expect(
            fromConfig(cfg(("external_directory", pmap(("$HOME/projects/*", .allow)))), homeDirectory: HOME)
                == [r("external_directory", "\(HOME)/projects/*", .allow)])                                              // F6
        #expect(
            fromConfig(cfg(("external_directory", pmap(("$HOME", .allow)))), homeDirectory: HOME)
                == [r("external_directory", HOME, .allow)])                                                              // F7
        #expect(
            fromConfig(cfg(("external_directory", pmap(("/some/~/path", .allow)))), homeDirectory: HOME)
                == [r("external_directory", "/some/~/path", .allow)])                                                    // F8 (no mid-string expand)
        #expect(
            fromConfig(cfg(("external_directory", pmap(("~", .allow)))), homeDirectory: HOME)
                == [r("external_directory", HOME, .allow)])                                                              // F12
        // order preservation (F9/F10)
        #expect(fromConfig(cfg(("*", act(.deny)), ("bash", act(.allow))), homeDirectory: HOME).map(\.permission) == ["*", "bash"])
        #expect(fromConfig(cfg(("bash", act(.allow)), ("*", act(.deny))), homeDirectory: HOME).map(\.permission) == ["bash", "*"])
        #expect(
            fromConfig(cfg(("bash", act(.allow)), ("*", act(.ask)), ("edit", act(.deny)), ("mcp_*", act(.allow))),
                       homeDirectory: HOME).map(\.permission) == ["bash", "*", "edit", "mcp_*"])                          // F10
        #expect(
            fromConfig(cfg(("bash", pmap(("*", .deny), ("git *", .allow)))), homeDirectory: HOME).map(\.pattern)
                == ["*", "git *"])                                                                                       // F11
    }

    @Test("null delete sentinels (kilocode)")
    func nullSentinels() {
        #expect(fromConfig(cfg(("bash", pmap(("*", .ask), ("npm *", nil)))), homeDirectory: HOME) == [r("bash", "*", .ask)])  // T12
        #expect(fromConfig(cfg(("bash", nil)), homeDirectory: HOME) == [])                                                    // T13
    }
}

// MARK: - evaluate via config  [next.test.ts E1..E11]

@Suite("evaluate via config")
struct EvaluateConfigTests {
    private func e(_ config: PermissionConfig, _ perm: String, _ pat: String) -> PermissionAction {
        evaluate(perm, pat, fromConfig(config, homeDirectory: HOME)).action
    }
    @Test("rows")
    func rows() {
        #expect(e(cfg(("*", act(.deny)), ("bash", act(.allow))), "bash", "ls") == .allow)                 // E1
        #expect(e(cfg(("bash", act(.allow)), ("*", act(.deny))), "bash", "ls") == .deny)                  // E2
        #expect(e(cfg(("*", act(.ask)), ("bash", act(.allow))), "edit", "foo.ts") == .ask)                // E3
        #expect(e(cfg(("*", act(.ask)), ("bash", act(.allow))), "bash", "ls") == .allow)                  // E4
        #expect(e(cfg(("bash", pmap(("*", .deny), ("git *", .allow)))), "bash", "rm foo") == .deny)        // E5
        #expect(e(cfg(("bash", pmap(("*", .deny), ("git *", .allow)))), "bash", "git status") == .allow)   // E6
        #expect(e(cfg(("*", act(.ask)), ("bash", act(.allow)), ("edit", act(.deny))), "bash", "ls") == .allow)     // E7
        #expect(e(cfg(("*", act(.ask)), ("bash", act(.allow)), ("edit", act(.deny))), "edit", "foo.ts") == .deny)  // E8
        #expect(e(cfg(("*", act(.ask)), ("bash", act(.allow)), ("edit", act(.deny))), "read", "foo.ts") == .ask)   // E9
        #expect(e(cfg(("external_directory", pmap(("~/projects/*", .allow)))), "external_directory", "\(HOME)/projects/file.txt") == .allow)     // E10
        #expect(e(cfg(("external_directory", pmap(("$HOME/projects/*", .allow)))), "external_directory", "\(HOME)/projects/file.txt") == .allow) // E11
    }
}

// MARK: - merge  [next.test.ts M1..M8]

@Suite("merge")
struct MergeTests {
    @Test("order-preserving concat + evaluate")
    func rows() {
        #expect(merge([r("bash", "*", .allow)], [r("bash", "*", .deny)]) == [r("bash", "*", .allow), r("bash", "*", .deny)])  // M1
        #expect(merge([r("bash", "*", .allow)], []) == [r("bash", "*", .allow)])                                              // M5
        // M7
        let m7 = merge([r("*", "*", .ask)], [r("bash", "*", .allow)])
        #expect(evaluate("bash", "ls", m7).action == .allow)
        #expect(evaluate("edit", "foo.ts", m7).action == .ask)
        // M8
        #expect(evaluate("bash", "ls", merge([r("bash", "*", .allow)], [r("bash", "*", .ask)])).action == .ask)
    }
}

// MARK: - evaluate on literal rulesets  [next.test.ts V1..V24]

@Suite("evaluate (literal rulesets, last-match-wins)")
struct EvaluateLiteralTests {
    @Test("rows")
    func rows() {
        #expect(evaluate("bash", "rm", [r("bash", "rm", .deny)]).action == .deny)                                       // V1
        #expect(evaluate("bash", "rm", [r("bash", "*", .allow)]).action == .allow)                                      // V2
        #expect(evaluate("bash", "rm", [r("bash", "*", .allow), r("bash", "rm", .deny)]).action == .deny)               // V3
        #expect(evaluate("bash", "rm", [r("bash", "rm", .deny), r("bash", "*", .allow)]).action == .allow)              // V4
        #expect(evaluate("edit", "src/foo.ts", [r("edit", "src/*", .allow)]).action == .allow)                          // V5
        #expect(evaluate("edit", "src/components/Button.tsx",
                         [r("edit", "src/*", .deny), r("edit", "src/components/*", .allow)]).action == .allow)          // V6
        #expect(evaluate("edit", "src/components/Button.tsx",
                         [r("edit", "src/components/*", .allow), r("edit", "src/*", .deny)]).action == .deny)           // V7
        #expect(evaluate("unknown_tool", "anything", [r("bash", "*", .allow)]).action == .ask)                          // V8
        #expect(evaluate("bash", "rm", []).action == .ask)                                                              // V9
        #expect(evaluate("edit", "etc/passwd", [r("edit", "src/*", .allow)]).action == .ask)                            // V10
        #expect(evaluate("edit", "src/secret.ts",
                         [r("edit", "*", .ask), r("edit", "src/*", .allow), r("edit", "src/secret.ts", .deny)]).action == .deny)  // V12
        #expect(evaluate("edit", "src/foo.ts",
                         [r("edit", "*", .ask), r("edit", "test/*", .deny), r("edit", "src/*", .allow)]).action == .allow)        // V13
        #expect(evaluate("bash", "/bin/rm", [r("bash", "*", .allow), r("bash", "/bin/rm", .deny)]).action == .deny)     // V14
        #expect(evaluate("bash", "/bin/rm", [r("bash", "/bin/rm", .deny), r("bash", "*", .allow)]).action == .allow)    // V15
        #expect(evaluate("bash", "rm", [r("*", "*", .deny)]).action == .deny)                                           // V16
        #expect(evaluate("bash", "rm", [r("*", "rm", .deny)]).action == .deny)                                          // V17
        #expect(evaluate("mcp_server_tool", "anything", [r("mcp_*", "*", .allow)]).action == .allow)                    // V18
        #expect(evaluate("bash", "rm", [r("*", "*", .deny), r("bash", "*", .allow)]).action == .allow)                  // V19
        #expect(evaluate("edit", "src/foo.ts", [r("*", "*", .deny), r("edit", "src/*", .allow)]).action == .allow)      // V20
        #expect(evaluate("mcp_dangerous", "anything",
                         [r("*", "*", .ask), r("mcp_*", "*", .allow), r("mcp_dangerous", "*", .deny)]).action == .deny) // V21
        #expect(evaluate("unknown_tool", "anything", [r("*", "*", .ask), r("bash", "*", .allow)]).action == .ask)       // V22
        #expect(evaluate("bash", "rm", [r("bash", "*", .allow), r("*", "*", .deny)]).action == .deny)                   // V23
        #expect(evaluate("bash", "rm", [r("bash", "*", .allow)], [r("bash", "rm", .deny)]).action == .deny)             // V24 (2 rulesets flattened)
    }
}

// MARK: - disabled  [next.test.ts D1..D10]

@Suite("disabledTools")
struct DisabledTests {
    @Test("rows")
    func rows() {
        #expect(disabledTools(["bash", "edit", "read"], [r("*", "*", .allow)]).isEmpty)                                 // D1
        #expect(disabledTools(["bash", "edit", "read"], [r("*", "*", .allow), r("bash", "*", .deny)]) == ["bash"])      // D2
        #expect(disabledTools(["edit", "write", "apply_patch", "bash"], [r("*", "*", .allow), r("edit", "*", .deny)])
                == ["edit", "write", "apply_patch"])                                                                    // D3
        #expect(disabledTools(["bash"], [r("bash", "*", .allow), r("bash", "rm *", .deny)]).isEmpty)                     // D4
        #expect(disabledTools(["bash", "edit"], [r("*", "*", .ask)]).isEmpty)                                           // D5
        #expect(disabledTools(["bash"], [r("bash", "*", .deny), r("bash", "echo *", .allow)]).isEmpty)                  // D6
        #expect(disabledTools(["bash"], [r("bash", "rm *", .deny), r("bash", "*", .allow)]).isEmpty)                    // D7
        #expect(disabledTools(["bash", "edit", "webfetch"],
                              [r("bash", "*", .deny), r("edit", "*", .deny), r("webfetch", "*", .deny)])
                == ["bash", "edit", "webfetch"])                                                                        // D8
        #expect(disabledTools(["bash", "edit", "read"], [r("*", "*", .deny)]) == ["bash", "edit", "read"])              // D9
        #expect(disabledTools(["bash", "edit", "read"], [r("*", "*", .deny), r("bash", "*", .allow)]) == ["edit", "read"]) // D10
    }
}

// MARK: - readHarden (.env guard)  [env-read.test.ts + derived]

@Suite("readHarden — .env secret guard")
struct ReadHardenTests {
    @Test("resolve-level env rows (E1..E3)")
    func resolveRows() {
        let base = fromConfig(cfg(("read", pmap(("*", .allow), ("*.env", .ask), ("*.env.*", .ask), ("*.env.example", .allow)))),
                              homeDirectory: HOME)
        let broad = fromConfig(cfg(("read", pmap(("*", .allow)))), homeDirectory: HOME)
        let set = merge(base, broad)
        #expect(decide("read", "project/.env", set) == .ask)            // E1: broad allow does not bypass env ask
        #expect(decide("read", "project/.env.local", set) == .ask)      // E2
        #expect(decide("read", "project/.env.example", set) == .allow)  // E3
    }

    @Test("harden unit rows")
    func hardenRows() {
        #expect(readHarden("read", "project/.env", r("read", "*", .allow)) == r("read", "*.env", .ask))
        #expect(readHarden("read", "project/.env.local", r("read", "*", .allow)) == r("read", "*.env.*", .ask))
        #expect(readHarden("read", "project/.env.example", r("read", "*", .allow)) == r("read", "*", .allow))  // example exception
        #expect(readHarden("read", ".env", r("*", "*", .allow)) == r("read", "*.env", .ask))                   // broad via permission=="*"
        #expect(readHarden("read", "project/.env", r("read", "project/.env", .allow)) == r("read", "project/.env", .allow))  // not broad
        #expect(readHarden("read", "src/index.ts", r("read", "*", .allow)) == r("read", "*", .allow))          // guard nil
        #expect(readHarden("write", "project/.env", r("write", "*", .allow)) == r("write", "*", .allow))       // not read
        #expect(readHarden("read", "project/.env", r("read", "*", .deny)) == r("read", "*", .deny))            // not allow
        #expect(readHarden("read", "project/.env", r("read", "*", .ask)) == r("read", "*", .ask))              // not allow
    }
}

// MARK: - bash arity  [arity.test.ts]

@Suite("bash arity prefix")
struct ArityTests {
    @Test("prefix rows")
    func prefixRows() {
        #expect(bashArityPrefix(["unknown", "command", "subcommand"]) == ["unknown"])
        #expect(bashArityPrefix(["touch", "foo.txt"]) == ["touch"])
        #expect(bashArityPrefix(["git", "checkout", "main"]) == ["git", "checkout"])
        #expect(bashArityPrefix(["docker", "run", "nginx"]) == ["docker", "run"])
        #expect(bashArityPrefix(["aws", "s3", "ls", "my-bucket"]) == ["aws", "s3", "ls"])
        #expect(bashArityPrefix(["npm", "run", "dev", "script"]) == ["npm", "run", "dev"])
        #expect(bashArityPrefix(["docker", "compose", "up", "service"]) == ["docker", "compose", "up"])
        #expect(bashArityPrefix(["consul", "kv", "get", "config"]) == ["consul", "kv", "get"])
        #expect(bashArityPrefix(["git", "checkout"]) == ["git", "checkout"])
        #expect(bashArityPrefix(["npm", "run", "dev"]) == ["npm", "run", "dev"])
        #expect(bashArityPrefix([]) == [])
        #expect(bashArityPrefix(["single"]) == ["single"])
        #expect(bashArityPrefix(["git"]) == ["git"])   // arity 2 but only 1 token -> clamped, no crash
    }

    @Test("always glob")
    func globRows() {
        #expect(bashAlwaysGlob(["git", "commit", "-m", "x"]) == "git commit *")
        #expect(bashAlwaysGlob(["npm", "run", "build"]) == "npm run build *")
        #expect(bashAlwaysGlob(["ls", "-la", "/tmp"]) == "ls *")
        #expect(bashAlwaysGlob(["gh", "pr", "list", "--state", "open"]) == "gh pr list *")
        #expect(bashAlwaysGlob(["rm", "-rf", "/"]) == "rm *")
    }

    @Test("all 136 table entries present")
    func tableCount() {
        #expect(arityTable.count == 136)
    }
}

// MARK: - toConfig  [next.toConfig.test.ts T1..T11]

@Suite("toConfig")
struct ToConfigTests {
    @Test("Ruleset -> config rows")
    func rows() {
        #expect(toConfig([r("read", "*", .allow)]) == cfg(("read", pmap(("*", .allow)))))                                     // T1
        #expect(toConfig([r("bash", "npm *", .allow)]) == cfg(("bash", pmap(("npm *", .allow)))))                             // T2
        #expect(toConfig([r("bash", "*", .ask), r("bash", "npm *", .allow)])
                == cfg(("bash", pmap(("*", .ask), ("npm *", .allow)))))                                                       // T3
        #expect(toConfig([r("read", "*", .allow), r("bash", "npm *", .allow), r("bash", "git *", .allow)])
                == cfg(("read", pmap(("*", .allow))), ("bash", pmap(("npm *", .allow), ("git *", .allow)))))                  // T4
        #expect(toConfig([]) == cfg())                                                                                        // T5
        #expect(toConfig([r("bash", "*", .ask), r("bash", "rm *", .deny)])
                == cfg(("bash", pmap(("*", .ask), ("rm *", .deny)))))                                                         // T6
        #expect(toConfig([r("websearch", "*", .allow)]) == cfg(("websearch", act(.allow))))                                   // T9 scalar-only
        #expect(toConfig([r("doom_loop", "bash", .allow)]) == cfg())                                                          // T10 scalar-only non-* dropped
        #expect(toConfig([r("websearch", "*", .allow), r("todowrite", "*", .allow), r("bash", "npm *", .allow)])
                == cfg(("websearch", act(.allow)), ("todowrite", act(.allow)), ("bash", pmap(("npm *", .allow)))))            // T11
    }

    @Test("round-trips through fromConfig always in object form (T7/T8)")
    func roundTrip() {
        let t7 = toConfig(fromConfig(cfg(("read", act(.allow)), ("bash", act(.ask))), homeDirectory: HOME))
        #expect(t7 == cfg(("read", pmap(("*", .allow))), ("bash", pmap(("*", .ask)))))                                        // T7
        let input = cfg(("bash", pmap(("*", .ask), ("npm *", .allow), ("git *", .allow))))
        let t8 = toConfig(fromConfig(input, homeDirectory: HOME))
        #expect(t8 == input)                                                                                                  // T8
    }
}
