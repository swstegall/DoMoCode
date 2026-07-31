// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Testing

import DoMoCore

// Every test that registers a secret builds its own `RedactionVault`. The
// registry on `RedactionVault.shared` is process-wide and append-only, and
// suites run in parallel — a test that registered into it would change what a
// concurrently running suite sees. Only the read-only façade tests touch the
// shared vault.

// MARK: - The literal registry

@Suite("Redaction: the literal registry")
struct RedactionRegistryTests {

    @Test("A registered secret is replaced wherever it appears")
    func registeredSecretIsReplaced() {
        let vault = RedactionVault()
        vault.register("hunter2correcthorse")
        #expect(
            vault.diagnostic("gateway said hunter2correcthorse is invalid, retry")
                == "gateway said [redacted] is invalid, retry"
        )
    }

    @Test("A secret shorter than eight characters is not registered")
    func shortSecretIsIgnored() {
        let vault = RedactionVault()
        vault.register("dev")
        #expect(vault.diagnostic("the dev server is down") == "the dev server is down")
    }

    @Test("A whitespace-only secret is not registered")
    func whitespaceOnlySecretIsIgnored() {
        let vault = RedactionVault()
        vault.register("        ")  // eight spaces: long enough, but not a secret
        let text = "column         aligned"  // nine spaces
        #expect(vault.diagnostic(text) == text)
    }

    @Test("A nil secret is ignored")
    func nilSecretIsIgnored() {
        let vault = RedactionVault()
        vault.register(nil)
        #expect(vault.diagnostic("nothing to hide here") == "nothing to hide here")
    }

    @Test("The longer of two overlapping secrets is replaced whole")
    func longestSecretWins() {
        let vault = RedactionVault()
        // Registered shortest first on purpose: insertion order must not decide
        // the outcome, or the tail of the longer secret survives beside the
        // placeholder.
        vault.register("longsecretvalue")
        vault.register("longsecretvalueEXTENDED")
        #expect(vault.diagnostic("x longsecretvalueEXTENDED y") == "x [redacted] y")
    }

    @Test("registerAll applies the same rules to every element")
    func registerAllAppliesTheSameRules() {
        let vault = RedactionVault()
        vault.registerAll(["hunter2correcthorse", "zz", "anothersecretvalue"])
        #expect(
            vault.diagnostic("a hunter2correcthorse b anothersecretvalue c zz d")
                == "a [redacted] b [redacted] c zz d"
        )
    }

    @Test("An empty registry leaves ordinary text untouched")
    func emptyRegistryIsTransparent() {
        let vault = RedactionVault()
        let text = "the build finished in 4.2 seconds with 0 warnings"
        #expect(vault.diagnostic(text) == text)
    }
}

// MARK: - Pattern rules

@Suite("Redaction: pattern rules")
struct RedactionPatternTests {

