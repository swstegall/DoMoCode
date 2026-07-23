# DoMoCode

A terminal UI coding-agent harness for Swift, built with Swift Package Manager, that talks to many
different models through a single [LiteLLM](https://github.com/BerriAI/litellm) gateway.

DoMoCode is a Swift port of the [Pi Agent Harness](https://github.com/earendil-works/pi) by Mario
Zechner, derived from `v0.81.1` (commit
[`9b3a2059`](https://github.com/earendil-works/pi/commit/9b3a2059171bcc74ad9d2cadeea6d186776cf2db),
2026-07-22) and used under the MIT License. DoMoCode is an independent project and is not affiliated
with or endorsed by the Pi Agent Harness project. See [NOTICES.md](NOTICES.md) for full attribution.

---

## Status: pre-implementation

**This repository contains no implementation yet.** Everything below is a statement of intent and a
plan of record — a description of what DoMoCode is being built to be, not of shipped behavior. Every
capability is tagged with the phase that will deliver it, and nothing is described in the present
tense until the corresponding phase lands.

DoMoCode is a deliberately **narrowed** port, not a feature-parity port. See
[Non-goals](#non-goals-and-known-gaps) for what is being left out on purpose.

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

## Architecture

Package name `DoMoCode`; executable target and installed command `domocode`.

```
Sources/
  DoMoCore/        Shared vocabulary: JSONValue, JSON Schema, tolerant/partial JSON parser,
                   error taxonomy, JSONL codec, uuidv7.
  DoMoTermIO/      The POSIX seam. The only module that imports Darwin/Glibc: termios raw mode,
                   TIOCGWINSZ, SIGWINCH, the stdin byte pump, panic-safe terminal restore.
  DoMoTUI/         Inline (non-alternate-screen) differential renderer, Component protocol,
                   overlays, multi-line Editor, keybindings, ANSI/display-width text engine.
  DoMoLLM/         LiteLLM-only OpenAI-compatible client: transport seam, SSE decoding, streaming
                   tool-call accumulator, model catalog, usage and cost accounting.
  DoMoAgent/       The pure agent loop: turn structure, tool dispatch, steering and follow-up
                   queues, event sink. No I/O, no persistence — so it is cheap to test.
  DoMoHarness/     Session tree, JSONL storage, context building, compaction, branch summaries,
                   skills and prompt templates, hooks.
  DoMoExec/        FileSystem + Shell over swift-subprocess; gitignore walker; path sandboxing;
                   per-path file mutation coordinator.
  DoMoTools/       The built-in tools (read/write/edit/bash/grep/find/ls), headless by design —
                   no TUI imports.
  DoMoToolsUI/     Renderers for those tools, reattached at composition time.
  DoMoCLI/         Modes (interactive/print/json), settings, project trust, resource loading,
                   slash commands, wiring.
  domocode/        The executable. ArgumentParser root plus DoMoCLI.run().
```

### How this maps to upstream pi

| pi package | DoMoCode module(s) | Notes |
|---|---|---|
| `@earendil-works/pi-tui` | `DoMoTermIO` + `DoMoTUI` | Split in two. TermIO owns terminal state (`terminal.ts`, `stdin-buffer.ts`); TUI owns the diff renderer, components, and the width/ANSI engine (`tui.ts`, `keys.ts`, `keybindings.ts`, `utils.ts`, `fuzzy.ts`, `autocomplete.ts`, `kill-ring.ts`, `undo-stack.ts`, `word-navigation.ts`, `components/`). Inline images and the Windows shims are dropped. |
| `@earendil-works/pi-ai` | `DoMoLLM` | Radically narrowed. Keeps the *shapes* — `Context`, `AssistantMessage`, `Usage`, `StopReason` — plus the streaming tool-call assembler, retry/overflow classifiers, and cost math. Drops 37 providers, 9 wire APIs, OAuth, and the generated model catalog. |
| `@earendil-works/pi-agent-core` (`agent-loop.ts`, `types.ts`) | `DoMoAgent` | Ported structurally: turn loop, stop conditions, three-phase tool dispatch, parallel-vs-sequential execution, truncated-tool-call refusal, steering queues. |
| `@earendil-works/pi-agent-core` (`harness/`) | `DoMoHarness` | Session tree, storage, `buildContext`, compaction, branch summarization, hooks. |
| `@earendil-works/pi-agent-core` (`env/nodejs.ts`) | `DoMoExec` | Protocol-based FileSystem and Shell with a single POSIX implementation. |
| `@earendil-works/pi-coding-agent` (`core/tools/`) | `DoMoTools` + `DoMoToolsUI` | The built-in tools, split headless/rendered. |
| `@earendil-works/pi-coding-agent` (rest) | `DoMoCLI` | Session orchestration, settings, trust, slash commands, output modes. |
| `@earendil-works/pi-storage-sqlite-node` | `DoMoHarness` protocol; SQLite backend deferred | JSONL is the shipping default; the `SessionStorage` seam exists from Phase 3. |
| `@earendil-works/pi-server` | *(none)* | Explicit non-goal. |

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

Deliberately *not* adopted: `Span`, `RawSpan`, `UTF8Span`, and `InlineArray`. They are the right shape
for the escape decoder and for grapheme-cluster width measurement, but every standard-library API that
*produces* one is `@available(macOS 26)` — the types back-deploy, the accessors do not — and on Linux
they are unconditional, so using them means `#if` divergence in the most correctness-critical code in
the project. The decoder is built on `[UInt8]` with an explicit index, but its internal view type is
deliberately `Span`-shaped (borrowed base plus count, explicit slicing, no ownership) so the storage
swap is mechanical when the floor eventually reaches macOS 26.

## Roadmap

Ordered strictly by dependency. Each phase ends with something runnable and tested.

- [ ] **Phase 0 — Skeleton.** `Package.swift` with the pin table, all targets declared, the per-target
      isolation and safety settings from [Concurrency](#concurrency-and-isolation), CI on macOS and
      Ubuntu at Swift 6.2 building in both debug and `-c release`. `DoMoCore`: `JSONValue`, JSON
      Schema, the tolerant JSON parser, `uuidv7`, error taxonomy, JSONL codec.
- [ ] **Phase 1 — Talk to LiteLLM headlessly.** `DoMoLLM` end to end: transport seam, lenient
      `Codable` models, SSE decoding, `[DONE]`, in-stream error sniffing, the tool-call accumulator,
      usage capture, retry/backoff, `GET /v1/models` catalog. Plus `DoMoExec` and headless
      `DoMoTools`. *Exit:* `domocode -p "list the files here"` runs a real multi-turn tool loop and
      prints plain text — with zero TUI code, which is exactly why it comes first. `DoMoExec` targets
      swift-subprocess 0.5+, whose API differs substantially from the 0.4 line: `Execution` is generic
      over its input/output types, `CollectedResult` / `ExecutionRecord` / `ExecutionOutcome`
      collapsed into a single `ExecutionResult`, and the 16 `run()` overloads became 6. Write against
      0.5 directly; do not follow examples written for 0.4.
- [ ] **Phase 2 — The agent loop.** `DoMoAgent` as a pure, heavily unit-tested function; Phase 1's
      ad-hoc loop is retrofitted onto it.
- [ ] **Phase 3 — Persistence and harness.** Session tree, JSONL storage, `buildContext`, compaction,
      branch summarization, hooks. `--continue` / `--resume` / `--fork`, settings with global/project
      merge, project trust. *Exit:* sessions survive restart; `--mode json` is scriptable.
- [ ] **Phase 4 — Terminal.** Ordered so the test oracle exists before the code it judges.
      **4a:** the SwiftTerm-backed screen-state harness — renderer bytes in, assertions against a real
      VT100 cell grid, including a fixture where the transcript exceeds the viewport. A harness that
      records writes instead of emulating a screen cannot catch the bug class this phase exists to
      avoid. **4b:** `DoMoTermIO` — raw mode, restore-on-crash, SIGWINCH, and the stdin framing layer
      with an explicit complete/incomplete/not-escape state machine plus an ESC-disambiguation
      timeout, tested before any decoding is written. **4c:** the key decoder as a public pure
      function, the `KeyId` grammar and matcher, then the keybindings layer — this ordering is
      load-bearing, since the app layer resolves keybindings at roughly forty call sites. **4d:**
      `DoMoTUI` — width engine → components → diff renderer (with viewport, height-change, shrink and
      append-past-viewport bookkeeping) → overlays → Editor → Markdown. *Exit:* interactive mode with
      streaming output, `@` file completion, Escape-to-abort, Enter-steering.
- [ ] **Phase 5 — Polish.** Slash commands, `!` shell commands, skills, prompt templates,
      `AGENTS.md` loading, themes, external editor, session tree navigation, model cycling.
- [ ] **Phase 6 — Deferred.** SQLite storage behind the existing protocol; RPC mode; anything
      promoted out of [Non-goals](#non-goals-and-known-gaps).

Phases 0–3 are what produce a genuinely useful tool. Phase 4 is the largest single body of work in
the port and deliberately waits until the headless path is stable — debugging a differential renderer
while the agent loop is still moving is how ports die. Upstream's TUI test suite is larger than its
TUI source, and for a port the tests *are* the specification; budget for porting them, not just the
implementation.

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
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Phase 6, optional target only. `from: "7.11.1"`. |
| [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | **Test target only** — a headless VT100 emulator used as a test oracle. Renderer bytes go in, assertions run against the resulting cell grid. Without it the riskiest code in the port has no end-to-end coverage on a TTY-less CI runner. `from: "1.15.0"`. Builds in Swift 5 language mode, so expect `Sendable` friction at the boundary from a `[.v6]` test target. |

### Deliberately not used

- **TUI frameworks** (SwiftTUI, TermKit, TUIkit, ncurses bindings) — DoMoCode is an *inline diffing
  renderer*, not a widget toolkit. Upstream pi never takes the alternate screen; it paints into
  normal scrollback with exact relative cursor motion, which is what makes it compose with your
  shell history. Adopting a widget toolkit means fighting it for screen ownership.
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
swift run domocode     # run from source
```

## Non-goals and known gaps

Stated plainly, because a port that implies parity will disappoint.

**Out of scope, deliberately:**

- **The TypeScript extension system.** This is pi's signature feature, and there is no Swift
  equivalent that preserves what makes it work — in-process input mutation, live custom components,
  hot reload. DoMoCode ships a fixed tool set and a fixed hook surface. If extensibility ever
  returns it will be out-of-process, and that is a research item rather than a promise.
- **Multi-provider support.** One wire API, one gateway. Routing across Bedrock, Vertex, Anthropic,
  and the rest is LiteLLM's job — that is the entire premise.
- **OAuth login flows.** Bearer key only.
- **The `pi-server` daemon** — multi-instance supervision, Unix-socket IPC, cloud presence.
- **The pi package manager** for distributing extensions, skills, and themes.
- **Windows.** macOS and Linux only. Not blocked architecturally, just unbuilt and untested.
- **MCP.** Upstream pi does not have it either, so this is not a regression — but people will ask.

**Deferred:** inline images (Kitty/iTerm2 graphics protocols), SQLite session storage, RPC mode,
session sharing and HTML export, vim-mode editing.

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

## Contributing

The repository is pre-implementation; Phase 0 is the current work. Issues proposing scope changes —
particularly anything in [Non-goals](#non-goals-and-known-gaps) — are welcome before code lands
rather than after.

## License

DoMoCode is released under the [MIT License](LICENSE), Copyright (c) 2026 Sam Stegall.

DoMoCode is a port of the [Pi Agent Harness](https://github.com/earendil-works/pi), Copyright (c)
2025 Mario Zechner, also under the MIT License. The upstream license text is reproduced in full in
[NOTICES.md](NOTICES.md), together with attribution for third-party dependencies.

"Pi", "Pi Agent Harness", and related names and marks are the property of their respective owners
and are used here for identification purposes only.
