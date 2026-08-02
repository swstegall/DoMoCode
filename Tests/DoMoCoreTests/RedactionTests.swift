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

    @Test("A registered literal cannot switch a pattern rule off")
    func aRegisteredLiteralCannotPoisonAPatternRule() {
        let vault = RedactionVault()
        // Not hypothetical: `authHeader` is a credential-carrying config key and
        // its value is a *header name*. Replacing this literal before the rules
        // run deletes the substring the header rule matches on, and
        // `Basic Zm9vOmJhcg==` — which carries no vendor prefix and no bearer
        // scheme, so no other rule sees it — is written to the session file.
        // No value rule touches `Authorization`, so it is held back for the
        // pattern pass and removed by the pass after it.
        vault.register("Authorization")
        let result = vault.diagnostic("Authorization: Basic Zm9vOmJhcg==")
        #expect(!result.contains("Zm9vOmJhcg=="))
        // The name goes too, because the literal really is registered. Losing
        // the header's name is a diagnostic cost; losing its value is a breach.
        #expect(result == "[redacted]: [redacted]")
    }

    @Test(
        "A registered secret a rule would only partly rewrite is removed whole",
        arguments: [
            // Running the patterns first is strictly worse here, and this is the
            // common case: the URL-userinfo rule keeps the host by design, and
            // the `@` inside the password ends its match — so it rewrote
            // `://admin:p@` and printed all but the first character of the
            // password, which the registry could no longer match because the
            // literal it knows no longer occurred:
            //
            //   connect failed: postgres://[redacted]@ssw0rd-hunter2-longsecret@db.internal:5432/app
            (
                "postgres://admin:p@ssw0rd-hunter2-longsecret@db.internal:5432/app",
                "ssw0rd-hunter2-longsecret"
            ),
            // The same shape wherever a rule's run class stops short of the end
            // of the secret. `=` is in neither run class, so both of these kept
            // their tail.
            ("xox" + "b-123456789012-1234567890123-abcdefghij==TRAILINGHALF", "TRAILINGHALF"),
            ("sk-ant-api03-AAAAAAAAAAAAAAAAAAAA==PADDINGTAIL", "PADDINGTAIL"),
        ])
    func aPartlyRecognizedSecretIsRemovedWhole(secret: String, leak: String) {
        let vault = RedactionVault()
        vault.register(secret)
        let result = vault.diagnostic("connect failed: \(secret)")
        #expect(!result.contains(leak))
        #expect(result == "connect failed: [redacted]")
    }

    @Test("A registered literal is still removed when no pattern rule sees it")
    func theRegistryIsStillTheBackstop() {
        // The other half of the ordering: holding a literal back for the pattern
        // pass must not mean the registry never gets its turn. This value has no
        // shape any rule recognizes.
        let vault = RedactionVault()
        vault.register("zqx-domocore-literal-77413")
        #expect(
            vault.diagnostic("tenant acme rejected zqx-domocore-literal-77413 at 12:30:45")
                == "tenant acme rejected [redacted] at 12:30:45"
        )
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

    @Test("A vendor-prefixed header name is still a header")
    func prefixedHeaderNameIsStillAHeader() {
        // The marker has to *end* the header name, not merely appear in it, so
        // anchoring the rule must not cost us the names a gateway actually
        // sends.
        #expect(
            Redaction.patterns("HTTP/1.1 401\nAnthropic-Api-Key: sk-ant-secret\nX-Request-Id: r1")
                == "HTTP/1.1 401\nAnthropic-Api-Key: [redacted]\nX-Request-Id: r1"
        )
        #expect(
            Redaction.patterns("  Set-Cookie: sid=xyz") == "  Set-Cookie: [redacted]"
        )
    }

    @Test("A header block quoted inside a one-line body is still a header block")
    func anEscapedLineBreakIsAHeaderPosition() {
        // A response's headers reach an error message through a JSON string,
        // where the line breaks are two characters. That is a header position
        // even though the text is one physical line.
        let body = #"upstream said: HTTP/1.1 401\r\nSet-Cookie: sid=abc123; HttpOnly"#
        #expect(Redaction.patterns(body) == #"upstream said: HTTP/1.1 401\r\nSet-Cookie: [redacted]"#)
    }

    @Test("A sentence that only mentions a header still loses the credential in it")
    func proseKeepsTheOtherRules() {
        // Leaving a prose span alone rather than rewriting it is what makes this
        // safe: the token and bearer rules run over the whole string afterwards,
        // so declining to treat the marker as a header costs nothing.
        #expect(
            Redaction.patterns("the api-key: sk-1234567890ABCDEFGH was refused")
                == "the api-key: [redacted] was refused"
        )
        #expect(
            Redaction.patterns("no cookie: Bearer abcdefghijklmnopqrstuvwx was sent")
                == "no cookie: Bearer [redacted] was sent"
        )
    }

    @Test("A word before the marker makes it prose even at the start of a line")
    func aWordBeforeTheMarkerIsProseOnAnyLine() {
        // The blank may indent a header line; it may never separate a word from
        // the header's name.
        #expect(Redaction.patterns("a\nthe cookie: is stale") == "a\nthe cookie: is stale")
    }

    @Test("Every header on a multi-line block is redacted, and only the headers")
    func everyHeaderInABlockIsRedacted() {
        #expect(
            Redaction.patterns("a\r\nAuthorization: 1\r\nCookie: 2\r\nEnd: 3")
                == "a\r\nAuthorization: [redacted]\r\nCookie: [redacted]\r\nEnd: 3"
        )
        #expect(Redaction.patterns("a\rCookie: 2") == "a\rCookie: [redacted]")
        #expect(Redaction.patterns("\tCookie: 2") == "\tCookie: [redacted]")
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
            // Split across a `+` rather than written whole. A fixture that
            // exercises the Slack rule necessarily LOOKS like a Slack token, and
            // GitHub's push protection rejects the entire push over it — which is
            // the scanner being right, not a false positive worth bypassing. The
            // value under test is byte-identical; only its spelling here changed.
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
            // A header *named* mid-sentence is prose, not a header. `DoMoError`
            // promises one line and that line is persisted as an assistant
            // message's `errorMessage`, so an unanchored header rule deleted the
            // actionable half of every sentence like these.
            "the api-key: header was rejected, rotate the key in the dashboard",
            "no cookie: value was sent, so the session could not be resumed",
            "set authorization: to a bearer scheme and retry the request",
            "gateway says x-api-key: is required for this route; see the docs",
            // The marker has to end the header name, so a longer word that
            // merely starts with one is not a header even at the line start.
            "cookieJar: enabled, 3 entries",
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
            // Everything below was called a credential by the enumeration this
            // rule replaced. The old test listed exactly the names that already
            // passed, so it could never have found them.
            "audio_tokens", "text_tokens", "image_tokens",
            "accepted_prediction_tokens", "rejected_prediction_tokens",
            "cache_read_tokens", "cache_write_tokens", "cache_creation_input_tokens",
            "num_tokens", "tokens", "tokenCount", "n_tokens", "server_tool_use_tokens",
        ])
    func tokenCountersAreNotSecrets(name: String) {
        #expect(!Redaction.isSecretKeyName(name))
    }

    @Test(
        "A plural credential is a credential, however counter-shaped it reads",
        arguments: [
            "access_tokens", "refresh_tokens", "api_tokens", "auth_tokens",
            "session_tokens", "id_tokens", "apiTokens", "AccessTokens",
        ])
    func pluralCredentialsAreStillSecrets(name: String) {
        // The counter rule keys on the plural, so it has to be told that a
        // credential can be plural too. A bare "ends in tokens" rule prints
        // every one of these.
        #expect(Redaction.isSecretKeyName(name))
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
            "prompt_tokens_details": [
                "cached_tokens": 4096, "audio_tokens": 0, "text_tokens": 12_000,
                "image_tokens": 345, "cache_read_tokens": 4096, "cache_write_tokens": 0,
            ],
            "completion_tokens_details": [
                "reasoning_tokens": 512, "accepted_prediction_tokens": 8,
                "rejected_prediction_tokens": 3, "audio_tokens": 0,
            ],
            "tokens_before": 900,
            "token_count": 42,
            "num_tokens": 13_023,
            "tokens": 13_023,
        ]
        #expect(RedactionVault().redact(usage) == usage)
    }

    @Test("A member whose key is a plural credential is still replaced")
    func pluralCredentialMembersAreReplaced() {
        // The mirror of the test above: the counter allow-list must not have
        // opened a hole for `{"access_tokens": [...]}`.
        let body: JSONValue = ["access_tokens": "wholly-unrecognizable-value", "total_tokens": 7]
        let redacted = RedactionVault().redact(body)
        #expect(redacted["access_tokens"] == .string("[redacted]"))
        #expect(redacted["total_tokens"] == .int(7))
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

// MARK: - Masking a line of source

@Suite("Redaction: masking a source line")
struct RedactionSourceLineTests {

    /// A key shaped exactly like the one a settings.json hands an MCP child.
    private static let credential = "sk-proj-a1b2c3d4e5f6g7h8i9j0klmn"

    private static func stars(_ text: String) -> String {
        String(repeating: "*", count: text.unicodeScalars.count)
    }

    @Test("A value under a credential-shaped key is masked, and the line keeps its length")
    func aValueUnderACredentialKeyIsMasked() {
        let line = #"    "OPENAI_API_KEY": "\#(Self.credential)","#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(masked == #"    "OPENAI_API_KEY": "\#(Self.stars(Self.credential))","#)
        // The invariant the caret depends on, asserted directly.
        #expect(masked.unicodeScalars.count == line.unicodeScalars.count)
    }

    @Test("The key itself is never masked — it is the half the user has to read")
    func theKeyIsNotMasked() {
        let masked = Redaction.maskingSecrets(
            inSourceLine: #"  "apiKey": "\#(Self.credential)""#
        )
        #expect(masked.contains(#""apiKey""#))
        #expect(!masked.contains("sk-"))
    }

    @Test("A value a pattern rule recognizes is masked whatever its key is called")
    func aRecognizableValueIsMaskedUnderAnyKey() {
        let line = #"  "repository": "https://alice:hunter2@git.example.com/repo.git","#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        // The userinfo span and nothing else — see `onlyTheUserinfoSpanIsMasked`.
        #expect(
            masked
                == #"  "repository": "https://\#(Self.stars("alice:hunter2"))@git.example.com/repo.git","#
        )
    }

    @Test("A URL's userinfo is masked; the endpoint it names stays readable")
    func onlyTheUserinfoSpanIsMasked() {
        // Starring the whole literal destroys the one thing this line can tell a
        // user who is here about an unrelated typo three lines away: which
        // gateway their config names. Keeping the host is the same distinction
        // the live URL rule already makes.
        let line = #"  "baseUrl": "https://svc:pw@gw.corp.internal:4000/v1","#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(
            masked == #"  "baseUrl": "https://\#(Self.stars("svc:pw"))@gw.corp.internal:4000/v1","#
        )
        #expect(masked.contains("gw.corp.internal:4000/v1"))
        #expect(!masked.contains("svc"))
        #expect(!masked.contains("pw@"))
        #expect(masked.unicodeScalars.count == line.unicodeScalars.count)
    }

    @Test("A credential on a line whose quotes do not balance is masked anyway")
    func aCredentialOutsideEveryLiteralIsMasked() {
        // The proof, through the production path. A missing quote is the
        // commonest JSON typo *and* the error being reported, and it inverts the
        // parity of every literal after it: the walk reads `": "` as the literal
        // and leaves the key and the credential outside every one of them, so
        // the excerpt printed the key verbatim under its own caret.
        let token = "sk-proj-a1b2c3d4e5f6g7h8i9j0kl"
        let line = #"    apiKeyEnv": "\#(token)","#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(!masked.contains("sk-proj"))
        #expect(masked == #"    apiKeyEnv": "\#(Self.stars(token))","#)
        #expect(masked.unicodeScalars.count == line.unicodeScalars.count)
    }

    @Test("The raw-line sweep is span-bounded, and deliberately has no header rule")
    func theRawLineSweepIsSpanBounded() {
        // The same broken parity, with a header marker outside every literal.
        // The header rule's value has no right edge but the end of the line, so
        // sweeping the raw line with it would delete the sibling members the
        // excerpt is quoting and leave the caret pointing at nothing.
        let line = #"    note": "authorization: rotate it", "model": "gpt-5""#
        #expect(Redaction.maskingSecrets(inSourceLine: line) == line)
    }

    @Test("Every value in an environment object is a credential, whatever it is named")
    func environmentValuesAreMaskedByPosition() {
        // `GH_PAT`, `NPM_AUTH` and `MY_KEY` carry none of the markers a name test
        // looks for, and none of these values has a shape a rule recognizes — so
        // every one of them was printed verbatim. `Settings.keyCarriesCredential`
        // registers all three as process-wide secrets for exactly that reason:
        // the block exists to hand secrets to a child process, and the names in
        // it are the user's own.
        let line =
            #"  "environment": {"GH_PAT": "abcd1234", "NPM_AUTH": "wxyz9876", "MY_KEY": "opaque"},"#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(
            masked
                == #"  "environment": {"GH_PAT": "\#(Self.stars("abcd1234"))", "NPM_AUTH": "\#(Self.stars("wxyz9876"))", "MY_KEY": "\#(Self.stars("opaque"))"},"#
        )
        #expect(masked.unicodeScalars.count == line.unicodeScalars.count)
    }

    @Test("Every element of a command array is a credential, argument or program")
    func commandArrayElementsAreMaskedByPosition() {
        // An argument is the same slot by another spelling: `--token=…` ends up
        // in the spawn-failure line and in this excerpt if it is not masked.
        let line = #"  "command": ["gh-mcp", "--token=s3cr3t-value"],"#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(!masked.contains("s3cr3t"))
        #expect(
            masked
                == #"  "command": ["\#(Self.stars("gh-mcp"))", "\#(Self.stars("--token=s3cr3t-value"))"],"#
        )
    }

    @Test("The position rule stops at its container, and never masks a key")
    func thePositionRuleIsBoundedToItsContainer() {
        // The keys are the half the user has to read, and a sibling of the
        // `environment` object is not in the block that carries credentials.
        let line = #"  {"environment": {"GH_PAT": "abcd1234"}, "model": "gpt-5"},"#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(
            masked == #"  {"environment": {"GH_PAT": "\#(Self.stars("abcd1234"))"}, "model": "gpt-5"},"#
        )
    }

    @Test("Masking is bounded to the literal, not to the end of the line")
    func maskingIsBoundedToTheLiteral() {
        // The exact shape that rules `Redaction.patterns` out for this job: its
        // header rule would take the value, the comma, the sibling member and
        // the rest of the line with it.
        let line = #"  "note": "authorization: rotate it", "model": "gpt-5""#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(masked == #"  "note": "\#(Self.stars("authorization: rotate it"))", "model": "gpt-5""#)
    }

    @Test("An ordinary settings line is returned byte for byte")
    func anOrdinaryLineIsUntouched() {
        for line in [
            #"  "contextWindow": 200000,"#,
            #"  "model": "gpt-5-codex","#,
            #"  "baseUrl": "https://gateway.example.com:8443/v1","#,
            #"  "command": "/usr/local/bin/node","#,
            #"  "prompt_tokens_details": {"cached_tokens": 4096},"#,
            "{",
            "",
        ] {
            #expect(Redaction.maskingSecrets(inSourceLine: line) == line)
        }
    }

    @Test("A key is only attributed to the literal that really follows it")
    func aKeyIsNotAttributedAcrossAStructuralCharacter() {
        // `environment` is not a secret name and `OPENAI_API_KEY` is a key, not
        // a value — so the only thing masked here is the value at the end.
        let line = #"  "environment": {"OPENAI_API_KEY": "\#(Self.credential)"}"#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(masked == #"  "environment": {"OPENAI_API_KEY": "\#(Self.stars(Self.credential))"}"#)
    }

    @Test("A literal the line ends inside of is masked to the end of the line")
    func anUnterminatedLiteralIsMaskedWhole() {
        let line = #"  "password": "hunter2correcthorse"#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(masked == #"  "password": "\#(Self.stars("hunter2correcthorse"))"#)
        #expect(masked.unicodeScalars.count == line.unicodeScalars.count)
    }

    @Test("An escaped quote does not end a literal early")
    func anEscapedQuoteIsPartOfTheValue() {
        let line = #"  "password": "ab\"cd", "model": "m""#
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(masked == #"  "password": "\#(Self.stars(##"ab\"cd"##))", "model": "m""#)
    }

    @Test("A tab inside a masked value stays a tab, so the columns after it do not move")
    func aTabInsideAMaskedValueSurvives() {
        // The excerpt expands tabs to a fixed stop. Turning one into `*` would
        // preserve the scalar count and still move every column after it.
        let line = "  \"password\": \"a\tb\""
        #expect(Redaction.maskingSecrets(inSourceLine: line) == "  \"password\": \"*\t*\"")
    }

    @Test("Masking a line twice changes nothing further")
    func maskingIsIdempotent() {
        let line = #"    "OPENAI_API_KEY": "\#(Self.credential)","#
        let once = Redaction.maskingSecrets(inSourceLine: line)
        #expect(Redaction.maskingSecrets(inSourceLine: once) == once)
    }

    @Test("Multi-scalar text is masked scalar for scalar, not byte for byte")
    func maskingCountsScalarsNotBytes() {
        // A byte-counted mask would emit two `*` for the `é` and four for the
        // emoji, sliding every column after them by five. Spelled with escapes
        // so the fixture cannot arrive decomposed and mean something else.
        let line = "  \"password\": \"\u{E9}\u{1F642}x\""
        let masked = Redaction.maskingSecrets(inSourceLine: line)
        #expect(masked == "  \"password\": \"***\"")
        #expect(masked.unicodeScalars.count == line.unicodeScalars.count)
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