    @Test("URL userinfo goes, the host stays readable")
    func urlUserinfoIsRedactedButNotTheHost() {
        #expect(
            Redaction.patterns("cloning https://alice:hunter2@git.example.com/repo.git now")
                == "cloning https://[redacted]@git.example.com/repo.git now"
        )
    }

    @Test("Every userinfo span in a line is redacted")
    func everyUserinfoSpanIsRedacted() {
        #expect(
            Redaction.patterns("a https://u1:p1@h1.example.com b https://u2:p2@h2.example.com c")
                == "a https://[redacted]@h1.example.com b https://[redacted]@h2.example.com c"
        )
    }

    @Test(
        "A credential header's value is taken wholesale, its name is kept",
        arguments: [
            ("Authorization: Bearer sk-1234567890ABCDEFGH", "Authorization: [redacted]"),
            ("authorization: abcdef", "authorization: [redacted]"),
            ("PROXY-AUTHORIZATION: Basic Zm9vOmJhcg==", "PROXY-AUTHORIZATION: [redacted]"),
            ("X-Api-Key: 12345", "X-Api-Key: [redacted]"),
            ("Api-Key: 12345", "Api-Key: [redacted]"),
            ("Cookie: session=abc123; theme=dark", "Cookie: [redacted]"),
            ("Set-Cookie: sid=xyz; HttpOnly", "Set-Cookie: [redacted]"),
        ])
    func headerValuesAreRedacted(input: String, expected: String) {
        #expect(Redaction.patterns(input) == expected)
    }

    @Test("A header rule stops at the end of its line")
    func headerRuleIsLineBounded() {
        let text = "HTTP/1.1 401\r\nAuthorization: Bearer sk-1234567890ABCDEFGH\r\nX-Request-Id: req_9\r\n"
        #expect(
            Redaction.patterns(text)
                == "HTTP/1.1 401\r\nAuthorization: [redacted]\r\nX-Request-Id: req_9\r\n"
        )
    }

    @Test("A header with no value is left alone rather than given a fake secret")
    func emptyHeaderValueIsNotInvented() {
        #expect(Redaction.patterns("Cookie:") == "Cookie:")
        #expect(Redaction.patterns("Cookie:   ") == "Cookie:   ")
    }

    @Test(
        "Every recognized vendor token prefix is redacted",
        arguments: [
            "sk-1234567890ABCDEFGH",
            "sk-ant-api03-AAAAAAAAAAAAAAAA",
            "sk-proj-BBBBBBBBBBBBBBBBBBBB",
            "sk_live_51H8xYzABCDEFGHIJKLMN",
            "pk_live_51H8xYzABCDEFGHIJKLMN",
            "ghp_16C7e42F292c6912E7710c838347Ae178B4a",
            "gho_16C7e42F292c6912E7710c838347Ae178B4a",
            "github_pat_11ABCDEFG0abcdefghijkl_ABCDEFGHIJKLMNOP",
            "xox" + "b-123456789012-1234567890123-abcdefghijklmnopqrst",
            "xox" + "p-123456789012-1234567890123-abcdefghijklmnopqrst",
            "AKIAIOSFODNN7EXAMPLE",
        ])
    func tokenPrefixesAreRedacted(token: String) {
        #expect(Redaction.patterns("key \(token) end") == "key [redacted] end")
    }

    @Test("A token at the very start of the text is redacted too")
    func tokenAtStartOfStringIsRedacted() {
        #expect(
            Redaction.patterns("sk-1234567890ABCDEFGH is the key")
                == "[redacted] is the key"
        )
    }

    @Test("A quote before a token is not eaten with it")
    func quoteAroundTokenSurvives() {
        #expect(
            Redaction.patterns(#""api_key":"sk-1234567890ABCDEFGH""#)
                == #""api_key":"[redacted]""#
        )
    }

    @Test("The full stop after a token is punctuation, not key material")
    func sentencePunctuationSurvives() {
        #expect(
            Redaction.patterns("the key is sk-1234567890ABCDEFGH. Rotate it.")
                == "the key is [redacted]. Rotate it."
        )
    }

    @Test("A bearer run is redacted, the scheme word is kept")
    func bearerRunIsRedacted() {
        #expect(
            Redaction.patterns("got Bearer abcdefghijklmnopqrstuvwxyz here")
                == "got Bearer [redacted] here"
        )
    }

    @Test("The bearer rule does not care about case or which blank separates it")
    func bearerRuleIsCaseAndSeparatorInsensitive() {
        #expect(
            Redaction.patterns("GOT BEARER ABCDEFGHIJKLMNOPQRSTUVWXYZ HERE")
                == "GOT BEARER [redacted] HERE"
        )
        #expect(
            Redaction.patterns("Bearer\tabcdefghijklmnopqrstuvwx")
                == "Bearer\t[redacted]"
        )
    }

    @Test("A gateway error body loses only the key it echoed")
    func gatewayErrorBodyKeepsItsStructure() {
        // The reason this module exists: LiteLLM's 401 body quotes the key back,
        // and that body is persisted verbatim as an assistant error message.
        let body = #"{"error":{"message":"Incorrect API key provided: sk-1234567890ABCDEFGH. Find yours at https://x.example.com/keys.","code":"invalid_api_key"}}"#
        #expect(
            Redaction.patterns(body)
                == #"{"error":{"message":"Incorrect API key provided: [redacted]. Find yours at https://x.example.com/keys.","code":"invalid_api_key"}}"#
        )
    }

    @Test("Redacting already-redacted text changes nothing further")
    func patternsAreIdempotent() {
        let once = Redaction.patterns("key sk-1234567890ABCDEFGH end")
        #expect(once == "key [redacted] end")
        #expect(Redaction.patterns(once) == once)
    }
}

// MARK: - Over-redaction

@Suite("Redaction: what must survive")
struct RedactionSurvivalTests {

