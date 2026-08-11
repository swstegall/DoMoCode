# MCP OAuth (browser login for remote servers)

DoMoCode can connect to a remote MCP server whose identity provider requires an
interactive login, by running the standard OAuth 2.0 **authorization-code +
PKCE** flow: open the system browser, capture the redirect on a loopback
listener, exchange the code for a bearer token, and refresh it silently for the
life of the session. The implementation is generic — it works for any provider
that speaks the flow — and covers both ends of the spectrum:

- **Zero-config discovery** for servers that implement the MCP authorization
  spec (protected-resource metadata → authorization-server metadata → dynamic
  client registration).
- **Explicit endpoints + a pre-registered client id** for enterprise IdPs that
  support none of that. Microsoft **ADFS** is the archetype and shaped several
  design decisions below.

Nothing here is provider-specific in the code; a provider's endpoints and
client id live entirely in the user's `settings.json`.

## Configuration

A remote MCP server opts into OAuth with an `oauth` block (see the README's
"Remote MCP servers and OAuth" section for the settings schema and examples).
Every field is optional:

| Field | Meaning | Default |
|---|---|---|
| `authorizationEndpoint` | OAuth authorize URL | discovered |
| `tokenEndpoint` | OAuth token URL | discovered |
| `clientId` | pre-registered public client id | dynamically registered |
| `scope` | space-separated scopes | from challenge / metadata, else none |
| `resource` | RFC 8707 resource indicator | the server's canonical URL |
| `redirectUri` | loopback redirect, exactly as registered | `http://127.0.0.1:27182/oauth/callback` |
| `cacheKey` | token-store namespace | the server name |

An empty `{}` means full discovery; `authorizationEndpoint` + `tokenEndpoint` +
`clientId` means explicit configuration. The two endpoints must be set together
or not at all.

## Architecture

All of it lives in `Sources/DoMoMCP/OAuth/`, behind one public entry point,
`MCPOAuthProvider.accessToken(...)`. The MCP client never learns how a token is
produced; it asks for one per request.

```
MCPManager.connect
   │  builds an MCPOAuthProvider per oauth server, acquires a token BEFORE the
   │  connect-retry loop (so a retry never re-opens the browser), and hands
   │  MCPClient an async token-provider closure
   ▼
MCPClient.sendRemote ──ask──▶ MCPOAuthProvider.accessToken(forceRefresh:…)
   │  attaches Bearer; on 401 asks once more with forceRefresh + the rejected
   │  token + the server's WWW-Authenticate challenge, replays the request once
   ▼
MCPOAuthProvider
   ├─ cached token (usable)                → return
   ├─ refresh_token grant (silent)         → OAuthHTTP → token endpoint
   └─ interactive flow (browser)           → OAuthDiscovery + DynamicClientRegistration
                                              + PKCE + OAuthLoopbackListener
                                              (+ SelfSignedCertificate for https)
        persist → OAuthTokenStore (0600 file, 0700 dir, file-locked, URL-bound)
```

| File | Responsibility |
|---|---|
| `MCPOAuthProvider.swift` | the orchestrator: cheap-token → refresh → interactive, single-flight, ADFS semantics |
| `OAuthDiscovery.swift` | RFC 9728 / RFC 8414 / OIDC metadata discovery, WWW-Authenticate parsing |
| `DynamicClientRegistration.swift` | RFC 7591 registration for servers that support it |
| `PKCE.swift` | S256 verifier/challenge + random state |
| `OAuthLoopbackListener.swift` | one-shot Hummingbird listener (http or https) that captures the redirect |
| `SelfSignedCertificate.swift` | in-process X.509 for the `https://localhost` listener |
| `OAuthTokenStore.swift` | the 0600 credential store, URL-bound, file-locked |
| `OAuthHTTP.swift` | proxy-aware form/JSON requests to the token and metadata endpoints |
| `BrowserLauncher.swift` | `open`/`xdg-open`, injectable and failure-soft |
| `MCPOAuthError.swift` | the typed, safe-to-print failure taxonomy |

## Design decisions worth knowing

**Token lifecycle is per-request, not per-connect.** The MCP client holds an
async token provider, not a frozen string. It attaches the current token on
every request, and on a 401 it forces one refresh and replays the request
exactly once. A second refusal is the typed `MCPError.unauthorized`; 403 fails
straight through (a scope problem is not cured by a fresher token).

