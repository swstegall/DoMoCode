# DoMoCode

A terminal UI coding-agent harness for Swift, built with Swift Package Manager, that talks to many
different models through a single [LiteLLM](https://github.com/BerriAI/litellm) gateway.

DoMoCode is a Swift port of the [Pi Agent Harness](https://github.com/earendil-works/pi) by Mario
Zechner, derived from `v0.81.1` (commit
[`9b3a2059`](https://github.com/earendil-works/pi/commit/9b3a2059171bcc74ad9d2cadeea6d186776cf2db),
2026-07-22) and used under the MIT License. DoMoCode is an independent project and is not affiliated
with or endorsed by the Pi Agent Harness project. See [NOTICES.md](NOTICES.md) for full attribution.

---

## Status: Phases 0–4 and 5.5 shipped; rest of the expansion planned

**The runtime, the inline terminal UI, and image input are implemented and tested** — Phases 0–4 plus
5.5, with 1,097 tests green in both debug and `-c release`. Everything else tagged **Phase 5 and
beyond** — the rest of the polish pass, the HTTP/SSE server, the full-screen TUI, MCP, and image
*display* — is a statement of intent and a plan of record, tagged with the phase that will deliver it
and described in the future tense until it lands. Read the [roadmap](#roadmap) for the boundary between
what runs today and what is planned.

DoMoCode began as a deliberately **narrowed** port; the
[scope expansion](#what-expanded-and-what-did-not) has since widened it in four directions while keeping
the core constraints intact. See [Non-goals](#non-goals-and-known-gaps) for what is still left out on
purpose.

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
the scope has been widened on purpose, in four directions its founding thesis ruled out, and this README
no longer pretends otherwise. DoMoCode is growing:

1. **A full-screen, alternate-screen TUI** — a widget-toolkit UI in the manner of Claude Code, opencode,
   or kilocode — added *alongside* the inline renderer, not replacing it.
2. **A client/server split** — the agent runtime moves behind a local HTTP + Server-Sent-Events server,
   and the terminal becomes a client that attaches to it.
3. **MCP** — a Model Context Protocol client, stdio-local first, so external tool servers can extend the
   agent.
4. **Inline images** — terminal graphics (Kitty/iTerm2) for display, plus image *input* to
   vision-capable models through the gateway.

What did **not** expand is the load-bearing part. The constants are the three constraints above — one
LiteLLM gateway (still no client-side multi-provider layer), Swift Package Manager only, and strict
Swift 6.2 concurrency — plus macOS-and-Linux and a single-user, local posture. The honest reading is
that "a port that implies parity will disappoint" now cuts both ways: DoMoCode is taking on a real slice
of the sibling-scale surface it once bounded out, and each reversal carries a named cost
([Non-goals](#non-goals-and-known-gaps)) rather than arriving free. All four are future work, sequenced
in the [roadmap](#roadmap); the runtime they build on (Phases 0–4) already exists.

## Architecture

Package name `DoMoCode`; executable target and installed command `domo`.

The Phases 0–4 design is a single process: a headless runtime with every I/O concern injected, bound to
an inline terminal client on the main actor. The expansion splits that seam onto a local socket. Three
layers result — a **runtime** (unchanged, because it was already event-sink-driven and owned by a
persistence actor), a **server** that hosts it behind HTTP+SSE, and a **client** that attaches over the
wire. The split is CQRS-shaped: the write path (`POST /session/:id/prompt`) drives the `AgentHarness`
actor that already owns the session tree; the read path (`GET /event`) is an SSE broadcast hub fed by the
same `AgentEventSink` the runtime already emits to. Modules tagged *(planned)* below are the expansion;
the rest ship today.

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
                    skills and prompt templates, hooks.
  DoMoExec/         FileSystem + Shell over swift-subprocess; gitignore walker; path sandboxing;
                    per-path file mutation coordinator.
  DoMoTools/        The built-in tools (read/write/edit/bash/grep/find/ls), headless by design.
  DoMoMCP/          (planned) MCP client: an McpManager actor owning stdio server connections plus
                    an McpTool adapter — the seam that makes the fixed tool set dynamic. Peer of DoMoLLM.

  # The server — hosts the runtime behind a local socket
  DoMoServer/       (planned) Hummingbird HTTP+SSE. Write path drives the AgentHarness actor; read
                    path is an SSE broadcast hub. Loopback-only bind, per-session token.

  # The terminal client
  DoMoTermIO/       The POSIX seam. The only module that imports Darwin/Glibc: termios raw mode,
                    TIOCGWINSZ, SIGWINCH, the stdin byte pump, panic-safe restore.
                    (planned) alternate-screen enter/exit; image-capability probe.
  DoMoTUI/          Inline (non-alternate-screen) differential renderer, Component protocol,
                    overlays, multi-line Editor, keybindings, ANSI/display-width text engine.
  DoMoTUIKit/       (planned) the full-screen (alternate-screen) layer: a box/flexbox-lite layout
                    engine and a fixed-height cell-buffer compositor reusing DoMoTUI's frame
                    differ; panes, splits, footer/sidebar, focus traversal.
  DoMoTermGraphics/ (planned) UI-agnostic Kitty/iTerm2 image encoders and header-only dimension
                    parsers, shared by both render modes.
  DoMoToolsUI/      Renderers for the built-in tools, reattached at composition time.
  DoMoCLI/          Modes (interactive/print/json), the SSE client that attaches to DoMoServer, and
                    `domo serve`; settings, project trust, resource loading, slash commands, wiring.
  domo/             The executable. ArgumentParser root plus DoMoCLI.run().
```

### How this maps to upstream pi

| pi package | DoMoCode module(s) | Notes |
|---|---|---|
| `@earendil-works/pi-tui` | `DoMoTermIO` + `DoMoTUI` (+ `DoMoTUIKit`, `DoMoTermGraphics`) | Split in two. TermIO owns terminal state (`terminal.ts`, `stdin-buffer.ts`); TUI owns the diff renderer, components, and the width/ANSI engine (`tui.ts`, `keys.ts`, `keybindings.ts`, `utils.ts`, `fuzzy.ts`, `autocomplete.ts`, `kill-ring.ts`, `undo-stack.ts`, `word-navigation.ts`, `components/`). The Windows shims are dropped. Unlike pi, which never takes the alternate screen, DoMoCode *adds* a full-screen alt-screen mode (`DoMoTUIKit`) beside the inline renderer; inline images (`terminal-image.ts`) are now a goal (`DoMoTermGraphics`), not dropped. |
| `@earendil-works/pi-ai` | `DoMoLLM` | Radically narrowed. Keeps the *shapes* — `Context`, `AssistantMessage`, `Usage`, `StopReason` — plus the streaming tool-call assembler, retry/overflow classifiers, and cost math. Drops 37 providers, 9 wire APIs, OAuth, and the generated model catalog. |
| `@earendil-works/pi-agent-core` (`agent-loop.ts`, `types.ts`) | `DoMoAgent` | Ported structurally: turn loop, stop conditions, three-phase tool dispatch, parallel-vs-sequential execution, truncated-tool-call refusal, steering queues. |
| `@earendil-works/pi-agent-core` (`harness/`) | `DoMoHarness` | Session tree, storage, `buildContext`, compaction, branch summarization, hooks. |
| `@earendil-works/pi-agent-core` (`env/nodejs.ts`) | `DoMoExec` | Protocol-based FileSystem and Shell with a single POSIX implementation. |
| `@earendil-works/pi-coding-agent` (`core/tools/`) | `DoMoTools` + `DoMoToolsUI` | The built-in tools, split headless/rendered. |
| `@earendil-works/pi-coding-agent` (rest) | `DoMoCLI` | Session orchestration, settings, trust, slash commands, output modes. |
| `@earendil-works/pi-storage-sqlite-node` | `DoMoHarness` protocol; SQLite backend deferred | JSONL is the shipping default; the `SessionStorage` seam exists from Phase 3. |
| `@earendil-works/pi-server` | `DoMoServer` (planned) | No longer a non-goal. Narrowed hard: a *local, loopback-only, single-client-first* HTTP/SSE server (Hummingbird), modeled on opencode's `server.ts`/`event.ts`. Multi-instance supervision, mDNS discovery, and cloud presence stay out. |
| *(no upstream — pi has no MCP)* | `DoMoMCP` (planned) | Original to DoMoCode, not derived from pi. An MCP client (stdio-local first), modeled on opencode's/kilocode's `mcp/`. |

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

**The client/server split moves two mechanisms across a socket.** The runtime itself does not change in
isolation terms — it is already `nonisolated` / `@concurrent`-at-the-seams with a single `AgentHarness`
actor — and `DoMoServer` is `nonisolated`, running on NIO's event loops, while `DoMoTUI`'s `MainActor`
default stays entirely on the *client* side of the wire. But two invariants are genuinely weakened, and
the rewrite names them rather than hiding them. First, `AgentEventSink.emit` is *awaited* today: the run
does not advance until every listener has accepted each event. Over a socket that guarantee is unsafe —
one hung client would stall the agent loop — so the network fan-out sink becomes fire-and-forget with a
per-subscriber buffer and an explicit slow-client policy (drop-oldest, then disconnect), while the
durable persistence sink stays awaited. Second, the `Mutex`-guarded steering box stops being an
in-process lock and becomes a client→server request drained at the next steering poll. Both are real
losses of a documented property, accepted for the split; see [Non-goals](#non-goals-and-known-gaps).

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
      gateway. 1059 tests, green in both configurations.
- [ ] **Phase 5 — Polish.** Slash commands, `!` shell commands, skills, prompt templates,
      `AGENTS.md` loading, themes, external editor, session tree navigation, model cycling.
      Refinements taken from the [sibling harnesses](#sibling-harnesses-and-prior-art):
      `$ARGUMENTS`/`$N` and inline `` !`shell` `` substitution in command and prompt templates,
      with per-command model and agent overrides; keyword-triggered skill auto-injection and
      task-input `{VAR}` templates; opencode's ANSI-index / `none`-means-inherit theme model with
      dark/light variants (exactly right for an inline renderer painting over an arbitrary
      background); a local `/review` of a diff, branch, or commit; and an inline fuzzy command
      menu with an on-demand cheat-sheet printed into scrollback — the flat, remappable subset of
      a command palette that needs no overlay panel. Ships the in-process interactive path to a
      genuinely useful state *before* the architecture pivot begins.
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
- [ ] **Phase 6 — Headless HTTP/SSE runtime server** (re-scoped from the old "RPC mode"). A new
      `DoMoServer` on Hummingbird 2.x, modeled on opencode's server: `AgentEvent` gains `Codable`;
      a `BroadcastEventSink` fans the existing event stream out over `GET /event` (connected frame
      + per-event frames + heartbeat); REST wrappers over `AgentHarness`/`JSONLSessionStore`
      (`POST /session/:id/prompt`, list/get/messages/children/fork/abort); loopback-only bind with a
      per-session token; `domo serve`; the awaited-emit sink split (durable-awaited vs
      fan-out-buffered). *Exit:* `domo serve` runs the runtime headless, a scriptable client streams
      events over SSE, abort/fork/resume work over REST, the JSON protocol carries a version field
      with round-trip tests — **single loopback client only**; local interactive/`-p` stays
      in-process. The hub is built broadcast-*capable*; multi-client mirroring waits on Phase 7.
- [ ] **Phase 7 — Full-screen widget TUI** (built in-house — there is no OpenTUI-equivalent in
      Swift). `DoMoTermIO` gains alternate-screen enter/exit (`CSI ?1049h/l`) with crash-safe
      restore; a new `DoMoTUIKit` module adds a box/flexbox-lite layout solver above the existing
      1-D `Component` protocol, a fixed-height cell-buffer compositor reusing `RenderCore`'s frame
      differ, and pane/split/footer/sidebar containers with focus traversal; a new full-screen
      screen-state test oracle (no upstream oracle exists). `DoMoCLI` grows the SSE client + a small
      normalized event store so the full-screen TUI renders from the server stream with
      random-access repaint. *Exit:* a full-screen TUI attaches over SSE, renders a session, survives
      resize, and restores the terminal cleanly on crash — **inline mode stays first-class for piped
      and `-p` output.** This is the single largest net-new subsystem in the project.
- [ ] **Phase 7.5 — Inline images, the display half.** Port pi's `terminal-image.ts` into
      `DoMoTermGraphics` (Kitty/iTerm2 encoders, header-only dimension parsers, cell-pixel-size
      query) with two placement adapters — scrollback spacers for inline, absolute-cell Kitty
      virtual placements for full-screen — plus the Kitty-ID free-and-repaint bookkeeping. *Exit:*
      images render in both modes on Kitty/iTerm2 and degrade to a text placeholder under
      tmux/screen. Sequenced after Phase 7 because placement forks on the render mode.
- [ ] **Phase 8 — Permission engine, then MCP.** Land the granular allow/ask/deny permission engine
      *first* (the binary project-trust gate is too coarse to gate arbitrary tool execution and the
      prompt-injection surface MCP introduces). Then `DoMoMCP` via the official
      `modelcontextprotocol/swift-sdk`: an `McpManager` actor, **stdio transport, tools only, no
      OAuth**, namespaced tool discovery, an `McpTool: AgentTool` adapter, and the fixed tool set
      made dynamic with a per-turn snapshot. *Exit:* a stdio MCP server's tools appear namespaced in
      the agent's tool set, gated by allow/ask/deny and snapshot-stable within a turn. Remote
      transports and OAuth are explicitly a later, separately-scoped reversal.
- [ ] **Later (unscheduled).** Multi-client attach / session mirroring; remote MCP + OAuth (PKCE +
      dynamic client registration + loopback callback); SQLite/GRDB storage behind the existing
      `SessionStorage` protocol; the remaining
      [sibling-harness candidates](#sibling-harnesses-and-prior-art) (git-shadow checkpoints,
      headless `domo run`, agent personas, per-task budget cap, first-party tool additions, …); and
      sixel.

Phases 0–3 produced a genuinely useful headless tool; Phase 4 (the inline TUI) was the largest single
body of the *port*. The expansion is ordered by dependency, not by appeal: the server comes **before**
the full-screen TUI, because the TUI-as-client model presumes a server to attach to and the inline
renderer cannot faithfully replay a session's scrollback to a late client; image *input* is pulled
early because it is cheap and orthogonal; the permission engine precedes MCP because it is a safety
prerequisite, not a nicety. Upstream's TUI test suite is larger than its TUI source, and the new
full-screen renderer has **no upstream oracle at all** — budget for building its test harness, not just
its implementation.

## Sibling harnesses and prior art

pi is DoMoCode's upstream, but it is not the only coding-agent harness worth reading. Three others
sit alongside it in this workspace and were studied in depth — not for code to copy (**none is
copied, vendored, or derived**) but to decide, feature by feature, what a LiteLLM-only,
inline-terminal harness should adopt, adapt, or refuse. Each is MIT or MIT-cored and independently
developed; full attribution and the license nuances are in [NOTICES.md](NOTICES.md).

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
[scope expansion](#what-expanded-and-what-did-not) reverses that, in the narrowed form the roadmap
records: DoMoCode now **adopts the server shape** (bounded to a local, loopback-only,
single-client-first HTTP/SSE server, modeled on opencode's `server.ts`/`event.ts`) and grows a
**full-screen event-store client** beside the inline renderer — built in-house, because OpenTUI is
TypeScript and has no Swift port, so only its retained-cell-buffer-plus-flexbox *design* is borrowed,
never code. What DoMoCode still refuses is the *rest* of the cluster: a client-side multi-provider
abstraction (model breadth stays the LiteLLM gateway's job), OAuth login, a JS/TS plugin system, an
extension/skill/theme marketplace, mDNS/multi-device presence, and any web/IDE/desktop GUI. MCP crosses
from the refused column to a goal (stdio-local first); the multi-client, remote-MCP-with-OAuth, and
daemon breadth stays out. So the survey no longer merely *reaffirms* DoMoCode's boundaries — it moved
four of them, each at a named cost.

### Features worth adopting

What the survey did surface is a compact set of terminal-native, single-provider, dependency-light
features that fit inside every constraint. They are folded into the roadmap above — a few into Phase 5,
the granular permission engine into Phase 8 (MCP's safety prerequisite), and the rest into the
unscheduled *Later* bucket. "Fit" is judged against the [non-goals](#non-goals-and-known-gaps): a new
*first-party* tool is `adaptable`, not free, because the extensibility non-goal forbids plugin-defined
tools, not new Swift ones — each addition still forces a tool-vs-prompt-injection and
in-process-vs-out-of-process decision.

| Feature | Seen in | Fit | Lands in |
|---|---|---|---|
| Granular permission engine (allow/ask/deny globs, last-match-wins, inline once/always/reject) | all three | yes | Phase 8 |
| Git-shadow snapshot checkpoints + undo/redo + fork-from-any-message | kilocode, opencode | yes | Later |
| Headless `domo run` (prompt in, streamed/JSON out, exit codes, `--auto`) | kilocode, opencode | yes | Later |
| Config-driven agent/persona profiles + a read-only plan mode | all three | yes | Later |
| Auto-format-after-edit hook; repo `.setup.sh` session-init hook | all three | yes | Later |
| Hard per-task budget cap (abort the loop on a cost ceiling) | OpenHands | yes | Later |
| Trusted-config `{env:}`/`{file:}` interpolation gated by the trust boundary | kilocode | yes | Later |
| Local `/review` of a diff, branch, or commit | kilocode, OpenHands | yes | Phase 5 |
| Skill refinements: keyword auto-injection, task-input `{VAR}` templates | all three | yes | Phase 5 |
| Slash-command polish: `$ARGUMENTS`/`$N`, inline `` !`shell` ``, per-command overrides, ANSI-index / `none`=inherit theming | opencode, kilocode | yes | Phase 5 |
| First-party tool additions: `question`/`suggest`, todo checklist, `webfetch` (+ gated `apply_patch`, `websearch`, notebook-edit, `recall`) | all three | adaptable | Later |
| Selectable/tunable history condensers (observation-masking, recent-window, LLM-summarizing) | OpenHands | adaptable | Later |
| Local conveniences: prompt stash, `/btw` side-branch, background jobs, file watcher, deterministic JSONL replay, local secrets + env injection, out-of-process notify/sound | opencode, kilocode, OpenHands | yes/adaptable | Later |
| Out-of-process research items: ACP single-session stdio subcommand (atop the Phase-6 server), LSP post-edit diagnostics, Seatbelt/bubblewrap bash sandbox, local semantic index via the gateway's `/embeddings` | all three | adaptable | Later / research |

The semantic-index row is the sharpest example of "adapt, don't adopt": the idea ports only if
embeddings come from the single LiteLLM gateway's OpenAI-compatible `/embeddings` into an
SPM-resolvable local store — an external Qdrant or a second embedding provider would breach both the
single-provider and the SPM-only / no-vendored-binaries constraints.

### Features declined

The [scope expansion](#what-expanded-and-what-did-not) moved four items — the server, the full-screen
TUI, MCP, and inline images — out of this list. Most of the rest still recurs across all three and stays
out, each against a named constraint:

- **Multi-provider model layers and wire-protocol adapters** — DoMoCode has one surface (LiteLLM);
  model breadth is the gateway's job, so the client-side abstraction is both disallowed and
  redundant. This one did *not* move.
- **OAuth / device login, JS/TS plugin systems, in-process JS interpreters (kilocode's "CodeMode"),
  and extension/skill/theme marketplaces** — the declared extensibility, bearer-key-only, and
  package-manager non-goals; several also need vendored binaries (SPM-only). MCP is no longer in this
  bullet — it is a Phase-8 goal — but only *stdio-local* MCP, because *remote* MCP servers require
  full OAuth, so that half stays deferred here.
- **Detached daemons, multi-instance supervision, mDNS, multi-device sync, and multi-backend
  (Docker/K8s/remote) sandboxes** — still out. DoMoCode's own server (Phase 6) is deliberately the
  opposite, narrow slice: one local loopback endpoint, single-client-first, no supervision and no
  discovery. Only the *local* Seatbelt/bwrap wrap of the bash tool is a later candidate.
- **Web / GUI / IDE / desktop UI** — embedded VSCode/browser panes, a hosted web console, an Electron
  app, editor extensions, and an *interactive full-screen diff pane*. DoMoCode does build a full-screen
  *terminal* TUI (Phase 7, in-house), but it stays a terminal app on the inline renderer's own
  primitives; the OpenTUI/SolidJS/React foundations and every non-terminal surface stay out.
- **Cloud agents, webhooks, cron automations, git-provider issue-resolvers, and inline
  FIM/speech-to-text** — daemon + OAuth + non-terminal-input constraints. Only the local headless
  `run` primitive is in scope, invoked from an external job the user owns.

## Dependencies

Every direct dependency must resolve on Swift 6.2. Several pins below were previously version caps
imposed by the 6.1 floor rather than stability judgments; those caps are gone and the table records
the versions that replaced them.

The deployment floor is **macOS 15**, raised from 13. `Synchronization.Mutex` and `Atomic` are gated
`@available(macOS 15)` on Apple platforms — they are unconditional on Linux — and they are how shared
mutable state is handled here, per [Concurrency](#concurrency-and-isolation). macOS 15 shipped in
September 2024; requiring it for a developer CLI is not aggressive.

These thirteen resolve as a set on a 6.2 manifest, and to a graph of **33 packages** once transitive
dependencies are counted — the AsyncHTTPClient tail (NIO, NIO-SSL, NIO-HTTP2, swift-certificates,
swift-crypto, swift-asn1, service-lifecycle) and swift-syntax 603, pulled by swift-json-schema for its
macros, account for most of that. swift-syntax is the single largest build-time cost in the graph; if
clean-build time becomes intolerable, dropping to swift-json-schema's non-macro modules and
hand-writing the tool schemas removes it.

The [scope expansion](#what-expanded-and-what-did-not) adds direct dependencies, tagged in the table
with the phase that introduces them: **Hummingbird** for the server (Phase 6), the **MCP Swift SDK**
(Phase 8), and, only if image resizing is in scope, **swift-png**/**swift-jpeg** (Phase 7.5). Because
Hummingbird is built on the swift-nio tail already resolved above, the net-new graph is modest. The
full-screen TUI (Phase 7) adds *no* dependency — it is built in-house on the existing renderer.

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
| [jpsim/Yams](https://github.com/jpsim/Yams) | MIT | YAML frontmatter in skills and prompt templates. `from: "6.2.2"` — that is Yams' own semver and has nothing to do with the Swift version. |
| [ajevans99/swift-json-schema](https://github.com/ajevans99/swift-json-schema) | MIT | Tool-schema generation *and* draft-2020-12 validation of returned arguments — validation is the half that protects you. `.upToNextMinor(from: "0.13.1")`, pre-1.0. |
| [swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0 WITH Swift-exception | cmark-gfm AST for the Markdown component. `.upToNextMinor(from: "0.8.0")` — the 6.1 floor capped this at 0.7.1. The repository moved from `apple/`, which now redirects; pin the semver tag, never a `swift-6.x.y-RELEASE` tag. |
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Later (SQLite session storage), optional target only. `from: "7.11.1"`. |
| [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | **Test target only** — a headless VT100 emulator used as a test oracle. Renderer bytes go in, assertions run against the resulting cell grid. Without it the riskiest code in the port has no end-to-end coverage on a TTY-less CI runner. `from: "1.15.0"`. Builds in Swift 5 language mode, so expect `Sendable` friction at the boundary from a `[.v6]` test target. Note: it does *not* emulate the Kitty/iTerm2 graphics protocols, so image *display* (Phase 7.5) has weaker automated coverage than the rest of the renderer. |
| [hummingbird-project/hummingbird](https://github.com/hummingbird-project/hummingbird) | Apache-2.0 | **Phase 6.** HTTP router + streaming SSE for `DoMoServer` (an SSE body is just a response streamed from an `AsyncSequence`). Built directly on swift-nio, already resolved via async-http-client, so it adds little to the graph. `swift-tools-version: 6.0`. Vapor was assessed and declined — heavier graph, older `EventLoopFuture`-era surface. |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | MIT / Apache-2.0 | **Phase 8.** The MCP client for `DoMoMCP` (stdio transport first). Pre-1.0, `.upToNextMinor(from: "0.12.1")`; `swift-tools-version: 6.1`. One risk to watch: it pins `swift-docc-plugin` to a git *branch*, which can complicate reproducible resolution — a hand-rolled JSON-RPC-over-stdio client (on `JSONValue` + swift-subprocess + EventSource, all already present) is the pre-justified fallback. |
| [tayloraswift/swift-png](https://github.com/tayloraswift/swift-png) | Apache-2.0 | **Phase 7.5, optional.** Pure-Swift PNG decode/encode, needed only if attachments must be resized to fit provider byte caps. `swift-tools-version: 5.10`. Skipped entirely for pass-through images. |
| [tayloraswift/swift-jpeg](https://github.com/tayloraswift/swift-jpeg) | Apache-2.0 | **Phase 7.5, optional.** Pure-Swift JPEG companion to swift-png for normalizing attachments. `swift-tools-version: 6.0`. |

### Deliberately not used

- **TUI frameworks** (SwiftTUI, TermKit, TUIkit, ncurses bindings) — assessed for the full-screen mode
  (Phase 7) and declined in favor of building the layout layer in-house. This is now a *build-vs-adopt*
  decision, not a no-widget-toolkit stance. `rensbreur/SwiftTUI` (MIT, `swift-tools-version: 5.6`) is
  the closest fit and is held as an escape hatch, but every candidate *owns* the screen, the stdin read
  loop, and the event model: adopting one means running a second terminal-owning stack beside
  `DoMoTermIO`'s key-decoding / framing / keybindings seam, rewriting `Editor` / `Markdown` /
  `Autocomplete` / `SelectList` as framework views, and surrendering the byte-level diff, the
  width-invariant check, and `CSI ?2026` synchronized output to a reactive whole-tree recompute — all
  on a pre-1.0 dependency. The in-house path instead adds an alternate-screen mode plus a flexbox-lite
  layout layer *above* the existing 1-D `Component` protocol, reusing `RenderCore`'s frame differ, the
  width engine, and every built widget unchanged. (`swifttui.sh`'s swift-tui is separately disqualified:
  its manifest declares `swift-tools-version: 6.3`, above the floor, so it will not resolve.)
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
  bet declined above. Its OSC-query surface is the genuinely non-duplicative part; worth revisiting
  at Phase 4 as a narrow dependency for background detection only, if theming needs it.
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

Planned precedence, highest first: **CLI flag → environment variable → project
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
| `DOMOCODE_TIMEOUT_MS` | `600000` | Overall request timeout. |
| `DOMOCODE_STREAM_TIMEOUT_MS` | `30000` | Time to first chunk — the knob that makes the UI feel responsive. |
| `DOMOCODE_MAX_RETRIES` | `3` | Client-side retry count. |
| `DOMOCODE_CONFIG_DIR` | `~/.domocode` | Settings, sessions, trust store, skills, themes. |
| `DOMOCODE_SESSION_DIR` | `$CONFIG_DIR/sessions` | Session JSONL root. |
| `DOMOCODE_LOG_LEVEL` | `warning` | Logs go to stderr; stdout is reserved for the JSON protocol channel. |
| `DOMOCODE_OFFLINE` | `0` | Skip catalog and version lookups. |
| `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` | — | Honored by the transport. |

Secrets are never written to `settings.json` — only the *name* of the environment variable holding
them, or a `~/.domocode/credentials.json` created `0600` whose permissions are checked on read.

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

Two run modes are planned once the [expansion](#roadmap) lands. `domo` continues to run in-process for
local interactive and `-p` use, with **inline** output by default — the only mode that pipes.
`domo serve` (Phase 6) starts the headless runtime behind a loopback-only HTTP/SSE server with a
per-session token, and `domo` then attaches to it as a **full-screen** alternate-screen client
(Phase 7).

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
[sibling harnesses](#sibling-harnesses-and-prior-art) — a permission engine ([Phase 8](#roadmap)),
snapshot checkpoints, a headless `run`, agent personas, and more (Later) — is tracked there. Inline
images and a local server are no longer deferred; they are roadmap phases.

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

**Costs the expansion accepts.** The four reversals are not free, and the honest list is short and real:

- **Full-screen mode abandons shell-scrollback composition.** The inline renderer's whole point is that
  it paints into normal scrollback and composes with your shell history; the alternate-screen mode owns
  the screen, leaves no transcript behind, and cannot be piped. Inline mode is kept as a first-class
  second mode precisely so that property is not lost outright.
- **Two render modes, and a new oracle to build.** The inline diff was verified against pi's oracle;
  the fixed-height cell-buffer diff is new code with *no* upstream oracle, so its correctness rests on
  a test harness DoMoCode must write itself, and the two modes double the renderer's test surface.
- **A local server is a new attack surface.** A socket on loopback is reachable by any local process;
  the mitigation is a loopback-only bind plus a per-session token by default, but the single-process
  design never had this exposure.
- **A weakened backpressure invariant.** The awaited event-emit guarantee is deliberately relaxed for
  the network fan-out sink (buffer + slow-client policy), as [Concurrency](#concurrency-and-isolation)
  records; a late client can only backfill a summary, not replay exact history.
- **MCP widens the prompt-injection surface.** MCP tool descriptions and resource contents are
  attacker-controlled text entering the context, which is why the permission engine is a hard
  prerequisite (Phase 8) and remote servers wait.
- **Image display has weaker coverage.** Kitty images do not reflow and cannot be asserted on the
  TTY-less CI oracle, so display correctness leans on manual verification more than the rest of the
  renderer does.

## Contributing

Phases 0–4 are implemented; Phase 5 and the [expansion](#roadmap) are the current work. Issues
proposing scope changes — particularly anything in [Non-goals](#non-goals-and-known-gaps) — are
welcome before code lands rather than after.

## License

DoMoCode is released under the [MIT License](LICENSE), Copyright (c) 2026 Sam Stegall.

DoMoCode is a port of the [Pi Agent Harness](https://github.com/earendil-works/pi), Copyright (c)
2025 Mario Zechner, also under the MIT License. The upstream license text is reproduced in full in
[NOTICES.md](NOTICES.md), together with attribution for third-party dependencies.

"Pi", "Pi Agent Harness", and related names and marks are the property of their respective owners
and are used here for identification purposes only.
