# DoMoCode

A terminal UI coding-agent harness for Swift, built with Swift Package Manager, that talks to many
different models through a single [LiteLLM](https://github.com/BerriAI/litellm) gateway.

DoMoCode is a Swift port of the [Pi Agent Harness](https://github.com/earendil-works/pi) by Mario
Zechner, derived from `v0.81.1` (commit
[`9b3a2059`](https://github.com/earendil-works/pi/commit/9b3a2059171bcc74ad9d2cadeea6d186776cf2db),
2026-07-22) and used under the MIT License. DoMoCode is an independent project and is not affiliated
with or endorsed by the Pi Agent Harness project. See [NOTICES.md](NOTICES.md) for full attribution.

---

## Status: the port is finished; the harness is being built out

**The runtime, both terminal UIs, the HTTP/SSE server, inline images in and out, the permission engine,
the MCP client, the Phase 5b command layer, Phase 5c client polish, Phase 5d terminal-native polish,
Phase 10 context engineering, Phase 11's mutable tool suite, Phase 12's Git review surface, Phases
13–17's checkpoints, agents, subagents, diagnostics, and memory, Phase 18 sandboxing, Phase 19's
PTY/interactive-terminal seam, Phase 20's export/replay surface, and Phase 21's split-footer mini
mode are implemented, with focused coverage added here** — Phases 0–21 are complete. The focused
Swift 6.3.3 debug and release matrices for the new paths are green: bounded PTY service, VT screen
model, inline terminal provider, server ownership, transcript export/copy, HTML rendering, trajectory
replay, and split-footer rendering. The broad macOS integration
matrix remains subject to existing timing-sensitive full-screen client/server tests.
`domo` with no arguments is a full-screen client attached to a loopback server it spawns itself;
`--inline` is the classic scrollback REPL, `--mini` is the split-footer scrollback REPL; `-p`
is headless.

**Every phase of the pi port has shipped through Phase 12 Git review; the harness build-out is complete
through Phase 21 split-footer rendering.**
Phases 5a–5d — truth and plumbing, the command layer, client polish, and terminal-native polish — are
complete. The default client now receives the same command registry as the inline surface,
`/review`, `/init`, and `/tree` are available through that registry, trusted project instructions and
skills participate in the system prompt, and Claude Code-compatible markdown resources load in place.
The 5c slice adds the shared theme/dialog foundations, command palette, client-side `@` completion,
model changes, searchable session/tree controls, labels, branch summaries, LLM title generation, and
`$EDITOR` handoff. Its follow-up polish wires the reusable confirm/form/editor dialogs into real
actions, refreshes open pickers, presents labels on their target nodes, preserves explicit title clears,
and starts automatic titling only after a completed first turn. **Phase 5d now closes the terminal-native
polish gap.**
Beyond it,
[a second survey of the sibling harnesses](#sibling-harnesses-and-prior-art) found a broad set of
capabilities DoMoCode did not have — sandboxing, PTY access, export/replay, and split-footer rendering
have since shipped. The [roadmap](#roadmap) records the implementation history.

The goal has changed accordingly. DoMoCode began as a deliberately **narrowed** port; the
[first scope expansion](#what-expanded-and-what-did-not) widened it in four directions, all of which
shipped. The aim now is a **fully-featured terminal harness** — no compromises on capability, with the
remaining constraints (Swift 6.3, SwiftPM-only, macOS/Linux, one LiteLLM gateway) treated as facts
about *how* a feature gets built wherever that is possible. A handful genuinely cannot survive them,
and those are named rather than quietly dropped. Six reversals of a stated
non-goal are called out in the roadmap rather than assumed; see
[Non-goals](#non-goals-and-known-gaps).

## Why this exists

Upstream pi is a Node/Bun monorepo that normalizes ~38 model providers across ~10 different wire
APIs. That breadth is the right design for pi. It is the wrong design here.

DoMoCode inverts it. There is **one wire API** (OpenAI Chat Completions) pointed at **one host** (a
LiteLLM proxy), because LiteLLM already does the multi-provider normalization — that is its entire
premise. Everything the provider-abstraction layer would have cost gets spent on the agent loop and
the renderer instead.

Three constraints shape the whole project:

1. **Swift 6.3**, `swift-tools-version: 6.2`, `swiftLanguageModes: [.v6]` — strict concurrency on
   from day one. The manifest *format* stays at 6.2 because nothing here needs a 6.3 manifest
   feature; the **toolchain floor** is 6.3, and CI pins it. Nothing in this package uses a 6.3-only
   language feature — the floor moved because 6.2 stopped being buildable, not because anything
   wanted it. See below.
2. **Swift Package Manager only.** No CocoaPods, no Carthage, no vendored binary frameworks. Every
   dependency resolves from a public GitHub repository.
3. **One provider surface: LiteLLM.** Model breadth is the gateway's job, not the client's.

**The floor moved twice, both times for the same reason, and the second time is worth recording
because it was found the hard way.** On 2026-08-01 CI began failing on all four jobs inside
`SystemPackage` itself, before a line of this package compiled — `cannot find 'AT_RESOLVE_BENEATH' in
scope`. swift-system 1.7 put that constant behind a `canImport(Darwin, _version: 346)` gate that
admits it on an SDK which does not declare it; constraining swift-system below 1.7 fixed that job and
revealed the next one, `swift-configuration` reaching for `Data.bytes`, a Foundation API 6.2 does not
ship. That package is a Hummingbird transitive — not something this project chose — present in every
1.x release and in every Hummingbird since 2.18. Holding 6.2 would have meant pinning swift-system
back two minors *and* Hummingbird back nine, indefinitely, to keep a promise nothing here depended
on. So the floor moved instead.

Two things are worth taking from that. A version floor is a claim about what other people can build
with, and it decays silently: it broke in CI while every local build stayed green, because
development happens on a newer toolchain. And **pinning the floor in CI is what made it decay
loudly** rather than becoming a lie in this README — which is the entire argument for pinning it
there rather than letting the runner's default drift.

This project previously held a 6.1 floor, and that floor was expensive in a specific, mechanical way:
SwiftPM rejects any dependency whose manifest declares a `swift-tools-version` above the active
toolchain, so a package one minor version ahead is not "risky," it is unresolvable. Much of the
terminal-and-concurrency ecosystem crossed to 6.2, and the cost showed up as version caps that read
like stability judgments but were not: `async-http-client` held at 1.30.3, `swift-log` at 1.10.0,
`swift-markdown` at 0.7.1, and `swift-subprocess` — the officially-blessed `Foundation.Process`
replacement, which a coding agent cannot do without — held below 0.5. Those caps are gone. The
[dependency table](#dependencies) records the versions that replaced them.

Moving the floor now rather than later is deliberate. `swift-tools-version: 6.2` is what gates
`.defaultIsolation(MainActor.self)`, and SE-0461 changes the runtime meaning of every
`nonisolated async` function in the package — under the new rule such a function inherits its
caller's isolation instead of hopping to the global executor, which is a silent behavior change with
no diagnostic. Adopting that against zero source files costs nothing; adopting it against a finished
agent loop means auditing every `await`.

### What expanded, and what did not

DoMoCode began as a deliberately *narrowed* pi port, and for the runtime that framing still holds. But
the scope was widened on purpose, in four directions its founding thesis ruled out, and this README no
longer pretends otherwise. DoMoCode grew:

1. **A full-screen, alternate-screen TUI** — a widget-toolkit UI in the manner of Claude Code, opencode,
   or kilocode — added *alongside* the inline renderer, not replacing it. It is now the default mode.
2. **A client/server split** — the agent runtime moved behind a local HTTP + Server-Sent-Events server,
   and the terminal became a client that attaches to it.
3. **MCP** — a Model Context Protocol client, stdio-local, so external tool servers can extend the
   agent. It is hand-rolled rather than SDK-based; see the [dependency table](#dependencies).
4. **Inline images** — terminal graphics (Kitty/iTerm2) for display, plus image *input* to
   vision-capable models through the gateway.

What did **not** expand is the load-bearing part. The constants are the three constraints above — one
LiteLLM gateway (still no client-side multi-provider layer), Swift Package Manager only, and strict
Swift 6.2 concurrency — plus macOS-and-Linux and a single-user, local posture. The honest reading is
that "a port that implies parity will disappoint" now cuts both ways: DoMoCode took on a real slice
of the sibling-scale surface it once bounded out, and each reversal carries a named cost
([Non-goals](#non-goals-and-known-gaps)) rather than arriving free. All four have shipped, in the order
the [roadmap](#roadmap) records.

## Architecture

Package name `DoMoCode`; executable target and installed command `domo`.

The Phases 0–4 design was a single process: a headless runtime with every I/O concern injected, bound to
an inline terminal client on the main actor. The expansion split that seam onto a local socket. Three
layers result — a **runtime** (unchanged, because it was already event-sink-driven and owned by a
persistence actor), a **server** that hosts it behind HTTP+SSE, and a **client** that attaches over the
wire. The split is CQRS-shaped: the write path (`POST /session/:id/prompt`) drives the `AgentHarness`
actor that already owns the session tree; the read path (`GET /session/:id/events`) is an SSE broadcast
hub fed by the same `AgentEventSink` the runtime already emits to. Every module below ships today.

```
Sources/
  DoMoCore/         Shared vocabulary: JSONValue, JSON Schema, tolerant/partial JSON parser,
                    error taxonomy, JSONL codec, uuidv7. Used from runtime, server, and client.

  # The headless runtime — unchanged by the client/server split
  DoMoLLM/          LiteLLM-only OpenAI-compatible client: transport seam, SSE decoding, streaming
                    tool-call accumulator, model catalog, usage and cost accounting.
  DoMoAgent/        The pure agent loop: turn structure, tool dispatch, steering and follow-up
                    queues, the awaited event sink. No I/O, no persistence — so it is cheap to test.
  DoMoHarness/      Session tree, JSONL storage, context building, compaction, branch summaries,
                    hooks, the system-prompt builder, and command/skill resource loading.
  DoMoMemory/       On-demand session recall plus typed, byte-budgeted project memory outside the
                    checkout, with one shared secret-redaction gate on every write.
  DoMoExec/         FileSystem + Shell over swift-subprocess; gitignore walker; path and OS-process
                    sandboxing; per-path file mutation coordinator; image-attachment loading.
  DoMoGit/          The non-interactive Git facade, machine-oriented status/diff parsers, session-start
                    checkpoints, and the DiffSource boundary used by review and future shadow history.
  DoMoTools/        The built-in tools (read/write/edit/bash/grep/find/ls), background processes, and
                    the inline-first interactive_terminal PTY capability with a headless refusal.
  DoMoPermissions/  The granular allow/ask/deny engine: glob matching, last-match-wins evaluation,
                    the bash arity table, the .env guard, the config self-edit guard, an actor that
                    remembers and persists grants, and the beforeToolCall hook that gates the loop.
  DoMoMCP/          MCP client: an MCPManager actor owning fail-closed, environment-scrubbed stdio
                    server subprocesses, a JSON-RPC 2.0 protocol actor, and an McpTool: AgentTool
                    adapter. Hand-rolled, no SDK.
  DoMoLSP/          Content-Length-framed LSP diagnostics: pooled per-root stdio clients, initialize/
                    open/change notifications, pull diagnostics, merged push diagnostics, and an
                    optional OS-process sandbox.

  # The server — hosts the runtime behind a local socket
  DoMoServer/       Hummingbird HTTP+SSE. Write path drives the AgentHarness actor; read path is an
                    SSE broadcast hub. Loopback-only bind, per-session token, and a session-owned
                    PTY service ready for a future bidirectional client transport. Also owns the wire
                    DTOs (ServerEvent, ServerNotice) that the client decodes.

  # The terminal client
  DoMoTermIO/       The POSIX seam. The only module that imports Darwin/Glibc: termios raw mode,
                    TIOCGWINSZ, SIGWINCH, the stdin byte pump, panic-safe restore, alternate-screen
                    enter/exit, mouse reporting, PTY process groups, bounded output replay, and the
                    VT screen model used to interpret foreign interactive programs.
  DoMoTUI/          Both renderers. Inline: the differential scrollback renderer, Component protocol,
                    overlays, multi-line Editor, keybindings, ANSI/display-width text engine.
                    Full-screen: AltScreenCore + CellBuffer (absolute-CUP cell compositor), the
                    flexbox-lite LayoutNode tree, FocusRing, and ScreenSurface. Both conform to one
                    TerminalApp protocol, so one TerminalDriver drives either.
  DoMoTermGraphics/ UI-agnostic Kitty/iTerm2 image encoders, capability detection, and header-only
                    dimension parsers, shared by both render modes.
  DoMoToolsUI/      Renderers for the built-in tools, reattached at composition time.
  DoMoClient/       The full-screen client: the AsyncHTTPClient REST + SSE transport, an EventStore
                    that folds the delta-only stream into a normalized transcript, the two-pane UI,
                    scrolling, selection and clipboard, prompt history, and the approval modal.
  DoMoCLI/          Modes (full-screen/inline/print/json) and `--serve`; settings, project trust,
                    permission setup, MCP wiring, and composition.
  domo/             The executable. ArgumentParser root plus DoMoCLI.run().
```

### How this maps to upstream pi

| pi package | DoMoCode module(s) | Notes |
|---|---|---|
| `@earendil-works/pi-tui` | `DoMoTermIO` + `DoMoTUI` (+ `DoMoTermGraphics`) | Split in two. TermIO owns terminal state (`terminal.ts`, `stdin-buffer.ts`); TUI owns the diff renderer, components, and the width/ANSI engine (`tui.ts`, `keys.ts`, `keybindings.ts`, `utils.ts`, `fuzzy.ts`, `autocomplete.ts`, `kill-ring.ts`, `undo-stack.ts`, `word-navigation.ts`, `components/`). The Windows shims are dropped. Unlike pi, which never takes the alternate screen, DoMoCode *added* a full-screen alt-screen mode beside the inline renderer — it lives inside `DoMoTUI`, not in a separate module. Inline images (`terminal-image.ts`) are ported into `DoMoTermGraphics` rather than dropped. |
| `@earendil-works/pi-ai` | `DoMoLLM` | Radically narrowed. Keeps the *shapes* — `Context`, `AssistantMessage`, `Usage`, `StopReason` — plus the streaming tool-call assembler, retry/overflow classifiers, and cost math. Drops 37 providers, 9 wire APIs, OAuth, and the generated model catalog. |
| `@earendil-works/pi-agent-core` (`agent-loop.ts`, `types.ts`) | `DoMoAgent` | Ported structurally: turn loop, stop conditions, three-phase tool dispatch, parallel-vs-sequential execution, truncated-tool-call refusal, steering queues. |
| `@earendil-works/pi-agent-core` (`harness/`) | `DoMoHarness` | Session tree, storage, `buildContext`, compaction, branch summarization, hooks. |
| `@earendil-works/pi-agent-core` (`env/nodejs.ts`) | `DoMoExec` | Protocol-based FileSystem and Shell with a single POSIX implementation. |
| `@earendil-works/pi-coding-agent` (`core/tools/`) | `DoMoTools` + `DoMoToolsUI` | The built-in tools, split headless/rendered. |
| `@earendil-works/pi-coding-agent` (rest) | `DoMoCLI` | Session orchestration, settings, trust, output modes, and the Phase 5b command/resource layer. |
| `@earendil-works/pi-storage-sqlite-node` | `DoMoHarness` protocol; SQLite backend deferred | JSONL is the shipping default and the only implementation; the `SessionStorage` seam exists from Phase 3. |
| `@earendil-works/pi-server` | `DoMoServer` | No longer a non-goal. Narrowed hard: a *local, loopback-only* HTTP/SSE server (Hummingbird), modeled on opencode's `server.ts`/`event.ts`. Multi-instance supervision, mDNS discovery, and cloud presence stay out. |
| *(no upstream — pi has no MCP)* | `DoMoMCP` | Original to DoMoCode, not derived from pi. A hand-rolled stdio MCP client, modeled on opencode's/kilocode's `mcp/`. |
| *(no upstream — pi has no permission engine)* | `DoMoPermissions` | **Not from pi.** Eight of its thirteen files are ports carrying opencode's copyright, two of those also kilocode's; see [NOTICES.md](NOTICES.md#other-prior-art) for the per-file record. |
| *(no upstream — pi has no client/server split)* | `DoMoClient` | Original to DoMoCode. The full-screen terminal client; only the retained-cell-buffer + flexbox *design* is borrowed from OpenTUI, never code. |

### Concurrency and isolation

Swift 6.2 makes default isolation a per-target setting, and DoMoCode's module boundaries already run
along isolation lines. Four decisions follow, all expressed in `Package.swift`:

**`nonisolated async` now inherits the caller's isolation.** With
`.enableUpcomingFeature("NonisolatedNonsendingByDefault")`, an unmarked `nonisolated async func` runs
on its caller's actor; `@concurrent` is the new spelling for the old always-hop behavior. This matters
concretely: `DoMoTUI` is main-actor-bound, so if the TUI awaits into the agent loop and the loop's
entry points are plain `async`, SSE decoding, JSON parsing, and tool dispatch all execute on the main
actor and block the renderer — with no diagnostic. The rule is therefore that **`@concurrent` marks
module seams and nothing else**: the public entry points of `DoMoLLM`, `DoMoAgent`, and `DoMoExec` are
`@concurrent`, and everything they call transitively is plain `nonisolated async` and correctly
inherits the off-main context.

**`DoMoTUI` is MainActor by default; nothing else is.** That target gets
`.defaultIsolation(MainActor.self)` plus `.enableUpcomingFeature("InferIsolatedConformances")`, which
together delete the `@MainActor` noise from every `Component` conformance. `DoMoCore` is shared
vocabulary used from both domains and stays `nonisolated`; `DoMoTermIO` runs a stdin byte pump that
must not be on the main actor; `DoMoLLM` is network I/O. One trap to note: under default `MainActor`
isolation even a global `let` of a `Sendable` type infers `@MainActor`, so shared state must be
written `nonisolated let`.

**Shared mutable state is `Mutex`, not an actor.** For state with no async work under the lock — the
SIGWINCH-updated terminal dimensions, cancellation flags, config snapshots, the cost accumulator —
`Synchronization.Mutex` beats an actor: it is synchronous, so a `nonisolated` function reads it
without becoming `async`, and there are no suspension points or reentrancy hazards. The dividing line
is absolute — never `await` while holding the lock, and use an `actor` when the critical section
genuinely needs to. The signal-handler path is the exception: a `SIGWINCH` handler may only touch
async-signal-safe things, so it sets an `Atomic<Bool>` that the render loop polls. This is what sets
the macOS 15 floor.

**Unsafety is confined by the compiler, not by convention.** `.strictMemorySafety()` is on for
`DoMoCore`, `DoMoTUI`, `DoMoLLM`, and everything above them, and *off* for `DoMoTermIO`. The point of
the flag is auditing, and in `DoMoTermIO` there is nothing to audit — it is POSIX calls by design,
roughly one `unsafe` keyword per call, and annotating them all just trains you to stop reading the
warnings. Everywhere else a strict-memory-safety warning means unsafety leaked out of the seam, which
is precisely the invariant the module split exists to enforce. Alongside it,
`.treatAllWarnings(as: .error)` from the first commit.

Two smaller commitments: every long-lived task is named (SE-0469) — the byte pump, each SSE stream,
the render loop — because a stuck agent loop is far easier to read in a backtrace when its tasks have
names; and `DoMoTermIO`'s platform imports are a three-way `Darwin` / `Glibc` / `Musl` shim from the
start, so the Static Linux SDK can produce a fully static binary without retrofitting.

**The client/server split cost two mechanisms.** The runtime itself did not change in isolation terms —
it was already `nonisolated` / `@concurrent`-at-the-seams with a single `AgentHarness` actor — and
`DoMoServer` is `nonisolated`, running on NIO's event loops, while `DoMoTUI`'s `MainActor` default stays
entirely on the *client* side of the wire. But two invariants are genuinely weakened, and this names them
rather than hiding them. First, `AgentEventSink.emit` is *awaited* in-process: the run does not advance
until every listener has accepted each event. Over a socket that guarantee is unsafe — one hung client
would stall the agent loop — so the network fan-out sink is fire-and-forget with a per-subscriber
bounded buffer and a drop-oldest policy, while the durable persistence sink stays awaited. A client that
misses frames re-seeds its transcript from `GET /session/:id/messages` on reconnect rather than replaying
the gap. Second, **mid-run steering now survives the split.** A per-session `SteeringBox` accepts prompts
through `POST /session/:id/steer`, reports its level-triggered count with `queue_update`, and the client
uses the 409 response only for the narrow race where a run settles between its status check and submit;
it retries the ordinary prompt route there. The safe default delivers one queued message at a time, with
an `all` mode for callers that want a batch.

Deliberately *not* adopted: `Span`, `RawSpan`, `UTF8Span`, and `InlineArray`. They are the right shape
for the escape decoder and for grapheme-cluster width measurement, but every standard-library API that
*produces* one is `@available(macOS 26)` — the types back-deploy, the accessors do not — and on Linux
they are unconditional, so using them means `#if` divergence in the most correctness-critical code in
the project. The decoder is built on `[UInt8]` with an explicit index, but its internal view type is
deliberately `Span`-shaped (borrowed base plus count, explicit slicing, no ownership) so the storage
swap is mechanical when the floor eventually reaches macOS 26.

## Roadmap

Ordered strictly by dependency. Each phase ends with something runnable and tested.

- [x] **Phase 0 — Skeleton.** `Package.swift` with the pin table, all package targets declared, the
      per-target isolation and safety settings from
      [Concurrency](#concurrency-and-isolation), CI on macOS and Ubuntu at the floor toolchain building in both
      debug and `-c release`. `DoMoCore`: `JSONValue`, JSON Schema, the tolerant JSON parser,
      `uuidv7`, error taxonomy, JSONL codec. 234 tests, green in both configurations.
- [x] **Phase 1 — Talk to LiteLLM headlessly.** `DoMoLLM` end to end: transport seam, lenient
      `Codable` models, SSE decoding, `[DONE]`, in-stream error sniffing, the tool-call accumulator,
      usage capture, retry/backoff, `GET /v1/models` catalog. Plus `DoMoExec` and headless
      `DoMoTools`. *Exit met:* `domo -p "..."` runs a real multi-turn tool loop and prints plain
      text — with zero TUI code, which is exactly why it comes first. The exit-criterion test drives
      the compiled binary against a loopback mock gateway. 535 tests, green in both configurations.
- [x] **Phase 2 — The agent loop.** `DoMoAgent` as a pure, heavily unit-tested module — the
      outer follow-up loop and inner turn loop, three-phase tool dispatch, the `.length`
      truncated-call refusal, steering and follow-up queues, and an awaited `AgentEventSink` (not a
      fire-and-forget stream). Print mode's ad-hoc loop is gone, retrofitted onto `runAgentLoop`.
      570 tests, green in both configurations.
- [x] **Phase 3 — Persistence and harness.** `DoMoHarness`: an append-only session tree in JSONL,
      `buildContext` resolving the leaf-to-root path (or to the nearest compaction boundary),
      compaction and branch summarization, and the `AgentHarness` actor that persists each message as
      the loop runs. CLI: persistence by default, `--continue` / `--resume` / `--fork` / `--session`,
      and a project trust gate. *Exit met:* an end-to-end test resumes a session in a second process
      and proves the next request carries the prior turn's context. 677 tests, green in both
      configurations.
- [x] **Phase 4 — Terminal.** Built oracle-first, across four workflows. **4a:** the SwiftTerm
      screen-state oracle (renderer bytes in, cell-grid assertions), the `DoMoTermIO` POSIX seam (raw
      mode with panic-safe restore, SIGWINCH, the stdin framing state machine, key decoding,
      keybindings), and the `DoMoTUI` width engine. **4b:** the Component model and the inline
      differential renderer (verified against the oracle, proven not to clamp-and-overwrite the
      transcript), overlays, and core components. **4c:** the multi-line Editor (`[[Character]]`
      buffers), Markdown-on-swift-markdown, and autocomplete + fuzzy. **4d:** the live terminal
      driver, `DoMoToolsUI` tool renderers, and the interactive REPL. *Exit met:* `domo` with no
      `-p` is an interactive session with streaming output, `@` file completion, Escape-to-abort, and
      Enter to queue a follow-up; three end-to-end tests drive the real REPL headlessly against a mock
      gateway. 1059 tests, green in both configurations. (That REPL is `domo --inline` today — Phase 7
      moved the no-flag default to the full-screen client; its `@`/slash completion landed in 5c.)
- [x] **Phase 5 — Polish**, split into four the way Phase 8 was. **5a, 5b, 5c, and 5d are complete.**
      It was sequenced *before* the architecture pivot and was overtaken by it, so the work landed
      against the client/server seams: the full-screen
      client has a shared command registry, theme value model, dialog stack, searchable pickers,
      model/session/tree mutations, and the existing accounting footer is wired to server-derived
      values.

      **[x] 5a — Truth and plumbing.** Several shipped subsystems reported numbers that were
      structurally wrong: cost was always zero because `rates:` was never passed to a single
      production call site, and the context window was a hardcoded 200k guess wrong for every
      non-frontier alias behind the proxy. Per-alias `modelOverrides` (context window, cost rates,
      reasoning effort) now reach all three `streamCompletion` sites through one `ModelRuntime` and a
      shared stream factory; LiteLLM's `x-litellm-response-cost` is read into `Usage` when present,
      though per-alias rates remain the primary source because a streaming response's headers flush
      before its cost is knowable; compaction is configurable; `smallModel` (or `compaction.model`)
      builds a real summarizer, but only when it differs from the run's model, so nothing changes for
      a user who configures nothing. `contextWindow` became **optional** — `nil` means genuinely
      unknown and a meter renders `?` rather than a percentage of a guess, with a 200k fallback used
      only to decide when to compact. Plus `{env:}`/`{file:}` resolution following kilocode's hardened
      semantics rather than opencode's (project config untrusted, an unset variable a hard error
      rather than a silent empty string, an env denylist so an interpolated value cannot re-inject the
      credential the MCP scrub removes); a shared secret-redaction module; config errors that name a
      line, a column and draw a caret; and a `flock(2)` lock plus a mode-preserving atomic write
      around the settings read-modify-write, whose race was never only cross-process — one
      `domo --serve` with two sessions could lose a grant to itself. Two items **could not be
      backfilled** and so shipped now: per-entry `elapsedMs` and a monotonic per-file `seq`.
      *Exit met, and exceeded at the user's request:* the numbers are not merely available but
      **displayed** — a footer in the default client showing cwd, git branch, tokens, cost and
      context percentage (Phase 5c's item, pulled forward), the same three numbers on the inline
      REPL's status row, and `cost`/`reasoning` on the `--json` stream. A malformed `settings.json`
      names the offending line, column and key under a caret. Three approved secret-leak fixes went
      with it: the gateway's 401 body — which echoes the key it received and was persisted into
      session JSONL forever — is redacted; a custom `apiKeyEnv` is scrubbed from MCP children; and
      `bash` no longer inherits the gateway credential. **Two adversarial reviews ran, one on the code
      and one on the fixes**, producing 45 confirmed findings and 66 disproved suspicions; among the
      real ones were a symlink escape in untrusted project config, a redaction registration that
      *defeated* the header rule it was meant to help, an overflow that trapped and killed the client,
      and — the most valuable — proof that the entire per-alias plumbing on the **default** surface
      could be deleted with the whole suite green, because the surface everybody uses was the one
      nobody had tested. A **third** pass then reviewed those fixes, and found several incomplete and
      one strictly worse than what it replaced — the `{file:}` fix did not close a *dangling* symlink,
      running the redaction patterns before the literal registry let a rule bite a piece out of a
      registered secret so the rest printed, and a length cut meant to hide a value was four
      characters wider than the longest thing it could legitimately show. Those are closed too.
      2,524 tests in 298 suites, green in debug and release.

      *Left open, deliberately, and written down rather than discovered later:* the `{file:}` check
      still has a residual TOCTOU window — closing it needs `O_NOFOLLOW` and a read from the
      descriptor, which would break the trusted policy's documented ability to follow a link to
      `~/.gateway-key`; `SessionAccounting` cannot say whether a session was *priced*, so the footer
      still cannot distinguish an operator's deliberate `$0` from an unpriced alias the way print mode
      can, and the inline strip has not been brought onto the footer's negative-cost and clamping
      rules; `Usage`'s own `Decimal`s still cross `/status` as JSON numbers, so only
      `SessionAccounting.costTotal` is string-encoded; and `AgentLoop` still fabricates a
      `messageStart` for a turn that never streamed, so the sink infers "was this timed" from the stop
      reason instead of being told.

      **[x] 5b — The command layer.** The two seams the rest of the roadmap leans on hardest: a composable
      `SystemPromptBuilder` (base → `SYSTEM.md` → `AGENTS.md`/`CLAUDE.md` ancestor walk → available
      skills → cwd) and one `CommandDescriptor` registry served to both surfaces over `GET /commands`,
      so they cannot drift. On top of them: markdown-plus-frontmatter commands and skills with a
      permissive parser so Claude Code files load unmodified, `.claude/skills` and `.agents/skills`
      read in place rather than migrated, the full template grammar (`$ARGUMENTS`, `$N` with
      last-slurps-remainder, `${1:-default}`, `@file` inclusion, trust-gated inline `` !`shell` ``),
      per-command model and reasoning overrides, keyword-triggered skills, and `/init` and `/review`
      shipped as built-in templates rather than special-cased code. *Exit:* dropping
      `.domocode/commands/review.md` into a repo produces a working `/review` in both surfaces, and an
      `AGENTS.md` at the root visibly changes the system prompt. **Exit met:** the shared builder,
      registry endpoint, trust gate, template grammar, built-in `/init` and `/review`, project/user
      precedence, and focused harness coverage are shipped. The command-palette and full-screen
      `@` affordances are now part of the first 5c slice.

      **5c — Dialogs, themes, and the client's missing hands (complete).** The largest single chunk
      of Phase 5.
      One reusable dialog vocabulary (`select`/`confirm`/`input`/`form`/`editor` as async overlays,
      with a dialog stack and focus save/restore), applied across the permission/diagnostics surfaces
      and client actions; a `Theme` value type with hex / ANSI-index / `none`-means-inherit and dark-light
      variants; and then both spent on the pickers users expect — command palette, `@` completion in
      the client, model picker writing the first real `model_change`, `/tree` with filter modes,
      folding, labels and branch summaries (giving the already-written `summarizeBranch` a caller),
      session picker with search, rename and LLM auto-titling, `$EDITOR` handoff around the alt
      screen, and a footer showing cwd, branch, tokens, cost and context percentage. *Exit:* in the
      default client a user can theme it, switch models, search and rename sessions, navigate and
      branch the tree, and read a footer whose numbers are derived rather than guessed.

      **Phase 5c exit verified:** `ThemeColor` accepts hex, ANSI-index, and inherited colours with
      dark/light palettes; `DialogStack` now owns focus-safe overlays including permission and
      diagnostics; the default client exposes the command palette, `/tree`, Tab-driven `@` and slash
      completion, model switching, searchable sessions, rename/label forms, tree filtering/folding,
      branch navigation and summaries, LLM-generated titles, and `$EDITOR` handoff. **The delivered
      polish** wires the dialog vocabulary, picker refresh, label presentation, title-clear semantics,
      and completed-turn auto-title trigger, covered by the Swift 6.3.3 debug/release verification
      matrices.

      **5d — Terminal-native polish (complete).** Kitty keyboard protocol negotiation with a `modifyOtherKeys`
      fallback, restoring Shift+Enter through negotiated CSI-u input; exit-time stdin drain so
      key-release escapes do not leak into the
      parent shell; focus tracking; OS notifications via OSC 777 / Kitty OSC 99 written straight down
      the tty, which works unchanged over SSH; terminal title and OSC 9;4 progress, both registered in
      the crash-safe teardown; OSC 8 hyperlinks; clipboard image paste. *Exit:* Shift+Enter works, a
      finished run notifies only when you have tabbed away, and quitting — including crashing — always
      leaves the terminal clean. **Phase 5d exit verified:** the lifecycle, driver, client and inline
      REPL seams cover keyboard negotiation, focus-aware notifications, presentation cleanup, OSC 8
      links, and bounded clipboard image/text paste.
- [x] **Phase 5.5 — Inline images, the input half.** `ContentBlock.image(ImageBlock)` and an
      `image_url` data-URL wire encoding for image-bearing *user* turns (assistant turns stay
      plain-string, since some models mirror a content-part array back as garbage). Images a *tool*
      returns — `read` on a PNG already produces one — are carried through the `RegistryTool` adapter
      (`AgentToolResult.images`, `ToolResultBlock.images`, both backward-compatibly Codable) and
      hoisted on the wire into a synthetic user message after the tool message, because the OpenAI
      `tool` role cannot hold image parts (pi's approach). Attach surfaces: a repeatable
      `--image <path>` flag in print mode and `@path` auto-attach in the interactive editor (read
      off the main actor). Dependency-free and single-provider-safe. The model catalog is advisory,
      so images are sent and a text-only model's error is surfaced rather than hard-gated — an
      `includeImageContent` seam exists for a future gate. Both the user-attach and tool-image paths
      are proven end-to-end against the mock gateway, in print mode and the live REPL. 1,097 tests
      green in debug and release.
- [x] **Phase 6 — Headless HTTP/SSE runtime server** (re-scoped from the old "RPC mode"). A new
      `DoMoServer` on Hummingbird 2.25.1 (resolves and builds sharing one swift-nio with
      async-http-client), modeled on opencode's server. The wire vocabulary is a versioned
      `ServerEvent` DTO *projected* from `AgentEvent` (streaming deltas flattened; `AssemblyEvent`
      kept off the wire; `DoMoAgent` left untouched) rather than encoding the event enum. A
      `BroadcastEventSink` fans it out over `GET /session/{id}/events` (connected frame + per-event
      frames + heartbeat) with the awaited-emit split honoured (durable-awaited vs
      fan-out-buffered, drop-oldest, so one stuck client cannot stall the loop); REST over
      `AgentHarness`/`JSONLSessionStore` (`POST /session/{id}/prompt` → 202, list / messages /
      children / abort / fork, resume by id); loopback-only bind + a constant-time bearer token;
      `domo --serve`. *Exit met:* an in-process end-to-end test stands the server up and drives it with
      a real HTTP client — create → SSE subscribe → prompt → assert the event frames → transcript
      persisted and read back → fork → 401/404 — and a three-lens adversarial review's findings
      (unbounded SSE buffer, error-swallowing that dropped the terminal frame, live-session
      overwrite, arbitrary-path resume) were fixed. **Single-client-first** — the broadcast hub takes
      N subscribers and nothing rejects a second one, but the mirroring semantics that would make that
      safe are unscheduled; `-p` stays in-process. 1,116 tests green in debug and release. The REST surface has since grown
      `/permission`, `/permissions` (Phase 8b) and `/status`, `/force-clear` (Phase 8.5).
- [x] **Phase 7 — Full-screen widget TUI**, built in-house across four sub-phases (there is no
      OpenTUI-equivalent in Swift). **7a:** alternate-screen enter/exit (`CSI ?1049h/l`) with
      crash-safe restore, plus `AltScreenCore` — a `RenderCore` sibling that paints by absolute `CUP`
      and never scrolls — over a `CellBuffer`. **7b:** the flexbox-lite `LayoutNode` tree
      (`Row`/`Column`/`Fixed`/`Flexible`/`FlexSpacer`, deterministic remainder split, and a
      `ComponentBox` adapter that lifts the existing 1-D `Component` protocol into 2-D). **7c:** the
      interactive layer — `FocusRing` (Tab-order traversal, an invariant the inline model never
      needed), `ScreenSurface` (the full-screen analogue of `TUI`), a `TerminalApp` protocol both
      conform to so *one* `TerminalDriver` drives either, and the overlay geometry solver extracted
      for sharing (inline behavior proven byte-identical). **7d:** a new `DoMoClient` target — not
      `DoMoTUIKit`, which was planned and never built, and not inside `DoMoCLI` as first sketched:
      an AsyncHTTPClient REST + SSE transport, an `EventStore` that folds the delta-only stream into
      a normalized transcript, and the two-pane sidebar/transcript/status/prompt UI. *Exit met:* the
      client attaches over SSE, renders a live session, and survives resize, all asserted against the
      SwiftTerm cell-grid oracle driving the real client against a real in-process server; terminal
      restore is an `atexit` + `SIGINT`/`SIGTERM`/`SIGHUP` handler replaying a preallocated exit
      sequence, covered by byte-composition and real-pty tests but not by a kill-mid-session test.
      **Inline mode stayed first-class** and `-p` still pipes. 1,193 tests green in debug and release.
- [x] **Phase 7.5 — Inline images, the display half.** `DoMoTermGraphics` is a faithful port of pi's
      `terminal-image.ts` (Kitty `APC f=100` and iTerm2 `OSC 1337` encoders, env-based capability
      detection, header-only PNG/JPEG/GIF/WebP dimension parsers plus a BMP reader pi does not have,
      cell sizing), fed by a `TIOCGWINSZ` cell-pixel-size probe. Both renderers learned to place images: the inline
      `RenderCore` treats an escape as an opaque image line and reserves `r` rows, while the
      full-screen `AltScreenCore` keeps a separate per-column image layer with its own diff — novel
      work, since pi is inline-only. Two protocol facts were byte-verified against upstream and are
      load-bearing: inline layout is **protocol-specific** (Kitty draws escape-first holding the
      cursor; iTerm2 reserves with blank lines and draws on the last row after `ESC[{rows-1}A`), and
      Kitty `f=100` is **PNG-only**, so a non-PNG returns nil and the caller shows the text fallback.
      *Exit met:* images render in the full-screen client and the inline REPL on Kitty and iTerm2 and
      degrade to a text placeholder under tmux/screen; print mode emits images only on a graphics tty
      in `.text` mode, so piped and `--json` output stay byte-clean rather than gaining a placeholder.
      1,253 tests green in debug and release.
- [x] **Phase 8 — Permission engine, then MCP**, across four sub-phases. **8a:** `DoMoPermissions` —
      allow/ask/deny with glob matching and last-match-wins evaluation (ported from opencode and
      checked against its test corpus), kilocode's base-vs-saved layering so a config `deny` beats a
      broad in-session grant, a 136-entry bash arity table so an "always" grant is scoped to a command
      prefix rather than to `bash`, a `.env` read guard, and a config self-edit guard that forces a
      prompt for any write, edit, or bash command touching the settings or trust file. Grants persist
      into the user's `settings.json` through an order-preserving rewrite. The gate is the agent
      loop's pre-existing `beforeToolCall` hook, so one seam covers every surface: the inline REPL
      raises a capturing modal, and headless `-p` refuses with a model-visible reason unless `--yolo`.
      **8b:** the server/client round-trip — `permission_request` on the SSE stream,
      `POST /session/:id/permission` to answer, `permission_resolved` broadcast, and
      `GET /session/:id/permissions` to reconcile a prompt missed while disconnected. **8c:**
      `DoMoMCP` — **hand-rolled, not the official Swift SDK** (whose stdio transport does not spawn
      the subprocess and which pins `swift-docc-plugin` to a git branch): one persistent subprocess
      per server over newline-delimited JSON-RPC 2.0, **stdio only, tools only, no OAuth**, paginated
      discovery, namespaced `server_tool` names de-collided against each other and against the
      built-ins, and an `McpTool: AgentTool` adapter. **8d:** integration and hardening — a `deny`
      rule *hides* an MCP tool from the model rather than merely blocking it (in both the tool array
      and the system-prompt tool list), a malformed schema drops the tool, LLM credentials are
      scrubbed from each child's environment, the system prompt carries a standing prompt-injection
      caveat, and teardown signals the child's process group directly, which fixed a real
      descendant leak. *Exit met, with one deviation:* MCP tools appear namespaced and gated, proven
      end-to-end through the compiled binary, and an untrusted project never spawns its servers — but
      the **per-turn tool-set snapshot did not ship**. The tool set is built once at startup and is
      immutable for the run, so a `tools/list_changed` notification cannot take effect until restart.
      1,340 tests green in debug and release.
- [x] **Phase 8.5 — Hardening and quality of life** (unplanned; driven by using the thing). Two
      efforts. First, a **defect sweep of the shipped full-screen client**: its root cause was that
      `runClient` built a default `TerminalLifecycle`, so the client *never entered the alternate
      screen* and painted absolute-CUP frames onto the normal buffer — every real scroll desynchronised
      later repaints. The alt-screen requirement now lives with the UI. Alongside it: pre-existing
      sessions were inert (the client never resumed them server-side), a dead SSE stream was permanent
      and silent (now bounded-backoff reconnect with a transcript re-seed), model and tool text
      reached the frame with control characters intact (`ESC[2J` wiped the page), tool calls gained
      spinner/⏳/✓/✗ state with an argument summary, and "allow always" stopped granting `*` on every
      path. Second, a **quality-of-life pass**: in-app selection and right-click copy (OSC 52 with
      tmux passthrough, plus `pbcopy`/`wl-copy`/`xclip`), mouse-wheel and PgUp/PgDn scrolling, `F8`
      and `--no-mouse` to hand the pointer back to the terminal, drag-and-drop image paths as prompt
      attachments, a multi-line prompt that grows and scrolls, per-workspace persistent prompt
      history, a real error surface (a classified notice channel, a persistent transcript row, `^O`
      to expand), retries widened to ten attempts with a sleep budget, and `--max-turns` made
      **unlimited by default in every mode**, guarded instead by a no-progress runaway detector.
      The load-bearing fix underneath: `AsyncHTTPClient`'s request timeout covers only
      time-to-response-head, so a gateway that sent headers and then stalled hung a turn forever and
      held the session's run slot — streamed bodies are now idle-guarded, with `GET /session/:id/status`,
      `POST /session/:id/force-clear` and a `^G` diagnostics panel as the escape hatch. Both efforts
      were reviewed adversarially, and each review was followed by a second one aimed at the *fixes* —
      which found about as many real problems as the review of the original code. That is the durable
      lesson of this phase: review the fix, not just the defect. 1,995 tests green in debug and release.
- [x] **Phase 9 — Steering, queues, and run control.** Restores what the client/server split took
      away. `SteeringBox` now lives in `DoMoHarness`, is held per session by `ServerRuntime`, and is
      shared by the inline REPL and the server path. The default full-screen client sends a mid-run
      prompt to `POST /session/:id/steer`, receives a `queue_update` frame, shows the queued count, and
      retries the ordinary prompt route only when a settle/submit race returns 409. Delivery is
      configurable as `one-at-a-time` (the safe default) or `all`, and queued messages survive a run
      ending in the small late-submit window. `maxCostPerRun` stops after the turn that reaches a
      positive USD ceiling and gives headless mode exit code 4. The no-progress detector now asks the
      permission engine under its reserved `doom_loop` key; inline and server prompts can answer it,
      while `-p --yolo` grants one more guard window without blocking a script. *Exit met:* typing
      while the agent works queues instead of erroring; focused loop, permission, server/client, and
      compiled-binary tests cover the queue, delivery modes, cost exit, and escalation paths.
- [x] **Phase 10 — Context engineering.** Compaction now has the missing runtime seam: one
      compact-and-retry recovery per turn, cross-provider overflow detection for explicit, silent, and
      truncation forms, cumulative file manifests, deterministic non-conversational summarizer input,
      context-time tool-output pruning, and recoverable spill-to-disk for oversized output. `/compact`
      and `/context` are available in the inline and full-screen clients and over the server client API.
      *Exit met:* a long session against a small-context alias recovers instead of dying, and the meter
      says `?` when the model window is genuinely unknown.
- [x] **Phase 11 — Mutable tool set, and the tool suite.** The seam phase is complete. Tool resolution
      is now a per-request function, with the system prompt's tool list computed from the same result;
      registration order stays stable for prompt caching. The full suite is shipped: `todowrite`; the
      structured `question` tool (inline and full-screen client/server round-trip, denied in headless
      mode); `webfetch` with its own permission kind; `glob`; `read` gaining directory listing,
      "did you mean", and nested-`AGENTS.md` injection; `finish`; session-scoped `background_process`;
      the edit engine's multi-strategy replacer cascade — with the disproportionate-match guard
      ported **first and unconditionally**; and `external_directory` as a real permission derived from
      parsed bash arguments. The MCP resolver now refreshes tools and schemas after
      `tools/list_changed` without a restart, while server sessions receive independent mutable-tool
      state. Parallel tool dispatch is enabled on all production surfaces, with a tool-level
      sequential override still available. *Exit met:* the model keeps a todo list, asks a structured
      question, fetches a URL under permission, and picks up an MCP tool added mid-session; focused
      and end-to-end tests cover the suite. The file-tool refusal versus bash's
      `external_directory` prompt closes the last permission asymmetry in this slice: an
      "allow always" on a bash prefix no longer silently widens a read beyond the workspace.
- [x] **Phase 12 — Git: facade, diff, review.** The first phase needing a new subsystem rather than a
      seam. DoMoCode has no git integration at all, and a `DoMoGit` facade gates the diff viewer,
      `/review`, checkpoints and eventually worktrees — so it is built once, deliberately, with the
      flag discipline (`--no-optional-locks`, `core.quotepath=false`, `GIT_TERMINAL_PROMPT=0`, …) that
      removes a class of cross-platform bugs. Note that `Shell` takes a command *string*, not an argv
      vector, so every interpolated ref must be quoted and every path list preceded by `--`; an
      argv-level `Shell.exec` is worth adding here. The cheap 80% ships first: recording the session's
      start HEAD as an entry makes `git diff <sha>` answer "everything this session changed" with no
      snapshot infrastructure at all. Then the full-screen diff review route — file-tree pane with
      collapsed path chains, split-versus-unified chosen by width, `]`/`[` hunk navigation,
      mark-reviewed, a source switcher behind one `DiffSource` protocol — plus per-file revert, a live
      modified-files sidebar, and LLM commit-message generation. *Exit:* `domo diff` and a `/diff`
      pane; `/review` on a branch produces an advisory review. **Exit met:** `DoMoGit` now owns the
      non-interactive command policy and machine-oriented parsing; new sessions record their start
      HEAD; `domo diff` emits the raw patch or structured JSON; the server/client expose diff, per-file
      restore, and commit-subject routes; and the full-screen review dialog provides a width-aware
      file tree, hunk navigation, reviewed marks, live refresh, destructive restore confirmation, and
      LLM-generated subjects. The inline surface names the full-screen affordance rather than sending
      `/diff` to the model.
- [x] **Phase 13 — Checkpoints and undo.** The single highest-value absent capability in the survey.
      Today a bad edit is permanent unless the user's own VCS happened to have it staged. Shadow git —
      a second `GIT_DIR` in the data directory whose work-tree is the user's project, capturing
      `write-tree` objects with no commits, branches or reflog — gives real undo without touching the
      user's repository, with ignore filtering piped through the *real* repo's `check-ignore`.
      Per-step snapshots are appended as their own entries rather than mutating the assistant message,
      preserving the append-only invariant. The revert planner is a pure, separately-tested function
      with earliest-writer-wins semantics: files nobody touched are never read or written, which is
      what stops undo clobbering the user's concurrent edits. The workspace-status indicator
      (`restored` / `snapshots-disabled` / `unavailable`) ships **in the same change as revert, never
      after** — a silent partial undo where the user believes files came back and they did not is the
      worst outcome in this domain. Plus `/timeline`, and a `/fork` command over plumbing that exists but has
      no interactive entry point: `AgentHarness.fork` is reachable today only through the `--fork`
      launch flag, while `POST /session/:id/fork` and `ServerClient.fork` have no caller outside
      tests. `/clone` has no plumbing at all — no harness method, no route — and is new work. *Exit met:*
      `DoMoShadowGit` records commitless shadow-index snapshots without touching the user's repository;
      append-only checkpoint and history-action entries drive a pure, earliest-writer-wins revert planner;
      `/undo` and `/redo` move conversation and files together with truthful restore/skipped/failed
      reporting; `restored` / `snapshots-disabled` / `unavailable` reaches the banner and REST client;
      and `/timeline`, `/fork`, and `/clone` are wired through the inline REPL, full-screen client,
      server, and client APIs.
- [x] **Phase 14 — Agents, personas, and plan mode.** An agent is a value — a name, a system prompt, a
      model, a permission ruleset, a mode. Under one gateway this is unusually cheap: a per-agent
      model is another alias on the same endpoint, with no provider resolution and no second
      credential. Markdown-plus-frontmatter agent files are **inert data with no host and no hot
      reload**, so this does not breach the extension-system non-goal — a distinction worth stating
      plainly, because it looks adjacent to a refused feature and is not. Layered builtin → user →
      project resolution with project files behind the trust gate, and **hardened modes**: a project
      config may tighten a mode and may never widen it. Plan mode is built entirely from permissions
      plus a plan file under `.domocode/plans/`, needing no external-directory concept because the
      sandbox root already contains it, with `plan_exit` as a terminating tool (the loop already
      honours `terminate` and settles as `.terminatedByTool`). *Exit:* Tab switches between `build`
      and `plan`; plan mode provably cannot edit anything but its plan file. *Exit met:* inert
      Markdown agent profiles resolve builtin → user → trusted project, profiles carry model,
      reasoning, mode, and permissions, server sessions switch build/plan policy with Tab, and the
      hardened plan rules allow writes only to the session's `.domocode/plans/<session>.md` while
      `plan_exit` terminates the loop.
- [x] **Phase 15 — Subagents.** Transformative, and the most expensive item here. Requires 14, 11, 9
      and 5c. It disturbs a real invariant: `AgentHarness.run` throws if already running and the
      server allows one run per session, so a background child must be a separate harness instance and
      a result arriving while the parent is idle must be able to *start* a run. Child sessions are
      real, resumable sessions with `parentSession` set — navigable, not summarized black boxes — with
      a `task` tool carrying `task_id` resumption, derived child permissions (parent *denies* inherit,
      capabilities do not), a `subagent_depth` cap, and background children whose results arrive
      through the Phase 9 queue. Child permission prompts bubble to the parent's UI by constructing
      the child's engine with the *root* session id — one argument, and the whole feature. Delegation
      is modelled as a typed event across `AgentEvent`, `ServerEvent` and the session payload, including
      JSONL and `-p` JSON projections. **Complete:** plan-mode delegation creates real `explore` child
      sessions, foreground and background runs are supported, task ids recover after restart, and the
      client sidebar can enter a child and press `b` to return to its parent.
- [x] **Phase 16 — LSP and code intelligence.** Independent of 14 and 15; can run in parallel. The
      cheap version ships first behind the same protocol as the expensive one, so nothing is thrown
      away: a `DiagnosticsProvider` implemented by a **CLI provider** (`swift build`, `tsc --noEmit`,
      `cargo check --message-format=json`) has no server lifecycle, no resident memory, and real value
      in a week. Then a real LSP client using the same persistent-process and JSON-RPC correlation
      contract as `DoMoMCP` (plus Content-Length framing), with per-root pooling and push+pull
      diagnostics merged. Post-edit diagnostics are appended to `edit`/`write` results as
      `<diagnostics>` blocks the model reads — errors only, capped. Auto-format after write lands here
      too, and needs **an explicit decision about its permission story**: running a project-configured
      binary after every write is an execution path the permission engine currently never sees.
      **Complete:** CLI compiler diagnostics attach capped, error-only `<diagnostics>` blocks after
      successful mutations; the pooled LSP provider handles Content-Length framing and merges pull
      results with pushed diagnostics; and `autoFormat` is a trusted, opt-in setting whose command
      runs only after the mutation has passed its permission decision. *Exit met:* an edit that breaks
      the build comes back with the compiler's own error attached.
- [x] **Phase 17 — Memory and recall.** The best value-to-cost ratio left after Phase 5, and it needs
      no new storage and no network. `session_recall` searches and reads this project's own past
      sessions, ranked over user text, assistant text, file references and tool *errors* while
      excluding reasoning and successful tool output — with recalled content labelled untrusted and
      elided in the middle rather than the tail. Then durable typed project memory outside the repo
      (project / environment / corrections / per-session digests) with a byte-budgeted index,
      `/memory`, and the secret-redaction gate from 5a on every write so there is exactly one
      definition of what counts as a secret. **Complete:** `session_recall` is available to the model
      in inline, headless, and server-backed sessions; historical excerpts are ranked and middle-
      elided inside an explicit untrusted boundary; `ProjectMemoryStore` persists typed records in a
      locked, atomic, owner-only file outside the checkout with upsert/delete semantics and a total
      byte budget; the model-facing `memory` tool asks before writes while `/memory` is available in
      both terminal surfaces and the remote client. Every title, ID, content, session ID, and tag is
      rejected if the shared Phase 5a redaction registry would change it. *Exit met:* a prior decision
      is searchable inside the session, and no secret-shaped input is accepted into a memory file.
- [x] **Phase 18 — Sandboxing and permission hardening.** The honest framing: `PathSandbox` confines
      the file tools and **bash is not confined at all**, so a reader could reasonably conclude the
      whole harness is sandboxed. This closes that and documents it. A pluggable OS backend with
      **fail-closed** selection — Seatbelt on macOS, bubblewrap on Linux, and a hard error rather than
      a silent downgrade when confinement cannot be established — with a parameterized SBPL policy
      that never string-interpolates a path, so it is unit-testable without spawning a process.
      Environment scrubbing and pinning is the cheapest high-value item in the phase. Project config
      may only *tighten* policy, expressed as a per-key lattice applied inside `resolvedRuleset` so
      nothing downstream can get it wrong — generalised to `mcpServers`, where a project may disable a
      user's server and never add one. Also argument-level narrowing for MCP tools, whose permission pattern is
      `*` today, so one "allow always" grants the whole tool forever. (Two-tier base-vs-saved
      resolution already shipped in 8a: `resolvePermission` returns a config `deny` before it will
      honour any saved allow.) *Exit:* `--sandbox` confines
      every model-originated process or refuses to run and says which backend was unavailable.
      **Complete:** `ProcessSandbox` now selects Seatbelt or bubblewrap fail-closed, passes the
      workspace as data to a constant Seatbelt policy, binds only system trees plus the workspace on
      bubblewrap, and pins/scrubs child environments. `--sandbox` reaches shell, background, MCP,
      formatter, diagnostics, Git, shadow-Git, and LSP process paths. Trusted project permissions
      can only tighten the upstream lattice; project MCP settings can disable an existing user
      server but cannot introduce or replace one; and unknown/MCP tool grants are scoped to canonical,
      glob-inert argument payloads. *Exit met:* `--sandbox` never silently falls back to an
      unconfined model-originated process.
- [x] **Phase 19 — PTY and interactive terminal.** Harder here than in any surveyed harness, because
      of the client/server split. Control messages already flow client→server over REST
      (`/prompt`, `/abort`, `/permission`), but there is no *streaming* channel to carry keystrokes
      into a live process, and SSE cannot become one. A
      server-owned PTY service with a bounded retained ring and a two-step attach (replay-then-
      activate) closes the race where bytes arrive between replay and subscription. `VTScreen` is a
      separate small emulator for foreign programs: cursor motion, erase/edit operations, scrolling,
      SGR, alternate-screen modes, OSC titles, split UTF-8, and common line editing are interpreted
      without feeding untrusted output into the renderer. `interactive_terminal` ships
      **inline-first**: the inline CLI owns a PTY-backed provider, routes raw keyboard bytes to the
      active child, and exposes a bounded VT projection; print and remote contexts return a
      model-visible refusal until a client input channel exists. Sandboxed inline sessions reuse the
      same `ProcessSandbox` launch plan as shell and background processes. The server runtime owns
      session-scoped PTYs and cleans them up on shutdown, but does not pretend SSE can provide input.
      *Exit met:* replay/activation, input round trips, bounded retention and gap reporting, VT
      interpretation, inline provider actions, headless refusal, sandbox propagation, and server
      session ownership are covered by focused tests; the live PTY path is suitable for `gh auth
      login` and ssh passphrase prompts.
- [x] **Phase 20 — Export, replay, and scriptability.** Small and self-contained. Markdown transcript
      export has content flags plus a full-screen content-options dialog, and `/copy` uses the same
      formatter — the export people actually want, shipped before the HTML viewer. Single-file HTML
      export is implemented as a **second `ToolRenderTheme` emitting spans instead of SGR**, so
      `DoMoToolsUI`'s renderers are reused verbatim rather than duplicated. **Trajectory replay** is
      a `ReplayToolExecutor` keyed by tool-call id over a recorded stream, driven by both
      `domo --replay <session> --until <entry>` and `domo replay [<session>] --until <entry>`; it
      validates the branch and writes a normal resumeable session without snapshot infrastructure.
      *Exit met:* `domo export --html`, the shared Markdown copy flow, and replay branch creation are
      covered by focused debug/release tests; the replay report gives the new session path for a live,
      divergeable follow-up.
- [x] **Phase 21 — Split-footer render mode.** Very large, depends on nothing, retires debt, and can
      be pulled forward at any time. The alternate screen is the default today, which is why DoMoCode
      has paid to rebuild what the terminal does for free: ~739 lines of in-app drag selection, a
      mouse-capture debt the code documents, an F8 escape hatch and an OSC 52 copy path. A DECSTBM
      split-footer mode — transcript appended into real scrollback, footer pinned to the bottom N rows
      — makes most of that optional and restores the property
      [Non-goals](#non-goals-and-known-gaps) lists as the largest cost the expansion accepted. With
      OSC 133 semantic prompt marks, which only pay off once there is real scrollback. *Exit met:*
      `domo --mini` gives a live prompt with a genuinely selectable, searchable, shell-composable
      transcript above it. The shipped mode reuses the interactive agent loop and PTY path, pins a
      measured multiline footer with DECSTBM, resets terminal margins on crash-safe teardown, and
      emits OSC 133 prompt and command boundaries. Terminal-oracle and real-binary PTY tests cover
      append scrolling, retained history, resizing, cursor placement, image cleanup, and mode
      selection.

### Decisions that reverse a stated non-goal

None of these are folded into a phase above. Each needs an explicit yes before it can be scheduled.

| Reversal | Needed for | Recommendation |
|---|---|---|
| **TypeScript extension system** | plugin hosts, `registerTool`/`registerCommand`, hot reload | **Stay dropped.** Swift has no in-process plugin ABI and a JS runtime breaks SPM-only. The in-scope substitute is **shell hooks** — `.domocode/hooks.json` mapping lifecycle events to subprocess commands with matchers and timeouts, trust-gated. Out-of-process extensibility with zero runtime dependency; it would slot after Phase 11. (Auto-format itself does not wait on this: it is Phase 16, run from a formatter registry rather than a user hook.) |
| **Multi-provider** | talking to a model without a proxy in front; subscription auth (Claude Pro/Max, ChatGPT Plus) | **Stay dropped** — it is the founding premise. Per-alias `modelOverrides` (5a) plus named profiles keyed on model/effort/permissions rather than base URL gets most of the practical value inside it. |
| **OAuth** | remote MCP, provider login, marketplaces | **The reversal most worth considering** — but note the README has been stricter than necessary. The transport half of remote MCP (`{type: remote, url, headers}` with a static bearer) needs **no OAuth at all** and is buildable today. Ship that as a small phase; decide OAuth separately. |
| **A supervising daemon** | warm singleton, multi-instance supervision, live share, persistent background processes | **Stay dropped**, but two in-scope substitutes capture most of the win: a parent-PID watchdog so an embedded server cannot be orphaned, and `domo -p --attach <url>` reusing a warm server's already-connected MCP servers — every `-p` run currently spawns and tears down every stdio server, which for an `npx`-launched one is seconds per invocation. |
| **A package manager** for skills, themes, extensions | distribution | **Decline for now**; revisit only if people are actually authoring skills after 5b. Reading `.claude/skills` and `.agents/skills` in place gives day-one compatibility with no distribution mechanism at all. |
| **Windows** | the platform | Nothing in the plan assumes it. |

Boundary-adjacent, not literally on the non-goal list, but worth deciding deliberately: **ACP over
stdio** (`domo acp`) is a stdio subprocess speaking a documented protocol with *zero* editor-side code
to maintain, and becomes cheap once Phase 14's registry exists; a **second read-only sandbox root** for
cloned reference repos preserves the single-root invariant that the whole tool layer is built on, where
a multi-root sandbox would weaken it; and **any phone-home at all** — there is none today, and a
notification centre, an update check or analytics would each be the first.

Phases 0–3 produced a genuinely useful headless tool; Phase 4 (the inline TUI) was the largest single
body of the *port*, and Phase 7 (the full-screen client) the largest net-new subsystem. The expansion
was ordered by dependency, not by appeal: the server came **before** the full-screen TUI, because the
TUI-as-client model presumes a server to attach to and the inline renderer cannot faithfully replay a
session's scrollback to a late client; image *input* was pulled early because it is cheap and
orthogonal; the permission engine preceded MCP because it is a safety prerequisite, not a nicety.

Two things are worth recording for anyone planning similar work. The full-screen renderer had **no
upstream oracle at all**, and building its test harness cost about as much as its implementation.
And Phase 8.5 exists because a subsystem can be fully tested and still be broken in the one
configuration the tests never construct — the alt-screen machinery was green throughout, because
every test fed it `?1049h` itself while the shipping client never did. Smoke-test the real binary.

### The dependency spine

Six seams gate most of the remaining surface. Every phase above is placed relative to these, and the
ordering falls out of them rather than out of appeal:

| Seam | Today | Unblocks |
|---|---|---|
| **System-prompt builder** | `SystemPromptBuilder` loads trusted system/instruction files and active skills | agents, plan mode, tool-visibility rewriting |
| **Command registry** | one shared registry, `GET /commands`, and template-backed dispatch | palette polish, keybindings, plan-exit UI |
| **Dialog vocabulary** | one bespoke permission modal per surface | `question`, every picker, settings, export options, diff review |
| **Per-turn mutable tool set** | `AgentHarness` resolves tools and rebuilds the prompt list per request; MCP `tools/list_changed` refreshes the live manager | plan mode, agents, subagents |
| **Git facade** | none | diff viewer, `/review`, checkpoints, undo, worktrees, branch in footer |
| **Model metadata** | ~~200k hardcoded; cost always zero~~ — **closed in 5a**: per-alias `modelOverrides`, an optional context window (`nil` renders `?`), and cost from rates or the gateway's own header | ~~context meter, cost display~~ (both shipped); budget cap shipped in Phase 9 |

### Scale

Honest sizing, so the roadmap is not read as a quarter's work. Phase 5 alone is multi-month.

| Phase | Scale | | Phase | Scale |
|---|---|---|---|---|
| 5a Truth and plumbing | weeks | | 14 Agents and plan mode | 1–2 months |
| 5b Command layer | ~1 month | | 15 Subagents | **multi-month** |
| 5c Dialogs and pickers | **multi-month** | | 16 LSP | weeks → **multi-month** |
| 5d Terminal polish | weeks | | 17 Memory and recall | 1–2 months |
| 9 Steering and run control | weeks | | 18 Sandboxing | **multi-month** |
| 10 Context engineering | ~1 month | | 19 PTY | **multi-month** |
| 11 Mutable tools + tool suite | 1–2 months | | 20 Export and replay | weeks |
| 12 Git, diff, review | **multi-month** | | 21 Split-footer | **multi-month** |
| 13 Checkpoints and undo | **multi-month** | | | |

## Sibling harnesses and prior art

pi is DoMoCode's upstream, but it is not the only coding-agent harness worth reading. Three others
sit alongside it in this workspace and were studied in depth, mostly to decide — feature by feature —
what a LiteLLM-only terminal harness should adopt, adapt, or refuse. Each is MIT or MIT-cored and
independently developed; full attribution and the license nuances are in [NOTICES.md](NOTICES.md).

This section used to claim none of their code was copied or derived. That stopped being true at
Phase 8: **`DoMoPermissions` contains code ported from opencode and kilocode** — the wildcard matcher,
the bash arity table, the policy evaluator, the config codec, the engine, the request vocabulary, the
request factory and the settings writer. Those files carry dual copyright headers, and
[NOTICES.md](NOTICES.md#other-prior-art) records them file by file. Everything else below really is
idea-only.

- **[pi](https://github.com/earendil-works/pi)** — MIT, © 2025 Mario Zechner. The direct upstream.
  DoMoCode derives code from it; everything below is measured against it.
- **[opencode](https://github.com/anomalyco/opencode)** — MIT, © 2025 opencode. An original
  client/server agent from the SST team: an Effect-`HttpApi` server hosts the runtime and is driven
  by a full-screen SolidJS/OpenTUI terminal app, a web app, an Electron desktop app, editor
  extensions, and a headless mode — many clients attaching to one server.
- **[kilocode](https://github.com/Kilo-Org/kilocode)** — MIT, © 2026 Kilo Code and © 2025 opencode.
  A multi-surface platform monorepo. Its CLI harness (`@kilocode/cli`, binary `kilo`) is a
  maintained *fork of opencode* (hence the dual copyright); the same repo also ships VS Code and
  JetBrains extensions descended from a separate Cline → Roo Code lineage.
- **[OpenHands](https://github.com/OpenHands/OpenHands)** — MIT core (with a PolyForm-licensed
  `enterprise/` subtree that was excluded from study), controlled by All Hands AI. Formerly
  OpenDevin: a self-hosted web "developer control center" (FastAPI + a React SPA) that orchestrates
  agents across local, Docker, remote-VM, and Kubernetes sandboxes. Only its MIT tree was read.

### What they share, and where DoMoCode diverges

All three converged on the same shape: a headless HTTP/SSE (or Effect-`HttpApi`) server hosting the
agent runtime, driven by many clients, with a full-screen widget-toolkit TUI (OpenTUI/SolidJS) or a
React SPA as just *one* front-end. DoMoCode's founding thesis defined itself *against* that shape — a
single process, an inline-scrollback renderer, no widget toolkit. The
[scope expansion](#what-expanded-and-what-did-not) reversed that, in the narrowed form the roadmap
records: DoMoCode **adopted the server shape** (bounded to a local, loopback-only,
single-client-first HTTP/SSE server, modeled on opencode's `server.ts`/`event.ts`) and grew a
**full-screen event-store client** beside the inline renderer — built in-house, because OpenTUI is
TypeScript and has no Swift port, so only its retained-cell-buffer-plus-flexbox *design* is borrowed,
never code. What DoMoCode still refuses is the *rest* of the cluster: a client-side multi-provider
abstraction (model breadth stays the LiteLLM gateway's job), OAuth login, a JS/TS plugin system, an
extension/skill/theme marketplace, mDNS/multi-device presence, and any web/IDE/desktop GUI. MCP crossed
from the refused column to a shipped feature (stdio-local only); the multi-client,
remote-MCP-with-OAuth, and daemon breadth stays out. So the survey no longer merely *reaffirms*
DoMoCode's boundaries — it moved four of them, each at a named cost.

### Features worth adopting

**This workspace has now been surveyed twice.** The first pass, below, covered the three siblings and
was filtered through the narrowed thesis, asking which handful of features fit inside it. The second
pass asked the opposite question — *what would it take to be fully featured* — and swept all four
repositories, upstream pi included, across sixteen feature domains, fit-checking every candidate against DoMoCode's actual code. It found **706 distinct
capabilities DoMoCode does not have**: 37 rated transformative, 282 high value. The
[roadmap](#roadmap) sequences everything rated transformative or high, plus most of the medium band;
what is left out is named under [Non-goals](#non-goals-and-known-gaps) rather than left to be
rediscovered. The table below is kept as the record of the first, narrower judgment.

The second survey's blunt finding: the most valuable single absent capability is **checkpoints and
undo** (Phase 13); the cheapest large win, **`AGENTS.md` loading**, is now shipped in Phase 5b and
changes every response the agent gives.

"Fit" below is judged against the [non-goals](#non-goals-and-known-gaps): a new *first-party* tool is
`adaptable`, not free, because the extensibility non-goal forbids plugin-defined tools, not new Swift
ones — each addition still forces a tool-vs-prompt-injection and in-process-vs-out-of-process decision.

| Feature | Seen in | Fit | Lands in |
|---|---|---|---|
| Granular permission engine (allow/ask/deny globs, last-match-wins, inline once/always/reject) | all three | yes | **Shipped** (Phase 8) |
| Headless run (prompt in, streamed/JSON out, exit codes, auto-approve) | kilocode, opencode | yes | **Shipped**, as flags rather than a subcommand: `-p` / `--json` / `--yolo`, exit codes 0–4 |
| Git-shadow snapshot checkpoints + undo/redo + fork-from-any-message | kilocode, opencode | yes | **Shipped** (Phase 13) |
| Config-driven agent/persona profiles + a read-only plan mode | all three | yes | **Shipped** (Phase 14) |
| Auto-format-after-edit hook; repo `.setup.sh` session-init hook | all three | yes | **Shipped** (Phase 16 format); hooks await the [extensibility decision](#decisions-that-reverse-a-stated-non-goal) |
| Hard per-task budget cap (abort the loop on a cost ceiling) | OpenHands | yes | **Shipped** (Phase 9; enforced when usage is priced by gateway or configured rates) |
| Trusted-config `{env:}`/`{file:}` interpolation gated by the trust boundary | kilocode | yes | Phase 5a |
| Local `/review` of a diff, branch, or commit | kilocode, OpenHands | yes | Phase 5b |
| Skill refinements: keyword auto-injection, task-input `{VAR}` templates | all three | yes | Phase 5b |
| Slash-command polish: `$ARGUMENTS`/`$N`, inline `` !`shell` ``, per-command overrides, ANSI-index / `none`=inherit theming | opencode, kilocode | yes | Phase 5b (commands) + 5c (themes) |
| First-party tool additions: `question`/`suggest`, todo checklist, `webfetch` (+ gated `apply_patch`, notebook-edit, `recall`) | all three | adaptable | Phase 11; `recall` shipped in Phase 17. `websearch` needs a second vendor and stays out |
| Untrusted session recall plus typed durable project memory | all three | yes | **Shipped** (Phase 17; JSONL recall and an atomic, byte-budgeted memory file) |
| Selectable/tunable history condensers (observation-masking, recent-window, LLM-summarizing) | OpenHands | adaptable | **Shipped** (Phase 10) |
| Local conveniences: prompt stash, `/btw` side-branch, background jobs, file watcher, JSONL replay, local secrets + env injection, out-of-process notify/sound | opencode, kilocode, OpenHands | yes/adaptable | Scattered: stash in Phase 9, background jobs in 11, replay in 20, notify/sound in 5d, secrets in 5a. Prompt *history* shipped in 8.5; a file watcher remains unscheduled |
| Out-of-process research items: ACP single-session stdio subcommand, LSP post-edit diagnostics, Seatbelt/bubblewrap bash sandbox, local semantic index | all three | adaptable | LSP **shipped in Phase 16**, the sandbox Phase 18; ACP awaits a [decision](#decisions-that-reverse-a-stated-non-goal); the semantic index is [not planned](#non-goals-and-known-gaps) |

The semantic-index row is the sharpest example of "adapt, don't adopt": the idea ports only if
embeddings come from the single LiteLLM gateway's OpenAI-compatible `/embeddings` into an
SPM-resolvable local store — an external Qdrant or a second embedding provider would breach both the
single-provider and the SPM-only / no-vendored-binaries constraints.

### Features declined

This list has shrunk twice. The [first scope expansion](#what-expanded-and-what-did-not) moved four
items out of it — the server, the full-screen TUI, MCP and inline images — and all four shipped. The
turn toward a fully-featured harness moves more: **sandboxing (Phase 18), an interactive full-screen
diff pane (Phase 12) and a PTY with an interactive terminal (Phase 19) are all now roadmap phases**,
not exclusions. What remains below is what stays out, each against a named constraint — and the six that
are genuinely the owner's call are tabulated in
[Decisions that reverse a stated non-goal](#decisions-that-reverse-a-stated-non-goal) rather than
settled here:

- **Multi-provider model layers and wire-protocol adapters** — DoMoCode has one surface (LiteLLM);
  model breadth is the gateway's job, so the client-side abstraction is both disallowed and
  redundant. This one did *not* move.
- **OAuth / device login, JS/TS plugin systems, in-process JS interpreters (kilocode's "CodeMode"),
  and extension/skill/theme marketplaces** — the declared extensibility, bearer-key-only, and
  package-manager non-goals; several also need vendored binaries (SPM-only). MCP is no longer in this
  bullet — it shipped in Phase 8 — and only the *OAuth* half of remote MCP is still deferred: a remote
  server reached with a static bearer header needs none, and is buildable today.
- **Detached daemons, multi-instance supervision, mDNS, multi-device sync, and multi-backend
  (Docker/K8s/remote) sandboxes** — still out. DoMoCode's own server (Phase 6) is deliberately the
  opposite, narrow slice: one local loopback endpoint, single-client-first, no supervision and no
  discovery. The *local* Seatbelt/bubblewrap wrap of the bash tool is no longer a "later candidate" —
  it is Phase 18, and it is the phase that makes the sandboxing story honest.
- **Web / GUI / IDE / desktop UI** — embedded VSCode/browser panes, a hosted web console, an Electron
  app and editor extensions stay out. The *interactive full-screen diff pane* has left this bullet:
  it is a terminal feature, it is Phase 12, and declining it was a category error — DoMoCode builds a
  full-screen terminal UI on the inline renderer's own primitives, and a diff pane is exactly that.
  The OpenTUI/SolidJS/React foundations and every non-terminal surface still stay out.
- **Cloud agents, webhooks, cron automations, git-provider issue-resolvers, and inline
  FIM/speech-to-text** — daemon + OAuth + non-terminal-input constraints. Only the local headless
  path is in scope — `domo -p`, invoked from an external job the user owns.

## Dependencies

Every direct dependency must resolve on the floor toolchain (Swift 6.3). Several pins below were previously version caps
imposed by the 6.1 floor rather than stability judgments; those caps are gone and the table records
the versions that replaced them.

The deployment floor is **macOS 15**, raised from 13. `Synchronization.Mutex` and `Atomic` are gated
`@available(macOS 15)` on Apple platforms — they are unconditional on Linux — and they are how shared
mutable state is handled here, per [Concurrency](#concurrency-and-isolation). macOS 15 shipped in
September 2024; requiring it for a developer CLI is not aggressive.

These thirteen resolve as a set on a 6.2 manifest under a 6.3 toolchain, and to a graph of **34 pinned packages** once
transitive dependencies are counted — the AsyncHTTPClient tail (NIO, NIO-SSL, NIO-HTTP2,
swift-certificates, swift-crypto, swift-asn1, service-lifecycle) and swift-syntax 603, pulled by
swift-json-schema for its macros, account for most of that. swift-syntax is the single largest
build-time cost in the graph; if clean-build time becomes intolerable, dropping to swift-json-schema's
non-macro modules and hand-writing the tool schemas removes it.

**The whole expansion cost exactly one dependency: Hummingbird.** Three others were planned and none
was needed. The MCP Swift SDK was replaced by a hand-rolled client (Phase 8c) — its stdio transport
does not spawn the subprocess, and it pins `swift-docc-plugin` to a git *branch*, which is a
reproducible-resolution liability; the fallback the table below had already pre-justified is what
shipped. swift-png/swift-jpeg were needed only for resizing attachments, and images are passed through
unresized (an oversized attachment is rejected, not downscaled), so nothing decodes pixels — image
bytes are only ever inspected by hand-written header readers: `DoMoExec`'s magic-number media-type
sniffer and `DoMoTermGraphics`'s dimension parsers. GRDB is still unused because JSONL remains the only `SessionStorage`
implementation. The full-screen TUI (Phase 7) and the whole Phase 8.5 pass added *no third-party*
dependency: Phase 7's only manifest change was declaring the new `DoMoClient` target and its test
target, and Phase 8.5's was a single intra-package edge from `DoMoClient` to `DoMoExec`.

| Package | License | Why |
|---|---|---|
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | CLI flags, subcommands, shell completions. `from: "1.8.2"`. |
| [swift-server/async-http-client](https://github.com/swift-server/async-http-client) | Apache-2.0 | The transport that streams incrementally with backpressure on both Darwin and Linux. `from: "1.35.0"` — the 6.1 floor capped this at 1.30.3. |
| [apple/swift-http-types](https://github.com/apple/swift-http-types) | Apache-2.0 | Currency types for the transport seam, so URLSession can be swapped in on Apple-only builds. `from: "1.6.0"`. |
| [mattt/EventSource](https://github.com/mattt/EventSource) | MIT | Transport-free incremental SSE parser, driven directly rather than via its client. `from: "1.4.1"`. |
| [ainame/swift-displaywidth](https://github.com/ainame/swift-displaywidth) | MIT | Grapheme-cluster-aware terminal cell width. A width bug corrupts every subsequent column on a line, so this is load-bearing for the renderer. Pre-1.0 and single-maintainer, so `.upToNextMinor(from: "0.1.0")` — `from:` would admit a breaking 0.2.0. |
| [apple/swift-system](https://github.com/apple/swift-system) | Apache-2.0 | `FilePath`, `FileDescriptor`, `Errno`. Note it does *not* expose termios or ioctl. `from: "1.7.5"`. |
| [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess) | Apache-2.0 | Async subprocess with cancellation that reaches the child. `from: "0.5.0"` — the previous sub-0.5 pin was a toolchain cap, not a stability choice. `1.0.0-beta.1` is usable but needs `.exact()`, since SwiftPM never selects a pre-release via `from:`. |
| [apple/swift-log](https://github.com/apple/swift-log) | Apache-2.0 | Logging facade; handler tees JSON to the session log and human text to stderr. `from: "1.14.0"` — the 6.1 floor capped this at 1.10.0. |
| [jpsim/Yams](https://github.com/jpsim/Yams) | MIT | Permissive YAML frontmatter in skills and prompt templates. `from: "6.2.2"` — that is Yams' own semver and has nothing to do with the Swift version. |
| [ajevans99/swift-json-schema](https://github.com/ajevans99/swift-json-schema) | MIT | Tool-schema generation *and* draft-2020-12 validation of returned arguments — validation is the half that protects you. `.upToNextMinor(from: "0.13.1")`, pre-1.0. |
| [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0 WITH Swift-exception | cmark-gfm AST for the Markdown component. `.upToNextMinor(from: "0.8.0")` — the 6.1 floor capped this at 0.7.1. The repository moved from `apple/`, which now redirects; pin the semver tag, never a `swift-6.x.y-RELEASE` tag. |
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | **Not declared.** Held for a possible SQLite session store at `from: "7.11.1"`, validated against this graph and recorded as a comment in `Package.swift`. JSONL is still the only `SessionStorage` implementation. |
| [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | **Test target only** — a headless VT100 emulator used as a test oracle. Renderer bytes go in, assertions run against the resulting cell grid. Without it the riskiest code in the port has no end-to-end coverage on a TTY-less CI runner. `from: "1.15.0"`. Builds in Swift 5 language mode, so expect `Sendable` friction at the boundary from a `[.v6]` test target. Note: it does *not* emulate the Kitty/iTerm2 graphics protocols, so image *display* (Phase 7.5) has weaker automated coverage than the rest of the renderer. |
| [hummingbird-project/hummingbird](https://github.com/hummingbird-project/hummingbird) | Apache-2.0 | **Phase 6, shipped.** HTTP router + streaming SSE for `DoMoServer` (an SSE body is just a response streamed from an `AsyncSequence`). Built directly on swift-nio, already resolved via async-http-client, so it added little to the graph. `from: "2.25.1"`. Vapor was assessed and declined — heavier graph, older `EventLoopFuture`-era surface. |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | MIT / Apache-2.0 | **Not declared — the pre-justified fallback is what shipped.** It was to be the MCP client for `DoMoMCP` at `.upToNextMinor(from: "0.12.1")`. Two blockers decided it: its `StdioTransport` does not spawn the server subprocess (so the hard part was ours either way), and it pins `swift-docc-plugin` to a git *branch*. `DoMoMCP` is instead a hand-rolled JSON-RPC-2.0-over-stdio client on `JSONValue` + swift-subprocess, both already present. |
| [tayloraswift/swift-png](https://github.com/tayloraswift/swift-png) | Apache-2.0 | **Not declared.** Pure-Swift PNG decode/encode, needed only if attachments must be resized to fit provider byte caps. Images are passed through unresized and an oversized one is rejected, so nothing decodes pixels — only the hand-written header-only dimension parsers in `DoMoTermGraphics` read image bytes. |
| [tayloraswift/swift-jpeg](https://github.com/tayloraswift/swift-jpeg) | Apache-2.0 | **Not declared**, for the same reason as swift-png. |

### Deliberately not used

- **TUI frameworks** (SwiftTUI, TermKit, TUIkit, ncurses bindings) — assessed for the full-screen mode
  (Phase 7) and declined in favor of building the layout layer in-house. That was a *build-vs-adopt*
  decision, not a no-widget-toolkit stance, and the build side of it has since shipped.
  `rensbreur/SwiftTUI` (MIT, `swift-tools-version: 5.6`) was the closest fit, but every candidate
  *owns* the screen, the stdin read loop, and the event model: adopting one would have meant running a
  second terminal-owning stack beside `DoMoTermIO`'s key-decoding / framing / keybindings seam,
  rewriting `Editor` / `Markdown` / `Autocomplete` / `SelectList` as framework views, and surrendering
  the byte-level diff, the width-invariant check, and `CSI ?2026` synchronized output to a reactive
  whole-tree recompute — all on a pre-1.0 dependency. The in-house path added an alternate-screen mode
  plus a flexbox-lite layout layer *above* the existing 1-D `Component` protocol, reusing the width
  engine, `RenderCore`'s mode-independent helpers (per-line resets, output normalization, the
  synchronized-output wrapper), and every built widget unchanged. The frame differ itself is not
  reused: `AltScreenCore` is a sibling with its own absolute-`CUP` diff, because a fixed-height buffer
  and a growing scrollback do not diff the same way.
  (`swifttui.sh`'s swift-tui is separately disqualified: its manifest declares
  `swift-tools-version: 6.3`, above the floor, so it will not resolve.)
- **TauTUI** ([steipete/TauTUI](https://github.com/steipete/TauTUI)) — the one Swift package that
  gets the architecture right: an honest, well-attributed port of pi-tui that renders inline into
  scrollback with relative cursor motion and `CSI ?2026` synchronized output, no alternate screen
  anywhere. It resolves fine on 6.2. It is still not adopted, for three reasons. **Coverage:** 5,382
  lines of Swift against pi-tui's 12,184 of TypeScript, and the gap is concentrated exactly where a
  coding-agent harness lives — overlays, the keybindings manager, kill-ring, undo, fuzzy match,
  `modifyOtherKeys` fallback, and hardware-cursor positioning have *zero* occurrences in its sources.
  **Staleness:** its own `docs/pitui-sync.md` records its last upstream inspection as pi-tui 0.29.0
  (2025-12-27); this port targets 0.81.1, roughly seven months and fifty minor releases later.
  **Defects with no seam to fix them:** an incomplete escape sequence split across two `read()`
  boundaries decodes as literal keystrokes (`ESC`, `[`, `A` instead of Up), and appending a line once
  the transcript exceeds the viewport emits a cursor-down that clamps at the bottom margin instead of
  scrolling, overwriting the transcript. Both live in `private` methods of `public final` classes.
  TauTUI is read closely as a Swift-idiom reference — the `Terminal` protocol seam,
  `render(width:) -> [String]`, grapheme-correct editing via `Character` — but no TauTUI code is
  depended on or vendored.
- **terminal-ansi** ([juri/terminal-ansi](https://github.com/juri/terminal-ansi)) — newly resolvable
  at 6.2, and a real package: an incoming escape-sequence parser, escape-aware word wrapping,
  terminal size, and OSC queries including background-color detection. Not adopted at Phase 0 because
  it overlaps the one subsystem this project has decided to own end to end, and because it means a
  pre-1.0 single-maintainer package with a vendored C shim sitting under the key decoder — the same
  bet declined above. Its OSC-query surface is the genuinely non-duplicative part, and the revisit
  never happened because nothing has needed it: there is no background-color detection in the tree,
  and no theming to want it until Phase 5c.
- **swift-collections** and **swift-async-algorithms** — not *direct* dependencies, but both are
  already in the resolved graph and already built: `swift-collections` 1.6.0 arrives via swift-nio,
  swift-json-schema, and swift-configuration, and `swift-async-algorithms` 1.1.5 via swift-nio-extras
  and swift-service-lifecycle. So the usual "extra build cost" argument against them does not apply —
  declaring either directly costs nothing but an import. They stay out only because nothing needs
  their API yet. Take `swift-collections` when scrollback wants a real `Deque`; take
  `swift-async-algorithms` for `AsyncChannel` if a bounded queue is ever needed, since the standard
  library still has no first-class backpressure and `AsyncStream`'s buffering policies drop rather
  than apply pressure — which is correct for keyboard input and irrelevant for SSE, where the network
  is the backpressure.
- **swift-termios** ([minacle/swift-termios](https://github.com/minacle/swift-termios)) — still
  unresolvable. Its only tag declares `swift-tools-version: 6.3`, above this project's floor, and
  there is no older tag. Raw termios comes from `DoMoTermIO`'s own POSIX shim.
- **Color libraries** (Rainbow, ColorizeSwift) — styling is injected as `(String) -> String`
  closures; there is nothing to depend on. About 60 lines of SGR helpers instead.
- **swift-openapi-generator / MacPaw/OpenAI** — a generated strict decoder fails where a lenient
  hand-written one shrugs, and "OpenAI-compatible" servers deviate constantly. Roughly eight lenient
  `Codable` structs instead.
- **AnyCodable** — archived, and `value: Any` is fundamentally non-`Sendable`. `DoMoCore.JSONValue`
  instead.

### Written by hand

These are part of the port rather than a dependency. For most of them no Swift package exists at all;
for the terminal seam and the renderer, packages now exist and were evaluated and declined — see
[Deliberately not used](#deliberately-not-used). Raising the floor to 6.2 unblocked much of the
dependency graph, but it did not shrink this list by a single item.

Termios raw mode and panic-safe restore; terminal size and SIGWINCH; escape-sequence reassembly with
an incomplete-sequence hold and an ESC-disambiguation timeout, and key decoding (legacy tables, Kitty
CSI-u behind a real capability handshake, xterm `modifyOtherKeys` fallback); the differential frame
renderer, including viewport and append-past-the-viewport scroll bookkeeping; a tolerant partial-JSON
parser for streaming tool calls; the streaming tool-call accumulator; SSE `[DONE]` and in-stream error
handling; gitignore semantics and the file walker; realpath-based path sandboxing; the
Markdown-to-ANSI walker; and a SwiftTerm-backed test harness that asserts against a real VT100 cell
grid rather than against emitted bytes.

Two non-negotiables carried over from reviewing prior art: the key decoder is a **public, pure,
independently testable function**, not a private method on a terminal type — every keybinding layer
is built on it. And a display-width disagreement **throws a catchable error**; it never
`precondition`s, because `precondition` traps in release builds and an emoji is not a reason to kill
an agent mid-render.

## Configuration

Precedence, highest first: **CLI flag → environment variable → project
`.domocode/settings.json` (trusted projects only) → user `~/.domocode/settings.json` → built-in
default.**

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `DOMOCODE_BASE_URL` | `http://localhost:4000/v1` | LiteLLM proxy base URL. Note LiteLLM's default port is 4000. |
| `DOMOCODE_API_KEY` | — | LiteLLM virtual key. Falls back to `LITELLM_API_KEY`, then `OPENAI_API_KEY`. |
| `DOMOCODE_AUTH_HEADER` | `Authorization` | Header *name* — operators can configure a custom one, so this is not hardcoded. |
| `DOMOCODE_AUTH_SCHEME` | `Bearer` | Scheme prefix. |
| `DOMOCODE_MODEL` | — | The public model alias as configured on the proxy. |
| `DOMOCODE_SMALL_MODEL` | falls back to `DOMOCODE_MODEL` | The model compaction summarizes with. Consumed since 5a, but only when it **differs** from the run's model — otherwise the harness's own summarizer is kept, so configuring nothing changes nothing. `compaction.model` in settings.json outranks it. |
| `DOMOCODE_REASONING_EFFORT` | unset | `minimal` / `low` / `medium` / `high`. |
| `DOMOCODE_TIMEOUT_MS` | `600000` | Overall request timeout. `0` means the default — a literal zero would fail every request before the gateway could answer, and there is no "no deadline" to express here. |
| `DOMOCODE_STREAM_TIMEOUT_MS` | `120000` | How long a committed response may deliver **nothing** before the turn is failed. A 2xx has already committed the stream, so exceeding this fails the turn rather than retrying it — tighten it and you trade a hung turn for a lost one, since a model can legitimately go quiet through a long reasoning block. `0` removes DoMoCode's silence bound. Time-to-response-head is separately bounded by a fixed 10 s connect timeout. **This knob previously did nothing**; setting it now has an effect — but see the note below on its 90 s ceiling. |
| `DOMOCODE_MAX_RETRIES` | `10` | Client-side retry count for a *retryable* failure. `0` disables retrying. |
| `DOMOCODE_RETRY_BASE_MS` | `1000` | First backoff; each further attempt doubles it before jitter. |
| `DOMOCODE_RETRY_MAX_MS` | `60000` | Backoff ceiling, which also caps a server-supplied `Retry-After`. |
| `DOMOCODE_RETRY_BUDGET_MS` | `300000` | Total time one request may spend asleep between attempts. `0` means no budget. |
| `DOMOCODE_CONFIG_DIR` | `~/.domocode` | Settings, trust store, user commands, user skills, and durable project memory. (The default client theme surface shipped in Phase 5c.) |
| `DOMOCODE_SESSION_DIR` | `$CONFIG_DIR/sessions` | Session JSONL root, and the per-workspace prompt history beside it. Point this elsewhere and both move. |
| `DOMOCODE_LOG_LEVEL` | `warning` | Logs go to stderr; stdout is reserved for the JSON protocol channel. |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | — | **Not honored.** Nothing reads them, and the default transport is `HTTPClient.shared`, which cannot be given a proxy configuration. Behind a proxy, point `DOMOCODE_BASE_URL` at it directly. |

Secrets are never written to `settings.json` — `Settings` has no API-key field at all. `apiKeyEnv`
holds only the *name* of the environment variable to read, so the key value never touches disk.

### settings.json keys

```jsonc
{
  "modelOverrides": {
    "gpt-4o": { "contextWindow": 128000, "input": 2.5, "output": 10.0, "reasoningEffort": "high" }
  },
  "compaction": { "enabled": true, "reserveTokens": 16384, "keepRecentTokens": 20000, "model": "cheap-alias" },
  "contextWindow": 200000,
  "autoFormat": { "enabled": true, "command": "swift-format {file}", "timeoutMs": 30000 },
  "mcpServers": { "gh": { "command": ["npx", "-y", "server"], "environment": { "TOKEN": "{env:GH_PAT}" } } }
}
```

`modelOverrides` is what the operator knows that the gateway will not say: LiteLLM's `/models`
answers with names and nothing else, so every number here is operator-supplied. Prices are per
million tokens and may be written flat (as above) or nested under `rates`; they decode from a JSON
number **or a string**, because a `Decimal` written as a bare number can lose its last digits on some
platforms. An alias-level `reasoningEffort` outranks the global one. An alias with no entry has an
**unknown** context window, which a meter renders as `?` — not as a percentage of a guess.

The two dictionaries merge differently, deliberately: `modelOverrides` replaces a **whole entry** per
key (project over user, the `mcpServers` rule), while `compaction` merges **field by field** (the
rule every other numeric knob follows).

`autoFormat` also merges field by field, project over user. It is disabled unless `enabled` is true and
`command` is non-empty. `{file}` becomes the changed file's shell-quoted absolute path; without the
placeholder, that path is appended. The command runs under the same scrubbed environment as other
tool subprocesses, only after `write` or `edit` has passed the mutation permission decision, and a
formatter failure is reported to the model without turning the successful mutation into an error.
Because it executes a project-configured binary, a project value is available only after the normal
project-trust gate.

**Value interpolation.** Any string field above, plus `mcpServers.*.command`, `.environment` values
and `.cwd`, may contain `{env:NAME}` or `{file:PATH}`. Write `{{env:NAME}}` for a literal. The rules
differ by trust, following kilocode rather than opencode:

| | user `~/.domocode/settings.json` | project `.domocode/settings.json` |
|---|---|---|
| `{env:NAME}` | allowed, except the gateway-credential names | **refused** |
| `{file:PATH}` | any file | confined to the project directory, symlinks resolved |

An unset variable or an unreadable file is a **hard error** naming the token — never the value, and
never the file's contents. That is a deliberate divergence from opencode, whose silent empty string
turns a config typo into an unexplained 401. Interpolation happens at decode time, so it cannot
reach the integer-valued knobs (`timeoutMs` and the retry numbers), and the `permission` block is
never interpolated at all — which is what stops `{env:}` becoming a permission-widening vector.
Values substituted into a credential-carrying field are registered for redaction; a hostname is not,
because blanking it would destroy the one fact a connection failure needs to report.

### Retries

A busy or overloaded provider is the one failure that reliably clears on its own, so it is waited out
rather than reported. A retryable failure — HTTP 429/5xx, a transport error, or a body LiteLLM
normalizes into one of those — is retried up to `DOMOCODE_MAX_RETRIES` times on an exponential
schedule: `DOMOCODE_RETRY_BASE_MS`, doubling per attempt, capped at `DOMOCODE_RETRY_MAX_MS`, with
half jitter, and with `DOMOCODE_RETRY_BUDGET_MS` as the ceiling on total sleep for one request. A
server-supplied `Retry-After` (or `retry-after-ms`) wins over the computed delay, clamped to the same
maximum. A failure that arrives *before* the gateway ever answered keeps its own, far smaller budget,
because an unreachable host is not a busy one.

Nothing that cannot clear on its own is retried: a rejected credential, an exhausted quota, a context
overflow and a malformed response all fail immediately.

A retry of an **assistant turn** is announced while it happens rather than hidden — a waiting run says
so instead of looking frozen, which is what makes a ten-attempt budget acceptable. Each attempt reports
the wait, the attempt number and the reason (`Retrying in 8s (attempt 4/10) — provider busy`): the
full-screen client puts it on the status line until the wait is over or something else needs that line,
the inline REPL adds a dim transcript line, and `-p` writes it to **stderr** in both text and `--json`
mode, so stdout and the JSON event vocabulary are untouched.

One retry path is still silent, and it is a known gap: compaction's summarization request is driven
directly by the harness rather than through the agent loop, so it reaches no sink. A session that
compacts against a busy gateway can still pause without saying why.

**A ceiling worth knowing about.** The transport runs on `HTTPClient.shared`, whose singleton
configuration carries a 90-second read timeout that DoMoCode cannot set. That bound fires first, so
`DOMOCODE_STREAM_TIMEOUT_MS` is only really in force below 90 s — a larger value, including the
120 s default, is preempted, and `0` disables DoMoCode's own silence bound without lifting that one.
Raising it means constructing an owned `HTTPClient`, which is the same change proxy support needs.

### Command line

`--max-turns <n>` — **unlimited by default, in every mode** (the full-screen client, `--inline`,
`-p`, and `--serve`). A run continues until the model produces a final answer, you abort it, or the
runaway guard trips: twelve consecutive turns that made the same tool calls and got back the same
results. `--max-turns 0` is the explicit spelling of unlimited, for a caller that builds its
arguments programmatically; a negative value is a usage error. `0` cannot mean "zero turns" — the
loop emits `agent_start`/`turn_start` before its first bound check, so a literal 0 would settle a run
with a dangling `turn_start`.

`--max-cost-per-run <usd>` — an optional positive USD ceiling for the assistant turns in one run. The
loop adds each completed turn's effective cost (the gateway-reported value when present, otherwise the
configured per-model rates) and stops with exit code `4` once the ceiling is reached. An alias with no
reported or configured price cannot be hard-capped honestly, so the flag remains inert for unpriced
usage. `--steering-mode <all|one-at-a-time>` selects whether queued prompts are delivered as one batch
or one message per turn boundary; one-at-a-time is the default.

`--no-mouse` — never claim the mouse in the full-screen client. The app then reports no mouse events
at all, so the terminal's own selection and scrollback keep working and wheel scrolling inside the
app is lost in exchange.

Keys in the full-screen client: `Tab` moves between panes, `Enter` sends, `Alt+Enter` (or `Ctrl+J`)
inserts a newline so a prompt can be several lines, `↑`/`↓` walk the prompt history for this
workspace, `Ctrl+O` expands a truncated error to its full text, `Esc` aborts a running turn, and
`Ctrl+C` quits.

Under `-p`, the exit code is the run's verdict:

| Code | Meaning |
|---|---|
| `0` | The model produced a final answer (or a tool ended the run cleanly). |
| `1` | The run failed: a provider error, an aborted turn, a bad `finish_reason`. |
| `2` | The `--max-turns` limit was reached before a final answer. Only reachable when a limit was asked for. |
| `3` | The runaway guard stopped the run: the same tool call returned the same result and made no progress. Raising `--max-turns` would change nothing. |
| `4` | The `--max-cost-per-run` ceiling was reached after a priced turn; no further model turn was started. |

`2`, `3`, and `4` are deliberately distinct: a script that retries with a bigger turn budget on `2`
must not retry on `3`, and a caller can handle a spend ceiling on `4` without misclassifying it as a
stuck model. In text mode an unbounded run prints `… still working — turn N` to **stderr** every
twenty-five turns, so a long run in a CI log is not mistaken for a hung one; stdout still carries only
the answer, and the `--json` event stream is unchanged.

### LiteLLM compatibility notes

These are non-obvious and the client is built to handle them:

- Response headers such as `x-litellm-call-id`, `x-litellm-model-id`, and
  `x-litellm-attempted-fallbacks` arrive on the **initial** response, not at stream close. When a
  fallback fired, the model that answered is not the one requested, and the UI must say so rather
  than lie.
- `message.content` is nullable on tool-call turns, and the error `code` field is a string.
- `/v1/models` may be non-exhaustive when wildcard model configs are in play, so a free-typed model
  id is always allowed.
- `[DONE]` is not part of the SSE specification, and mid-stream failures arrive as
  `data: {"error": ...}` under an already-committed HTTP 200.
- Reasoning and thinking fields are treated as best-effort decoration; no UI state depends on
  receiving them.

## Building

Requires a Swift 6.2 or newer toolchain (developed on 6.3.3). Targets macOS 15+ and Linux.

```bash
swift build            # build
swift test             # run tests
swift run domo         # run from source
```

There are five ways to run it, and the default changed with Phase 7.

| Invocation | What it does |
|---|---|
| `domo` | The **full-screen** alternate-screen client. It spawns a loopback `DoMoServer` on an ephemeral port with a generated token, attaches over SSE, and tears it down on exit. This is the default. |
| `domo --inline` | The classic **inline** REPL, painting into normal scrollback, in-process. Mid-run steering queues here and in the default client. |
| `domo --mini` | The split-footer REPL: the same live prompt and agent loop, with transcript in normal scrollback and a measured footer pinned below it. |
| `domo -p "…"` | Headless: prompt in, answer on stdout, exit code as the verdict. Add `--json` for a newline-delimited event stream. The only mode that pipes. |
| `domo --serve` | The headless runtime behind a loopback-only HTTP/SSE server (default port 4100). Attach with `domo --url http://127.0.0.1:4100 --token …`. |

Note that the server is a flag, not a subcommand — `domo --serve`, not `domo serve`.

## Non-goals and known gaps

Stated plainly, because a port that implies parity will disappoint. Two rounds of expansion have
emptied most of this section: the first moved a local server, a full-screen TUI, MCP and inline images
into the roadmap and all four shipped; the turn toward a fully-featured harness moved sandboxing, a
diff review pane, a PTY and much else. What is below is what genuinely remains out — and every one of
them is the owner's call rather than a settled fact, which is why each appears with its in-scope
substitute in [Decisions that reverse a stated non-goal](#decisions-that-reverse-a-stated-non-goal).

**Out of scope, deliberately:**

- **The TypeScript extension system.** This is pi's signature feature, and there is no Swift
  equivalent that preserves what makes it work — in-process input mutation, live custom components,
  hot reload. DoMoCode ships a fixed tool set and a fixed hook surface. If extensibility ever
  returns it will be out-of-process, and that is a research item rather than a promise. (MCP is the
  one sanctioned extension seam, and only stdio-local — see the roadmap.)
- **Multi-provider support.** One wire API, one gateway. Routing across Bedrock, Vertex, Anthropic,
  and the rest is LiteLLM's job — that is the entire premise. This one did not move.
- **OAuth login flows.** Bearer key only, for the LLM gateway. This has been read too broadly: remote
  MCP was treated as inheriting the whole non-goal, but a remote server reached with a *static bearer
  header* needs no OAuth at all and is buildable today. The OAuth half — PKCE, dynamic client
  registration, a loopback callback — is what actually stays out, and it is the reversal most worth
  considering.
- **A supervising daemon.** The Phase-6 server is one local, loopback-only, single-client-first
  endpoint — *not* the `pi-server` daemon's multi-instance supervision, Unix-socket fan-out, mDNS
  discovery, or cloud presence, all of which stay out.
- **A package manager** for distributing extensions, skills and themes. Reading `.claude/skills` and
  `.agents/skills` in place (Phase 5b) gives compatibility with what people already write, without
  becoming a distribution mechanism.
- **Windows.** macOS and Linux only. Not blocked architecturally, just unbuilt and untested.

**Still deferred, but no longer vague:** SQLite session storage stays behind the `SessionStorage`
protocol until JSONL actually hurts; hosted session *sharing* stays out while local Markdown and HTML
export become Phase 20; vim-mode editing, a file watcher, sixel, one-click whole-server MCP grants,
and multi-client session mirroring are all unscheduled — the last of these is not blocked, since the
SSE hub already takes N subscribers and REST is stateless, but the mirroring semantics that would make
a second attached client safe do not exist. Everything else the
[sibling-harness survey](#sibling-harnesses-and-prior-art) turned up — checkpoints, personas,
subagents, memory, LSP — now has a phase number rather than a bucket.

**Explicitly not planned,** so they are not rediscovered as gaps: codebase indexing and semantic search
(LanceDB, Qdrant and tree-sitter each fail SPM-only or the strict-memory-safety posture; the
transferable asset is the disciplined tool description that routes the model between the search tools
it already has, which is free); a JS interpreter or "code mode" (JavaScriptCore is Apple-only, and the
in-scope answer to tool-catalog bloat is the per-turn tool subset Phase 11 enables anyway);
first-party browser control (route it through a stdio MCP server — `playwright-mcp` works today with
zero new code, and `McpTool.mapResult` already lifts image blocks onto the attachment channel, so
DoMoCode can *display* the screenshots); notebook kernel execution; a multi-forge provider
abstraction; a Slack bridge; org-managed agents and marketplaces; live share links; and a crash screen
for Swift *traps* — traps do not unwind, and the allocation-free signal-time restore that already
ships is the correct and complete answer for that path.

**Fidelity gaps that will not be closed:**

- **Word segmentation.** pi uses ICU word rules via `Intl.Segmenter`; Swift has no stdlib
  equivalent, so word-motion behavior will differ at some punctuation boundaries.
- **Emoji width.** pi relies on V8's RGI emoji regex support, which Swift's regex engines lack.
  Width is re-derived from Unicode scalar properties, and exotic sequences may measure differently.
  Worth revisiting when the deployment floor reaches macOS 26 — `UTF8Span`'s allocation-free
  grapheme-cluster iteration is the right primitive for terminal cell measurement.
- **Markdown streaming.** pi mutates its Markdown tokens in place to avoid flicker on partial code
  fences; swift-markdown's AST is immutable, so the anti-flicker behavior is re-derived at the text
  level and will not match exactly.
- **Cost accounting** depends on prompt-cache plumbing whose support varies per upstream provider
  behind the gateway. Reported cost is an estimate.

**Costs the expansion accepted.** The four reversals were not free, and the honest list is short and
real — each of these is now a property of the shipped system, not a forecast:

- **Full-screen mode abandons shell-scrollback composition.** The inline renderer's whole point is that
  it paints into normal scrollback and composes with your shell history; the alternate-screen mode owns
  the screen, leaves no transcript behind, and cannot be piped. Inline mode is kept as a first-class
  second mode precisely so that property is not lost outright — but the full-screen mode is now the
  default, so that is what most runs get.
- **Two render modes, and an oracle that had to be built.** The inline diff was verified against pi's
  oracle; the fixed-height cell-buffer diff is new code with *no* upstream oracle, so its correctness
  rests on a test harness written here, and the two modes doubled the renderer's test surface.
- **A local server is a new attack surface.** A socket on loopback is reachable by any local process;
  the mitigation is a loopback-only bind plus a per-session token by default, but the single-process
  design never had this exposure.
- **A weakened backpressure invariant, with bounded steering queues.** The awaited event-emit guarantee
  is relaxed for the network fan-out sink (bounded buffer, drop-oldest), as
  [Concurrency](#concurrency-and-isolation) records; a client that falls behind re-seeds from the
  transcript rather than replaying the gap. Mid-run steering is supported over the wire now, but the
  queue is deliberately in-memory and per live session: a process restart leaves no accepted-but-
  undelivered prompt behind, and a queued message can still be lost if the host is terminated before
  its next turn is persisted. The client reconciles the level-triggered count through `/status`.
- **MCP widens the prompt-injection surface.** MCP tool descriptions and tool output are
  attacker-controlled text entering the context. That is why the permission engine landed first, why a
  standing caveat in the system prompt marks tool text as data rather than instructions, and why
  remote servers wait.
- **Image display has weaker coverage.** Kitty images do not reflow and cannot be asserted on the
  TTY-less CI oracle, so display correctness leans on manual verification more than the rest of the
  renderer does.
- **An error rebuilt from history loses its label.** The JSONL records a failure's prose and stop
  reason but not its `DoMoError.Kind`, so a session reopened later shows the detail under a generic
  headline. The live stream carries the real classification; persisting it is the fix.

## Contributing

All shipped phases through Phase 21 are implemented.
**Phase 21 — Split-footer render mode — is complete**, including the normal-scrollback mini surface.
The [dependency spine](#the-dependency-spine) remains useful historical context for how the work was
sequenced. Issues proposing scope changes — particularly anything in
[Non-goals](#non-goals-and-known-gaps) or the
[reversal table](#decisions-that-reverse-a-stated-non-goal) — are welcome before code lands rather
than after.

## License

DoMoCode is released under the [MIT License](LICENSE), Copyright (c) 2026 Sam Stegall.

DoMoCode is a port of the [Pi Agent Harness](https://github.com/earendil-works/pi), Copyright (c)
2025 Mario Zechner, also under the MIT License. The upstream license text is reproduced in full in
[NOTICES.md](NOTICES.md), together with attribution for third-party dependencies.

"Pi", "Pi Agent Harness", and related names and marks are the property of their respective owners
and are used here for identification purposes only.