**The browser opens only where a human can see it.** Interactive login runs in
the startup window — before the full-screen client redirects stderr — and only
when stderr is a terminal (and, on the inline surface, when there is a log sink
to print the authorize URL through). Mid-session token needs are refresh-only;
an expired session tells the model "restart domo to log in again" rather than
popping a browser over the TUI.

**The authorize URL is always printed.** A broken or absent browser launcher
costs a copy-paste, not the login — the URL goes to the terminal before the
browser is even asked to open it.

**Loopback redirect, plain HTTP by default.** `http://127.0.0.1` is the RFC
8252 norm every surveyed client uses. An `https://localhost` redirect (required
by registrations that refuse plain-HTTP loopback) gets a TLS listener with a
self-signed certificate generated in-process and cached a year at a time — the
browser warns once. The listener binds only the loopback interface, answers a
single state-checked callback, and refuses non-loopback redirect URIs outright.

**Secrets never touch settings.json.** The access token, refresh token, and any
dynamically registered client secret live in `<configDir>/mcp-oauth/tokens.json`
— created 0600 inside a 0700 directory, written atomically, guarded by a file
lock, and bound to the server URL they were minted for (a URL change reads as
"no credential", never as another server's token). Every token is registered
with the redaction vault the moment it exists, and OAuth error text — which can
carry provider-controlled strings — is mapped to a fixed message before it can
reach model-visible tool output or the session transcript.

**One coalescing mechanism, not two.** Concurrency is handled entirely by the
token store's per-cache-key flow lock — `flock`, which excludes two tasks in
the same process (each acquire opens its own descriptor) exactly as it excludes
two processes. Concurrent 401s serialize there and each re-reads the store
under the lock: the first refreshes, the rest observe its result. There is
deliberately no shared in-process coalescing task — that would entangle one
caller's cancellation and one caller's rejected-token with every other
caller's. Each caller's acquire is its own, so a caller aborted during the
browser wait unblocks promptly and releases the lock, while a sibling's login
is untouched. A 401's forced refresh is keyed to the exact token the failing
request carried, so a sibling's just-minted token is never wrongly discarded,
and the token exchange/refresh + its persist are shielded from cancellation so
a single-use code or a rotating refresh token is never burned mid-flight.

### ADFS realities (verified against Microsoft's documentation)

These are handled generically but were the reason for several rules:

- **`resource` on every grant.** Omitting it makes ADFS issue a token for
  `urn:microsoft:userinfo` that the MCP server rejects — an infinite-401 trap.
  It defaults to the server's canonical URL and is overridable for a
  relying-party identifier.
- **Refresh tokens do not rotate.** A refresh response that omits
  `refresh_token` keeps the previous one — and, since it also omits
  `refresh_token_expires_in`, keeps the previously learned refresh-token expiry
  rather than erasing it.
- **`invalid_grant` on any 4xx** (Auth0 answers 403, ADFS 400) drops the dead
  grant and falls back to interactive login rather than wedging startup.
- **Discovery falls back to `openid-configuration`.** ADFS publishes only the
  path-appended OIDC document, not RFC 8414 — so discovery tries the RFC 8414
  spellings first, then the OIDC ones.

## Testing

`Tests/DoMoMCPTests/OAuth*`, `SelfSignedCertificateTests.swift`,
`RemoteMCP401RetryTests.swift`, and `MCPManagerOAuthWiringTests.swift`, all
`.serialized` (they own sockets). Stub IdP and MCP endpoints are real
loopback Hummingbird servers on ephemeral ports; a scripted browser walks the
authorize URL as a real one would. Run them CI-style, never a bare `swift test`:

```
swift test --configuration debug   --no-parallel --filter "^DoMoMCPTests\."
swift test --configuration release  --no-parallel --filter "^DoMoMCPTests\."
```

## Deliberate limitations

- **No unknown-key diagnostic on the `oauth` block.** A typo'd field is
  silently ignored (as the rest of settings.json treats unknown keys). The
  most likely typo — the redirect key — is mitigated by naming it `redirectUri`
  to match the file's convention.
- **The refresh path is 401-reactive plus proactive-on-known-expiry.** A token
  with no stated lifetime is used until a 401 proves it stale, rather than
  refreshed on a timer.
- **One loopback port per concurrent flow.** A registration that pins a fixed
  port will fail with a clear `portInUse` error if that port is busy.