    @Test(
        "Text that only looks secret is left exactly as it was",
        arguments: [
            // A git SHA is forty characters of hex. An entropy heuristic eats
            // it; this module has none, deliberately.
            "commit a94a8fe5ccb19ba61c4c0873d391e987982fbbd3 is green",
            // A UUIDv7 session id — the harness prints these constantly.
            "session 01920e5c-7c3a-7f1e-9b2d-6f4a1c8e5d30 resumed",
            // Inline image payloads reach diagnostics whole.
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ",
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
            // Ordinary prose, including a colon.
            "The gateway refused the request: the account has no remaining credit.",
            // `sk-` buried in a word. The rule consumes a boundary character to
            // stop exactly this.
            "task-1234567890123456 completed",
            "run at 12:30:45 with timeout 30s",
            // A port is a colon after a host, not userinfo.
            "https://git.example.com:8443/repo.git",
            "See https://docs.example.com/guide#section for details",
            // Too short to be a credential run.
            "sk-short",
            "Bearer short",
            "let x = a?b:c; const y=[1,2,3].map(v=>v*2);",
            "/Users/sam/Programming/DoMoCode/Sources/DoMoCore/Redaction.swift:42:11",
        ])
    func innocentTextSurvives(text: String) {
        #expect(Redaction.patterns(text) == text)
    }
}

// MARK: - Key names

@Suite("Redaction: key names")
struct RedactionKeyNameTests {

    @Test(
        "A name that announces a credential is recognized however it is spelled",
        arguments: [
            "api_key", "apiKey", "X-API-KEY", "password", "passwd", "access_token",
            "refresh_token", "credentials", "authorization", "private_key",
            "AccessKeyId", "session_key", "client_secret", "Bearer",
        ])
    func secretNamesAreRecognized(name: String) {
        #expect(Redaction.isSecretKeyName(name))
    }

    @Test(
        "A token counter is never a secret — the allow-list runs first",
        arguments: [
            "max_tokens", "input_tokens", "output_tokens", "total_tokens",
            "prompt_tokens", "completion_tokens", "cached_tokens", "reasoning_tokens",
            "tokens_before", "token_count", "prompt_tokens_details",
            "completion_tokens_details", "cache_read_input_tokens",
        ])
    func tokenCountersAreNotSecrets(name: String) {
        #expect(!Redaction.isSecretKeyName(name))
    }

    @Test(
        "Ordinary payload keys are not secrets",
        arguments: [
            "model", "temperature", "content", "role", "cost", "cacheRead",
            "cacheWrite", "reasoning", "input", "output", "reportedCost", "",
        ])
    func ordinaryNamesAreNotSecrets(name: String) {
        #expect(!Redaction.isSecretKeyName(name))
    }

    @Test("Every credential environment variable is recognized by name")
    func credentialEnvironmentNamesAreRecognized() {
        // A scrub site that filters an environment by `isSecretKeyName` must not
        // miss the very variables this module names. If the two lists ever drift,
        // the gateway key leaks into MCP and tool children.
        #expect(Redaction.secretEnvironmentNames.contains("DOMOCODE_API_KEY"))
        #expect(Redaction.secretEnvironmentNames.contains("LITELLM_API_KEY"))
        #expect(Redaction.secretEnvironmentNames.contains("OPENAI_API_KEY"))
        #expect(Redaction.secretEnvironmentNames.allSatisfy { Redaction.isSecretKeyName($0) })
    }
}

// MARK: - JSON

@Suite("Redaction: JSON values")
struct RedactionJSONTests {

    @Test("A provider usage object round-trips completely unchanged")
    func usageObjectSurvivesUntouched() {
        // The most important test in this file. Every key here contains the
        // substring `token`, so without the allow-list in `isSecretKeyName`
        // every number an honest cost total depends on becomes "[redacted]".
        let usage: JSONValue = [
            "prompt_tokens": 12_345,
            "completion_tokens": 678,
            "total_tokens": 13_023,
            "max_tokens": 8192,
            "prompt_tokens_details": ["cached_tokens": 4096],
            "completion_tokens_details": ["reasoning_tokens": 512],
            "tokens_before": 900,
            "token_count": 42,
        ]
        #expect(RedactionVault().redact(usage) == usage)
    }

    @Test("DoMoCode's own Usage shape round-trips completely unchanged")
    func domocodeUsageShapeSurvivesUntouched() {
        let usage: JSONValue = [
            "input": 1200,
            "output": 340,
            "cacheRead": 0,
            "cacheWrite": 0,
            "reasoning": 128,
            "cost": [
                "input": 0.0123, "output": 0.45, "cacheRead": 0.0, "cacheWrite": 0.0,
            ],
            "reportedCost": 0.0021,
        ]
        #expect(RedactionVault().redact(usage) == usage)
    }

