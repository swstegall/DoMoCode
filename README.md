# DoMoCode

A terminal UI coding-agent harness for Swift, built with Swift Package Manager, that talks to many
different models through a single [LiteLLM](https://github.com/BerriAI/litellm) gateway.

DoMoCode is a Swift port of the [Pi Agent Harness](https://github.com/earendil-works/pi) by Mario
Zechner, derived from `v0.81.1` (commit
[`9b3a2059`](https://github.com/earendil-works/pi/commit/9b3a2059171bcc74ad9d2cadeea6d186776cf2db),
2026-07-22) and used under the MIT License. DoMoCode is an independent project and is not affiliated
with or endorsed by the Pi Agent Harness project. See [NOTICES.md](NOTICES.md) for full attribution.

---

## Status: every roadmap phase except Phase 5 has shipped

**The runtime, both terminal UIs, the HTTP/SSE server, inline images in and out, the permission engine
and the MCP client are implemented and tested** — Phases 0–4, 5.5, 6, 7, 7.5, 8 and the 8.5 hardening
pass — with **2,017 tests in 237 suites green in both debug and `-c release`**.
`domo` with no arguments is a full-screen client attached to a loopback server it spawns itself;
`--inline` is the classic scrollback REPL; `-p` is headless.

**Phase 5 — the polish pass — is the one roadmap phase that has not landed** (the unscheduled *Later*
bucket is also unbuilt, by design), and it is the largest remaining gap between this and a harness you
would reach for daily. The default full-screen client has no slash commands at all and `--inline`
recognises only `/exit`, `/quit` and `/clear`; skills, prompt templates, `AGENTS.md` loading, themes,
external-editor editing, session-tree navigation and in-session model switching do not exist. Read the
[roadmap](#roadmap) for the boundary between what runs today and what is still unbuilt.

DoMoCode began as a deliberately **narrowed** port; the
[scope expansion](#what-expanded-and-what-did-not) widened it in four directions while keeping the core
constraints intact, and all four have since landed. See
[Non-goals](#non-goals-and-known-gaps) for what is still left out on purpose.

## Why this exists

Upstream pi is a Node/Bun monorepo that normalizes ~38 model providers across ~10 different wire
APIs. That breadth is the right design for pi. It is the wrong design here.

DoMoCode inverts it. There is **one wire API** (OpenAI Chat Completions) pointed at **one host** (a
LiteLLM proxy), because LiteLLM already does the multi-provider normalization — that is its entire
premise. Everything the provider-abstraction layer would have cost gets spent on the agent loop and
the renderer instead.

Three constraints shape the whole project:

1. **Swift 6.2**, `swift-tools-version: 6.2`, `swiftLanguageModes: [.v6]` — strict concurrency on
   from day one. 6.2 is a floor, not a ceiling; development happens on the current release (6.3.3 at
   time of writing) and nothing here depends on 6.3-only features.
2. **Swift Package Manager only.** No CocoaPods, no Carthage, no vendored binary frameworks. Every
   dependency resolves from a public GitHub repository.
3. **One provider surface: LiteLLM.** Model breadth is the gateway's job, not the client's.

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
                    hooks. (Skills and prompt templates land here in Phase 5; they do not exist yet.)
  DoMoExec/         FileSystem + Shell over swift-subprocess; gitignore walker; path sandboxing;
                    per-path file mutation coordinator; image-attachment loading.
  DoMoTools/        The built-in tools (read/write/edit/bash/grep/find/ls), headless by design.
  DoMoPermissions/  The granular allow/ask/deny engine: glob matching, last-match-wins evaluation,
                    the bash arity table, the .env guard, the config self-edit guard, an actor that
                    remembers and persists grants, and the beforeToolCall hook that gates the loop.
  DoMoMCP/          MCP client: an MCPManager actor owning stdio server subprocesses, a JSON-RPC 2.0
                    protocol actor, and an McpTool: AgentTool adapter. Hand-rolled, no SDK.

  # The server — hosts the runtime behind a local socket
  DoMoServer/       Hummingbird HTTP+SSE. Write path drives the AgentHarness actor; read path is an
                    SSE broadcast hub. Loopback-only bind, per-session token. Also owns the wire
                    DTOs (ServerEvent, ServerNotice) that the client decodes.

  # The terminal client
  DoMoTermIO/       The POSIX seam. The only module that imports Darwin/Glibc: termios raw mode,
                    TIOCGWINSZ, SIGWINCH, the stdin byte pump, panic-safe restore, alternate-screen
                    enter/exit, mouse reporting, and the cell-pixel-size probe.
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
| `@earendil-works/pi-coding-agent` (rest) | `DoMoCLI` | Session orchestration, settings, trust, output modes. Slash commands are a Phase-5 item and are still a three-name stub. |
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
the gap. Second, **mid-run steering did not survive the split.** In-process, the `Mutex`-guarded steering
box lets a second prompt join a running turn; the server-hosted harness disables steering outright and
answers a prompt sent during a run with HTTP 409, which the client surfaces as a notice and restores into
the input box. Steering therefore works under `--inline` and not under the default client. Both are real
losses of a documented property; see [Non-goals](#non-goals-and-known-gaps).

Deliberately *not* adopted: `Span`, `RawSpan`, `UTF8Span`, and `InlineArray`. They are the right shape
for the escape decoder and for grapheme-cluster width measurement, but every standard-library API that
*produces* one is `@available(macOS 26)` — the types back-deploy, the accessors do not — and on Linux
they are unconditional, so using them means `#if` divergence in the most correctness-critical code in
the project. The decoder is built on `[UInt8]` with an explicit index, but its internal view type is
deliberately `Span`-shaped (borrowed base plus count, explicit slicing, no ownership) so the storage
swap is mechanical when the floor eventually reaches macOS 26.

## Roadmap

Ordered strictly by dependency. Each phase ends with something runnable and tested.

- [x] **Phase 0 — Skeleton.** `Package.swift` with the pin table, all eleven targets declared, the
      per-target isolation and safety settings from
      [Concurrency](#concurrency-and-isolation), CI on macOS and Ubuntu at Swift 6.2 building in both
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
      moved the no-flag default to the full-screen client, which has no `@` completion of its own.)
- [ ] **Phase 5 — Polish. The one unstarted phase, and the largest remaining gap.** Slash commands,
      `!` shell commands, skills, prompt templates, `AGENTS.md` loading, themes, external editor,
      session tree navigation, model cycling. Refinements taken from the
      [sibling harnesses](#sibling-harnesses-and-prior-art): `$ARGUMENTS`/`$N` and inline
      `` !`shell` `` substitution in command and prompt templates, with per-command model and agent
      overrides; keyword-triggered skill auto-injection and task-input `{VAR}` templates; opencode's
      ANSI-index / `none`-means-inherit theme model with dark/light variants (exactly right for an
      inline renderer painting over an arbitrary background); a local `/review` of a diff, branch, or
      commit; and an inline fuzzy command menu with an on-demand cheat-sheet printed into scrollback —
      the flat, remappable subset of a command palette that needs no overlay panel.

      It was originally sequenced *before* the architecture pivot and was overtaken by it, so what
      exists today is substrate rather than feature. `SlashCommand` + `SlashCommandProvider` and a
      fuzzy-ranked completion popup are built and tested, but dispatch is a hard-coded three-name
      `switch` (`/exit`, `/quit`, `/clear`) in the `--inline` REPL, and the default full-screen client
      has no slash commands at all. `ToolRenderTheme` / `SelectListTheme` / `EditorTheme` are real
      styling seams with hardcoded presets that nothing can select. The session **tree** exists in the
      harness and over REST (`GET /session/:id/children`, `POST /session/:id/fork`, both wrapped
      client-side), but the sidebar draws a flat list and never calls either. Model cycling has its
      persistence substrate only — a `model_change` session entry that round-trips through the context
      builder, compactor and branch summarizer, and that nothing in production ever writes. Skills,
      prompt templates, `AGENTS.md` loading and `$EDITOR` integration have no code at all: the system
      prompt is a single literal string, and `Yams` is declared for skill frontmatter that was never
      written, so it is currently an unused dependency.
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
      safe are *Later* work; `-p` stays in-process. 1,116 tests green in debug and release. The REST surface has since grown
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
- [ ] **Later (unscheduled).** Multi-client attach / session mirroring — the SSE hub is already an
      unguarded N-subscriber broadcast and REST is stateless, so a second client *can* attach today;
      what is missing is the mirroring semantics that would make it safe, which is why it stays here.
      Remote MCP + OAuth (PKCE + dynamic client registration + loopback callback); a per-turn MCP tool
      snapshot and `tools/list_changed` re-advertising (deferred out of Phase 8d — it needs a mutable
      tool set in the agent loop); one-click whole-server MCP grants; SQLite/GRDB storage behind the
      existing `SessionStorage` protocol; the remaining
      [sibling-harness candidates](#sibling-harnesses-and-prior-art) (git-shadow checkpoints, agent
      personas, per-task budget cap, first-party tool additions, …); and sixel.

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

What the survey did surface is a compact set of terminal-native, single-provider, dependency-light
features that fit inside every constraint. They are folded into the roadmap above — a few into Phase 5,
the granular permission engine into Phase 8 (MCP's safety prerequisite), and the rest into the
unscheduled *Later* bucket. Two rows have since shipped. "Fit" is judged against the
[non-goals](#non-goals-and-known-gaps): a new *first-party* tool is `adaptable`, not free, because the
extensibility non-goal forbids plugin-defined tools, not new Swift ones — each addition still forces a
tool-vs-prompt-injection and in-process-vs-out-of-process decision.

| Feature | Seen in | Fit | Lands in |
|---|---|---|---|
| Granular permission engine (allow/ask/deny globs, last-match-wins, inline once/always/reject) | all three | yes | **Shipped** (Phase 8) |
| Headless run (prompt in, streamed/JSON out, exit codes, auto-approve) | kilocode, opencode | yes | **Shipped**, as flags rather than a subcommand: `-p` / `--json` / `--yolo`, exit codes 0–3 |
| Git-shadow snapshot checkpoints + undo/redo + fork-from-any-message | kilocode, opencode | yes | Later |
| Config-driven agent/persona profiles + a read-only plan mode | all three | yes | Later |
| Auto-format-after-edit hook; repo `.setup.sh` session-init hook | all three | yes | Later |
| Hard per-task budget cap (abort the loop on a cost ceiling) | OpenHands | yes | Later |
| Trusted-config `{env:}`/`{file:}` interpolation gated by the trust boundary | kilocode | yes | Later |
| Local `/review` of a diff, branch, or commit | kilocode, OpenHands | yes | Phase 5 |
| Skill refinements: keyword auto-injection, task-input `{VAR}` templates | all three | yes | Phase 5 |
| Slash-command polish: `$ARGUMENTS`/`$N`, inline `` !`shell` ``, per-command overrides, ANSI-index / `none`=inherit theming | opencode, kilocode | yes | Phase 5 |
| First-party tool additions: `question`/`suggest`, todo checklist, `webfetch` (+ gated `apply_patch`, `websearch`, notebook-edit, `recall`) | all three | adaptable | Later |
| Selectable/tunable history condensers (observation-masking, recent-window, LLM-summarizing) | OpenHands | adaptable | Later |
| Local conveniences: prompt stash, `/btw` side-branch, background jobs, file watcher, deterministic JSONL replay, local secrets + env injection, out-of-process notify/sound | opencode, kilocode, OpenHands | yes/adaptable | Later (persistent per-workspace prompt *history* shipped in Phase 8.5; a stash did not) |
| Out-of-process research items: ACP single-session stdio subcommand (atop the Phase-6 server), LSP post-edit diagnostics, Seatbelt/bubblewrap bash sandbox, local semantic index via the gateway's `/embeddings` | all three | adaptable | Later / research |

The semantic-index row is the sharpest example of "adapt, don't adopt": the idea ports only if
embeddings come from the single LiteLLM gateway's OpenAI-compatible `/embeddings` into an
SPM-resolvable local store — an external Qdrant or a second embedding provider would breach both the
single-provider and the SPM-only / no-vendored-binaries constraints.

### Features declined

The [scope expansion](#what-expanded-and-what-did-not) moved four items — the server, the full-screen
TUI, MCP, and inline images — out of this list, and all four have since shipped. Most of the rest still
recurs across all three and stays out, each against a named constraint:

- **Multi-provider model layers and wire-protocol adapters** — DoMoCode has one surface (LiteLLM);
  model breadth is the gateway's job, so the client-side abstraction is both disallowed and
  redundant. This one did *not* move.
- **OAuth / device login, JS/TS plugin systems, in-process JS interpreters (kilocode's "CodeMode"),
  and extension/skill/theme marketplaces** — the declared extensibility, bearer-key-only, and
  package-manager non-goals; several also need vendored binaries (SPM-only). MCP is no longer in this
  bullet — it shipped in Phase 8 — but only *stdio-local* MCP, because *remote* MCP servers require
  full OAuth, so that half stays deferred here.
- **Detached daemons, multi-instance supervision, mDNS, multi-device sync, and multi-backend
  (Docker/K8s/remote) sandboxes** — still out. DoMoCode's own server (Phase 6) is deliberately the
  opposite, narrow slice: one local loopback endpoint, single-client-first, no supervision and no
  discovery. Only the *local* Seatbelt/bwrap wrap of the bash tool is a later candidate.
- **Web / GUI / IDE / desktop UI** — embedded VSCode/browser panes, a hosted web console, an Electron
  app, editor extensions, and an *interactive full-screen diff pane*. DoMoCode did build a full-screen
  *terminal* TUI (Phase 7, in-house), but it stays a terminal app on the inline renderer's own
  primitives; the OpenTUI/SolidJS/React foundations and every non-terminal surface stay out.
- **Cloud agents, webhooks, cron automations, git-provider issue-resolvers, and inline
  FIM/speech-to-text** — daemon + OAuth + non-terminal-input constraints. Only the local headless
  path is in scope — `domo -p`, invoked from an external job the user owns.

## Dependencies

Every direct dependency must resolve on Swift 6.2. Several pins below were previously version caps
imposed by the 6.1 floor rather than stability judgments; those caps are gone and the table records
the versions that replaced them.

The deployment floor is **macOS 15**, raised from 13. `Synchronization.Mutex` and `Atomic` are gated
`@available(macOS 15)` on Apple platforms — they are unconditional on Linux — and they are how shared
mutable state is handled here, per [Concurrency](#concurrency-and-isolation). macOS 15 shipped in
September 2024; requiring it for a developer CLI is not aggressive.

These thirteen resolve as a set on a 6.2 manifest, and to a graph of **34 pinned packages** once
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
| [jpsim/Yams](https://github.com/jpsim/Yams) | MIT | YAML frontmatter in skills and prompt templates. `from: "6.2.2"` — that is Yams' own semver and has nothing to do with the Swift version. **Currently unused**: it is declared for Phase 5, which has not started, and no source file imports it. |
| [ajevans99/swift-json-schema](https://github.com/ajevans99/swift-json-schema) | MIT | Tool-schema generation *and* draft-2020-12 validation of returned arguments — validation is the half that protects you. `.upToNextMinor(from: "0.13.1")`, pre-1.0. |
| [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0 WITH Swift-exception | cmark-gfm AST for the Markdown component. `.upToNextMinor(from: "0.8.0")` — the 6.1 floor capped this at 0.7.1. The repository moved from `apple/`, which now redirects; pin the semver tag, never a `swift-6.x.y-RELEASE` tag. |
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | **Not declared.** Held for Later (SQLite session storage) at `from: "7.11.1"`, validated against this graph and recorded as a comment in `Package.swift`. JSONL is still the only `SessionStorage` implementation. |
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
  and no theming to want it until Phase 5.
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
| `DOMOCODE_SMALL_MODEL` | falls back to `DOMOCODE_MODEL` | Used for compaction and branch summaries. |
| `DOMOCODE_REASONING_EFFORT` | unset | `minimal` / `low` / `medium` / `high`. |
| `DOMOCODE_TIMEOUT_MS` | `600000` | Overall request timeout. `0` means the default — a literal zero would fail every request before the gateway could answer, and there is no "no deadline" to express here. |
| `DOMOCODE_STREAM_TIMEOUT_MS` | `120000` | How long a committed response may deliver **nothing** before the turn is failed. A 2xx has already committed the stream, so exceeding this fails the turn rather than retrying it — tighten it and you trade a hung turn for a lost one, since a model can legitimately go quiet through a long reasoning block. `0` removes DoMoCode's silence bound. Time-to-response-head is separately bounded by a fixed 10 s connect timeout. **This knob previously did nothing**; setting it now has an effect — but see the note below on its 90 s ceiling. |
| `DOMOCODE_MAX_RETRIES` | `10` | Client-side retry count for a *retryable* failure. `0` disables retrying. |
| `DOMOCODE_RETRY_BASE_MS` | `1000` | First backoff; each further attempt doubles it before jitter. |
| `DOMOCODE_RETRY_MAX_MS` | `60000` | Backoff ceiling, which also caps a server-supplied `Retry-After`. |
| `DOMOCODE_RETRY_BUDGET_MS` | `300000` | Total time one request may spend asleep between attempts. `0` means no budget. |
| `DOMOCODE_CONFIG_DIR` | `~/.domocode` | Settings and the trust store. (Skills and themes land here in Phase 5.) |
| `DOMOCODE_SESSION_DIR` | `$CONFIG_DIR/sessions` | Session JSONL root, and the per-workspace prompt history beside it. Point this elsewhere and both move. |
| `DOMOCODE_LOG_LEVEL` | `warning` | Logs go to stderr; stdout is reserved for the JSON protocol channel. |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | — | **Not honored.** Nothing reads them, and the default transport is `HTTPClient.shared`, which cannot be given a proxy configuration. Behind a proxy, point `DOMOCODE_BASE_URL` at it directly. |

Secrets are never written to `settings.json` — `Settings` has no API-key field at all. `apiKeyEnv`
holds only the *name* of the environment variable to read, so the key value never touches disk.

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

`2` and `3` are deliberately distinct: a script that retries with a bigger budget on `2` must not
retry on `3`. In text mode an unbounded run prints `… still working — turn N` to **stderr** every
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

There are four ways to run it, and the default changed with Phase 7.

| Invocation | What it does |
|---|---|
| `domo` | The **full-screen** alternate-screen client. It spawns a loopback `DoMoServer` on an ephemeral port with a generated token, attaches over SSE, and tears it down on exit. This is the default. |
| `domo --inline` | The classic **inline** REPL, painting into normal scrollback, in-process. Mid-run steering works here and not in the client. |
| `domo -p "…"` | Headless: prompt in, answer on stdout, exit code as the verdict. Add `--json` for a newline-delimited event stream. The only mode that pipes. |
| `domo --serve` | The headless runtime behind a loopback-only HTTP/SSE server (default port 4100). Attach with `domo --url http://127.0.0.1:4100 --token …`. |

Note that the server is a flag, not a subcommand — `domo --serve`, not `domo serve`.

## Non-goals and known gaps

Stated plainly, because a port that implies parity will disappoint. The
[scope expansion](#what-expanded-and-what-did-not) moved four former non-goals — a local server, a
full-screen TUI, MCP, and inline images — into the roadmap; the boundaries below are what remains out,
each against the constraint that keeps it there.

**Out of scope, deliberately:**

- **The TypeScript extension system.** This is pi's signature feature, and there is no Swift
  equivalent that preserves what makes it work — in-process input mutation, live custom components,
  hot reload. DoMoCode ships a fixed tool set and a fixed hook surface. If extensibility ever
  returns it will be out-of-process, and that is a research item rather than a promise. (MCP is the
  one sanctioned extension seam, and only stdio-local — see the roadmap.)
- **Multi-provider support.** One wire API, one gateway. Routing across Bedrock, Vertex, Anthropic,
  and the rest is LiteLLM's job — that is the entire premise. This one did not move.
- **OAuth login flows.** Bearer key only, for the LLM gateway. The one crack: *remote* MCP servers (a
  later, separately-scoped goal) require OAuth, so remote MCP inherits this non-goal until that is
  resolved; the stdio-local MCP shipping first (Phase 8) needs none.
- **A supervising daemon.** The Phase-6 server is one local, loopback-only, single-client-first
  endpoint — *not* the `pi-server` daemon's multi-instance supervision, Unix-socket fan-out, mDNS
  discovery, or cloud presence, all of which stay out.
- **The pi package manager** for distributing extensions, skills, and themes.
- **Windows.** macOS and Linux only. Not blocked architecturally, just unbuilt and untested.

**Deferred:** SQLite session storage (Later); session sharing and HTML export — though the local
JSON/JSONL/zip transcript-export half is cheap, dependency-free, and separable from the deferred
hosted-share infrastructure — and vim-mode editing. The batch of features surfaced by the
[sibling harnesses](#sibling-harnesses-and-prior-art) — snapshot checkpoints, agent personas, and more
(Later) — is tracked there. Five items left this list by shipping: the permission engine and MCP
(Phase 8), the local server (Phase 6), inline images in both directions (Phases 5.5 and 7.5), and the
headless path (`-p`, since Phase 1).

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
- **A weakened backpressure invariant, and no steering over the wire.** The awaited event-emit
  guarantee is relaxed for the network fan-out sink (bounded buffer, drop-oldest), as
  [Concurrency](#concurrency-and-isolation) records; a client that falls behind re-seeds from the
  transcript rather than replaying the gap. Mid-run steering did not survive the split at all — it
  works under `--inline`, while the client's second prompt during a run is refused with a 409 and
  returned to the input box.
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

Every [roadmap](#roadmap) phase except **Phase 5 — Polish** is implemented; Phase 5 is the current
work. Issues proposing scope changes — particularly anything in
[Non-goals](#non-goals-and-known-gaps) — are welcome before code lands rather than after.

## License

DoMoCode is released under the [MIT License](LICENSE), Copyright (c) 2026 Sam Stegall.

DoMoCode is a port of the [Pi Agent Harness](https://github.com/earendil-works/pi), Copyright (c)
2025 Mario Zechner, also under the MIT License. The upstream license text is reproduced in full in
[NOTICES.md](NOTICES.md), together with attribution for third-party dependencies.

"Pi", "Pi Agent Harness", and related names and marks are the property of their respective owners
and are used here for identification purposes only.
