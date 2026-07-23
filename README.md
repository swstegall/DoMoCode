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

1. **Swift 6.1**, `swift-tools-version: 6.1`, `swiftLanguageModes: [.v6]` — strict concurrency on
   from day one.
2. **Swift Package Manager only.** No CocoaPods, no Carthage, no vendored binary frameworks. Every
   dependency resolves from a public GitHub repository.
3. **One provider surface: LiteLLM.** Model breadth is the gateway's job, not the client's.

The Swift 6.1 pin is a hard constraint with a real cost: SwiftPM rejects any dependency whose
manifest declares a `swift-tools-version` above the active toolchain, and a good deal of recent
terminal-and-concurrency work in the Swift ecosystem has already moved to 6.2. The
[dependency table](#dependencies) records the pins this forces. Module boundaries are drawn so that a
future 6.2 bump is a version change, not a refactor.

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
| `@earendil-works/pi-tui` | `DoMoTermIO` + `DoMoTUI` | Split in two. TermIO owns terminal state (`terminal.ts`, `stdin-buffer.ts`); TUI owns the diff renderer, components, and the width/ANSI engine (`tui.ts`, `keys.ts`, `utils.ts`, `components/`). Inline images and the Windows shims are dropped. |
| `@earendil-works/pi-ai` | `DoMoLLM` | Radically narrowed. Keeps the *shapes* — `Context`, `AssistantMessage`, `Usage`, `StopReason` — plus the streaming tool-call assembler, retry/overflow classifiers, and cost math. Drops 37 providers, 9 wire APIs, OAuth, and the generated model catalog. |
| `@earendil-works/pi-agent-core` (`agent-loop.ts`, `types.ts`) | `DoMoAgent` | Ported structurally: turn loop, stop conditions, three-phase tool dispatch, parallel-vs-sequential execution, truncated-tool-call refusal, steering queues. |
| `@earendil-works/pi-agent-core` (`harness/`) | `DoMoHarness` | Session tree, storage, `buildContext`, compaction, branch summarization, hooks. |
| `@earendil-works/pi-agent-core` (`env/nodejs.ts`) | `DoMoExec` | Protocol-based FileSystem and Shell with a single POSIX implementation. |
| `@earendil-works/pi-coding-agent` (`core/tools/`) | `DoMoTools` + `DoMoToolsUI` | The built-in tools, split headless/rendered. |
| `@earendil-works/pi-coding-agent` (rest) | `DoMoCLI` | Session orchestration, settings, trust, slash commands, output modes. |
| `@earendil-works/pi-storage-sqlite-node` | `DoMoHarness` protocol; SQLite backend deferred | JSONL is the shipping default; the `SessionStorage` seam exists from Phase 3. |
| `@earendil-works/pi-server` | *(none)* | Explicit non-goal. |

## Roadmap

Ordered strictly by dependency. Each phase ends with something runnable and tested.

- [ ] **Phase 0 — Skeleton.** `Package.swift` with the pin table, all targets declared, CI on macOS
      and Ubuntu at Swift 6.1. `DoMoCore`: `JSONValue`, JSON Schema, the tolerant JSON parser,
      `uuidv7`, error taxonomy, JSONL codec.
- [ ] **Phase 1 — Talk to LiteLLM headlessly.** `DoMoLLM` end to end: transport seam, lenient
      `Codable` models, SSE decoding, `[DONE]`, in-stream error sniffing, the tool-call accumulator,
      usage capture, retry/backoff, `GET /v1/models` catalog. Plus `DoMoExec` and headless
      `DoMoTools`. *Exit:* `domocode -p "list the files here"` runs a real multi-turn tool loop and
      prints plain text — with zero TUI code, which is exactly why it comes first.
- [ ] **Phase 2 — The agent loop.** `DoMoAgent` as a pure, heavily unit-tested function; Phase 1's
      ad-hoc loop is retrofitted onto it.
- [ ] **Phase 3 — Persistence and harness.** Session tree, JSONL storage, `buildContext`, compaction,
      branch summarization, hooks. `--continue` / `--resume` / `--fork`, settings with global/project
      merge, project trust. *Exit:* sessions survive restart; `--mode json` is scriptable.
- [ ] **Phase 4 — Terminal.** `DoMoTermIO` (raw mode, restore-on-crash, SIGWINCH, stdin framing),
      then `DoMoTUI` (width engine → components → diff renderer → overlays → Editor → keybindings →
      Markdown). *Exit:* interactive mode with streaming output, `@` file completion,
      Escape-to-abort, Enter-steering.
- [ ] **Phase 5 — Polish.** Slash commands, `!` shell commands, skills, prompt templates,
      `AGENTS.md` loading, themes, external editor, session tree navigation, model cycling.
- [ ] **Phase 6 — Deferred.** SQLite storage behind the existing protocol; RPC mode; anything
      promoted out of [Non-goals](#non-goals-and-known-gaps).

Phases 0–3 are what produce a genuinely useful tool. Phase 4 is the largest single body of work in
the port and deliberately waits until the headless path is stable — debugging a differential renderer
while the agent loop is still moving is how ports die.

## Dependencies

Every direct dependency must resolve on Swift 6.1. Several ecosystem packages have moved their
manifests to `swift-tools-version: 6.2`, which 6.1's SwiftPM rejects outright; those are pinned
accordingly and the reason is noted.

| Package | License | Why |
|---|---|---|
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | CLI flags, subcommands, shell completions. |
| [swift-server/async-http-client](https://github.com/swift-server/async-http-client) | Apache-2.0 | The transport that streams incrementally with backpressure on both Darwin and Linux. |
| [apple/swift-http-types](https://github.com/apple/swift-http-types) | Apache-2.0 | Currency types for the transport seam, so URLSession can be swapped in on Apple-only builds. |
| [mattt/EventSource](https://github.com/mattt/EventSource) | MIT | Transport-free incremental SSE parser, driven directly rather than via its client. Declares `swift-tools-version: 6.1`. |
| [ainame/swift-displaywidth](https://github.com/ainame/swift-displaywidth) | MIT | Grapheme-cluster-aware terminal cell width. A width bug corrupts every subsequent column on a line, so this is load-bearing for the renderer. |
| [apple/swift-system](https://github.com/apple/swift-system) | Apache-2.0 | `FilePath`, `FileDescriptor`, `Errno`. Note it does *not* expose termios or ioctl. |
| [swiftlang/swift-subprocess](https://github.com/swiftlang/swift-subprocess) | Apache-2.0 | Async subprocess with cancellation that reaches the child. Pinned below 0.5 — 0.5+ requires Swift 6.2. |
| [apple/swift-log](https://github.com/apple/swift-log) | Apache-2.0 | Logging facade; handler tees JSON to the session log and human text to stderr. Pinned below 1.10.1 for the same reason. |
| [jpsim/Yams](https://github.com/jpsim/Yams) | MIT | YAML frontmatter in skills and prompt templates. |
| [ajevans99/swift-json-schema](https://github.com/ajevans99/swift-json-schema) | MIT | Tool-schema generation *and* draft-2020-12 validation of returned arguments — validation is the half that protects you. |
| [apple/swift-markdown](https://github.com/apple/swift-markdown) | Apache-2.0 | cmark-gfm AST for the Markdown component. |
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | Phase 6, optional target only. |
| [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | **Test target only** — a headless VT100 emulator used as a test oracle. Renderer bytes go in, assertions run against the resulting cell grid. Without it the riskiest code in the port has no end-to-end coverage on a TTY-less CI runner. |

### Deliberately not used

- **TUI frameworks** (SwiftTUI, TermKit, TUIkit, ncurses bindings) — DoMoCode is an *inline diffing
  renderer*, not a widget toolkit. Upstream pi never takes the alternate screen; it paints into
  normal scrollback with exact relative cursor motion, which is what makes it compose with your
  shell history. No Swift framework does that, and adopting one means fighting it for screen
  ownership.
- **Color libraries** (Rainbow, ColorizeSwift) — styling is injected as `(String) -> String`
  closures; there is nothing to depend on. About 60 lines of SGR helpers instead.
- **swift-openapi-generator / MacPaw/OpenAI** — a generated strict decoder fails where a lenient
  hand-written one shrugs, and "OpenAI-compatible" servers deviate constantly. Roughly eight lenient
  `Codable` structs instead.
- **AnyCodable** — archived, and `value: Any` is fundamentally non-`Sendable`. `DoMoCore.JSONValue`
  instead.

### Written by hand

No adoptable Swift 6.1 package exists for these, so they are part of the port rather than a
dependency: termios raw mode and panic-safe restore; terminal size and SIGWINCH; escape-sequence
reassembly and key decoding (legacy tables, Kitty CSI-u, xterm `modifyOtherKeys`); the differential
frame renderer; a tolerant partial-JSON parser for streaming tool calls; the streaming tool-call
accumulator; SSE `[DONE]` and in-stream error handling; gitignore semantics and the file walker;
realpath-based path sandboxing; and the Markdown-to-ANSI walker.

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

Requires a Swift 6.1 toolchain. Targets macOS 13+ and Linux.

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