    @Test("A member whose key names a credential is replaced, its siblings are not")
    func secretKeysAreReplaced() {
        let body: JSONValue = [
            "api_key": "wholly-unrecognizable-value",
            "model": "gpt-5",
            "temperature": 0.7,
        ]
        let redacted = RedactionVault().redact(body)
        #expect(redacted["api_key"] == .string("[redacted]"))
        #expect(redacted["model"] == .string("gpt-5"))
        #expect(redacted["temperature"] == .double(0.7))
    }

    @Test("A null under a credential key stays null")
    func nullUnderSecretKeyIsNotInvented() {
        // Rewriting it would claim a credential was present when none was.
        #expect(RedactionVault().redact(["password": nil]) == ["password": nil])
    }

    @Test("String leaves are scrubbed at any depth")
    func stringLeavesAreScrubbedAtDepth() {
        let payload: JSONValue = [
            "messages": [
                ["role": "user", "content": "hello"],
                ["role": "assistant", "content": "use Bearer abcdefghijklmnopqrstuvwx please"],
            ]
        ]
        let redacted = RedactionVault().redact(payload)
        #expect(redacted["messages"]?[1]?["content"] == .string("use Bearer [redacted] please"))
        #expect(redacted["messages"]?[0]?["content"] == .string("hello"))
    }

    @Test("The registry applies inside JSON strings too")
    func registeredSecretsAreScrubbedInsideJSON() {
        let vault = RedactionVault()
        vault.register("hunter2correcthorse")
        #expect(
            vault.redact(["detail": "rejected hunter2correcthorse"])
                == ["detail": .string("rejected [redacted]")]
        )
    }
}

// MARK: - Headers

@Suite("Redaction: header dictionaries")
struct RedactionHeaderTests {

    @Test("Credential headers lose their value, everything else is kept")
    func credentialHeadersLoseTheirValue() {
        let headers = [
            "Authorization": "Bearer sk-1234567890ABCDEFGH",
            "Set-Cookie": "sid=xyz",
            "Content-Type": "application/json",
            "X-Request-Id": "req_abc123",
        ]
        let redacted = RedactionVault().redact(headers: headers)
        #expect(redacted["Authorization"] == "[redacted]")
        // `Cookie` carries none of the credential markers a key name is tested
        // for, so this fails the moment the header-name set is dropped.
        #expect(redacted["Set-Cookie"] == "[redacted]")
        #expect(redacted["Content-Type"] == "application/json")
        #expect(redacted["X-Request-Id"] == "req_abc123")
        #expect(redacted.count == headers.count)
    }

    @Test("An ordinary header's value is still pattern-scrubbed")
    func ordinaryHeaderValuesAreScrubbed() {
        // A redirect can carry a password in URL userinfo, which no name-based
        // rule would ever catch.
        let redacted = RedactionVault().redact(headers: ["Location": "https://u:pw@example.com/next"])
        #expect(redacted["Location"] == "https://[redacted]@example.com/next")
    }

    @Test("A registered secret is removed from an ordinary header's value")
    func registeredSecretsAreRemovedFromHeaderValues() {
        let vault = RedactionVault()
        vault.register("hunter2correcthorse")
        let redacted = vault.redact(headers: ["X-Trace": "attempt with hunter2correcthorse"])
        #expect(redacted["X-Trace"] == "attempt with [redacted]")
    }
}

// MARK: - The shared façade

@Suite("Redaction: the shared façade")
struct RedactionFacadeTests {

    // These read `RedactionVault.shared` but never register into it, so they
    // stay independent of whatever else is running.

    @Test("The placeholder is the exact string other surfaces match on")
    func placeholderIsPinned() {
        #expect(Redaction.placeholder == "[redacted]")
    }

    @Test("The static diagnostic applies the pattern rules")
    func staticDiagnosticAppliesPatterns() {
        #expect(
            Redaction.diagnostic("Authorization: Bearer abcdefghijklmnopqrstuvwx")
                == "Authorization: [redacted]"
        )
    }

    @Test("The static header and JSON entry points scrub as the vault does")
    func staticEntryPointsScrub() {
        #expect(Redaction.redact(headers: ["Authorization": "Bearer x"]) == ["Authorization": "[redacted]"])
        #expect(Redaction.redact(["api_key": "value"] as JSONValue) == ["api_key": "[redacted]"])
    }
}
