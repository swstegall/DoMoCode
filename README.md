# DoMoCode

DoMoCode is a Swift terminal harness for coding agents. It owns the agent loop,
tools, sessions, permissions, terminal UI, and local runtime; the model
connection is an adapter that can be LiteLLM, a direct provider, or a
protocol-speaking external agent.

The project began as a port of the [Pi Agent Harness](https://github.com/earendil-works/pi).
It is now a broader MIT-licensed Swift harness informed by Pi, OpenCode,
Kilo Code, and OpenHands. The port attribution and file-level notices are in
[NOTICES.md](NOTICES.md).

## Status

The existing implementation records Phases 0–21 as complete. Those phases cover
the runtime, both terminal surfaces, the local HTTP/SSE server, images,
permissions, MCP, commands and skills, context management, mutable tools, Git
review, checkpoints, agents, subagents, LSP, memory, sandboxing, PTY support,
export/replay, and split-footer rendering.

Phases 0–33 are recorded as complete, including the focused TUI interaction,
model-discovery, help, and direct tool-catalog command work in Phase 32 and
the Copilot-compatible `.github` prompt-resource discovery in Phase 33.

Audit snapshot: 2026-08-03. Branches and feature refs can move; the branch
table below records what was present in the local checkouts at audit time.

## Project contract

The following are the only hard constraints carried forward:

1. The supported toolchain is Swift 6.3 or newer. CI currently pins Swift
   6.3.3. The manifest may use an older manifest-format declaration when that
   is required by SwiftPM, but the tested toolchain floor is 6.3.
2. Code copied, ported, vendored, or newly authored for DoMoCode must be
   MIT-licensed or original DoMoCode work. PolyForm, proprietary, or
   source-available code is not eligible. In particular, the OpenHands
   enterprise/ tree is excluded.
3. Third-party Swift libraries must be Swift Package Manager dependencies
   resolvable from public GitHub repositories. Their licenses may be
   non-MIT, but every license and notice obligation must be reviewed and
   recorded in [NOTICES.md](NOTICES.md). No CocoaPods, Carthage, registry-only
   package, vendored binary, or unreviewed generated SDK is a roadmap
   prerequisite.

The current repository contains a small amount of existing Apache-derived
source and several Apache-licensed package dependencies; both are documented
in [NOTICES.md](NOTICES.md). The MIT-only code rule is the admission policy for
all new work, and Phase 22 removes or replaces the existing Apache-derived
source so the shipped DoMoCode code remains MIT-licensed. Non-MIT dependencies
are allowed and remain ordinary notice obligations, not a reason to reject a
useful SwiftPM library.

Everything else is open for evidence-based design: provider choice, auth
method, platform breadth, session storage, UI shape, local versus remote
execution, sandbox backend, automation, and the boundary between native tools
and MCP/ACP tools. A current implementation detail is not a permanent product
assumption.

## Quick start

Requirements: Swift 6.3 or newer and a currently supported platform. The
manifest currently declares macOS 15; portability is a roadmap concern, not a
reason to design new code around macOS-only APIs.

From this directory:

~~~sh
cd DoMoCode
swift build
swift test --no-parallel
swift test --configuration release --no-parallel
~~~

Point the current LiteLLM adapter at a gateway and run a prompt:

~~~sh
export DOMOCODE_BASE_URL=http://localhost:4000/v1
export DOMOCODE_API_KEY=replace-with-a-key
export DOMOCODE_MODEL=your-model-alias
swift run domo
swift run domo -p "summarize this repository"
~~~

Do not put the key in settings.json, a session file, or a prompt. DoMoCode
stores the name of the environment variable, not its value.

Current invocations:

| Invocation | Current behavior |
|---|---|
| domo | Full-screen alternate-screen client attached to a loopback server. |
| domo --inline | Inline REPL in normal terminal scrollback. |
| domo --mini | Inline REPL with a split footer pinned below scrollback. |
| domo -p "..." | Headless text mode; the answer goes to stdout. |
| domo -p "..." --json | Headless newline-delimited event output. |
| domo --serve | Loopback HTTP/SSE runtime server. |

## What is implemented today

The current source is split into these seams:

~~~text
DoMoCore          JSON values/schema, partial JSON, errors, redaction, JSONL, IDs
DoMoLLM           current LiteLLM/OpenAI-compatible transport, SSE, usage, retries
DoMoAgent         provider-independent turn loop, dispatch, queues, event sink
DoMoHarness       session tree, persistence, context, compaction, commands, skills
DoMoMemory        session recall and durable project memory
DoMoExec          files, shell, subprocesses, PTY launch, image loading, sandbox
DoMoGit           status/diff/review, shadow-Git checkpoints, restore planning
DoMoTools         built-in model tools and per-session state
DoMoPermissions   allow/ask/deny policy, trust, grants, environment guards
DoMoMCP           environment-scrubbed stdio MCP client and dynamic MCP tools
DoMoLSP           pooled LSP diagnostics and post-mutation diagnostics
DoMoServer        local REST/SSE runtime and session-owned PTYs
DoMoTermIO        POSIX terminal seam, raw mode, input, VT screen, lifecycle
DoMoTUI           inline and alternate-screen renderers, layouts and widgets
DoMoTermGraphics  Kitty/iTerm2 image encoding and dimension detection
DoMoToolsUI       built-in tool renderers
DoMoClient        full-screen two-pane REST/SSE client
DoMoCLI           composition, configuration, trust, modes, and executable wiring
~~~

The runtime already has important safety and reliability behavior:

- permission decisions are applied before model-originated tools run;
- project configuration is trust-gated and may tighten, never widen, policy;
- credentials are redacted from provider failures, settings, child processes,
  memory, and session-facing diagnostics;
- file mutations are serialized per path;
- Seatbelt/bubblewrap selection fails closed when sandboxing is requested;
- tool errors are model-visible results, while cancellation remains control
  flow;
- sessions are append-only JSONL trees with resume, fork, clone, compaction,
  branch summaries, export, replay, and undo/redo;
- tool resolution is late-bound per request and MCP tools/list_changed can
  refresh a live session;
- inline and full-screen clients share agent semantics but retain different
  terminal contracts.

## Current tool surface

The registry is intentionally context-dependent. A plan-mode, headless, or
permission-restricted session does not necessarily expose the same model tool
array as a build-mode interactive session.

| Group | Tools or capability | Current state |
|---|---|---|
| Files and shell | read, write, edit, bash, ls, find, grep, glob | Built in; sandbox and permission gated. |
| Run control | todowrite, finish, question, background_process, interactive_terminal | Built in where the surface can answer or attach to the operation. |
| Context | session_recall, memory, compaction, LSP diagnostics | Built in or injected by the harness. |
| Delegation | task, plan_exit, build/plan agent profiles | Built in for the modes that permit them. |
| Network | webfetch | Built in behind its own permission kind. |
| External tools | Namespaced MCP tools and explicit capability roles | Dynamic, local or remote, schema-validated and permission filtered. |
| Git | diff, review, restore, checkpoints, commit-subject generation | Native commands and UI; worktree orchestration is not complete. |
| Browser/search/notebooks | MCP-backed browser, notebook, and remote-search adapter roles | The external service owns automation, kernels, and credentials; DoMoCode owns the adapter, catalog, and policy boundary. |

The command registry is a separate surface from model tools. /review, /init,
/tree, /compact, /context, /memory, /undo, /redo, /timeline, /fork, /clone,
and other commands are local or server operations. The requested / tool
catalog must make that distinction visible instead of mixing slash commands
with callable tools.

## Audit of sibling harnesses

The audit covered the active checkout of each sibling, its local AGENTS.md,
source and documentation trees, license files, and feature-bearing
remote-tracking refs. Git was run inside each checkout; no sibling checkout
was edited. Feature branches were inspected with log and diff queries without
switching the active branch.

### Pi Agent Harness

Repository: [earendil-works/pi](https://github.com/earendil-works/pi), MIT.

Pi is the closest runtime ancestor. High-value capabilities found in the
active source and docs include:

- a normalized agent event stream distinct from provider wire messages;
- steering and follow-up queues, continue after tool errors, configurable
  parallel or sequential tool execution, tool preflight/postflight hooks, and
  terminate hints;
- session trees, branching, /tree, /fork, /clone, compaction, branch
  summarization, HTML export, replay, usage/cost accounting, and diagnostics;
- a model registry and provider composer spanning OpenAI Chat/Responses,
  Anthropic Messages, Gemini, Bedrock Converse, OpenAI-compatible gateways,
  Azure, Vertex, Cloudflare, GitHub Copilot, OpenRouter, xAI, and other
  adapters;
- API keys, OAuth, subscription-backed providers, custom providers, headers,
  usage/cost, provider-specific streaming, context overflow, and retry policy;
- a large extension system: custom tools, commands, shortcuts, message
  renderers, markdown transformers, entry renderers, dialogs, widgets,
  footers, autocomplete, model registration, dynamic tools, and session state;
- markdown-plus-frontmatter skills, keyword activation, skill discovery and
  package loading;
- themes with semantic colors, markdown/diff/syntax/thinking/bash colors,
  true-color and 256-color handling, configurable keybindings, and
  switchable TUI renderers;
- Gondolin, Docker, and OpenShell execution options, with provider auth kept
  outside the sandbox when appropriate.

Native Pi tools are the familiar file/shell/search set:
bash, read, write, edit, grep, find, and ls, with truncation, images, mutation
serialization, and render helpers.

Useful source/doc anchors are the
[agent package](https://github.com/earendil-works/pi/tree/main/packages/agent),
[coding-agent tools](https://github.com/earendil-works/pi/tree/main/packages/coding-agent/src/core/tools),
[provider guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/providers.md),
[extensions guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md),
[RPC protocol](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md),
[skills guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md),
and [containerization guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/containerization.md).

### OpenCode

Repository: [anomalyco/opencode](https://github.com/anomalyco/opencode), MIT.

OpenCode contributes the most complete provider-neutral server/tool
architecture in the audit:

- the llm package is schema-first and supports OpenAI Chat, OpenAI
  Responses, Anthropic Messages, Gemini, Bedrock Converse, and
  OpenAI-compatible providers with caching and normalized errors;
- the tool registry discovers built-ins, project tools, plugin tools, MCP
  tools, and model/provider-specific visibility; the same resolved set drives
  the tool definitions and prompt;
- built-ins include shell, read, glob, grep, edit, write, task, fetch, todo,
  search, skill, patch, question, and LSP, with experimental code mode and
  plan support;
- agents have primary and subagent modes such as build, plan, general, and
  explore; background tasks are resumable and return correlated results;
- MCP supports resources, templates, dynamic tools, authentication, OAuth
  callbacks, and permission filtering;
- LSP supplies diagnostics, definitions, references, implementations, call
  hierarchy, document symbols, and related code intelligence;
- snapshots, restore/revert/diff, Git worktrees, session retry, compaction,
  handoff, sharing, background jobs, server profiles, and remote workspace
  routing are first-class seams;
- plugins can supply tools/providers/commands/hooks, while skills are
  discovered from local and remote resources;
- the TUI has themes, theme switching, session inboxes, tool menus, image
  handling, and active work on background/image presentation.

See the [LLM package](https://github.com/anomalyco/opencode/tree/dev/packages/llm),
[tool registry](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/tool/registry.ts),
[task tool](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/tool/task.ts),
[MCP implementation](https://github.com/anomalyco/opencode/tree/dev/packages/opencode/src/mcp),
[LSP implementation](https://github.com/anomalyco/opencode/tree/dev/packages/opencode/src/lsp),
[snapshot service](https://github.com/anomalyco/opencode/tree/dev/packages/opencode/src/snapshot),
and [worktree service](https://github.com/anomalyco/opencode/tree/dev/packages/opencode/src/worktree).

### Kilo Code

Repository: [Kilo-Org/kilocode](https://github.com/Kilo-Org/kilocode), MIT
for the repository's open-source tree and its OpenCode-derived CLI.

Kilo is an OpenCode fork with a larger product surface:

- Code, Plan, Ask, Debug, and Review modes plus custom agents;
- Agent Manager with projects, task timelines, multiple sessions, worktrees,
  branch/diff review, setup scripts, promotion/handoff, remote sessions, and
  model/mode selection;
- orchestration experiments with planning, waves, subagents, and file-conflict
  avoidance;
- checkpoints, session export/import/portability, revert, Git review, and
  commit-message generation;
- indexing and memory services, indexing consent, model catalogs, autocomplete
  and ghost-text context, image attachments, terminal context, browser
  automation, and notebook integration;
- sandbox configuration, inheritance, network policy, process state, and
  platform-specific backends;
- Kilo Gateway device auth, model catalog/profile/balance surfaces, Codex
  refresh, reasoning metadata, and cloud/daemon/websocket session paths;
- retry backoff that can be cancelled by abort, model change, or model switch,
  plus explicit handling for empty provider responses.

The most relevant code is in the
[Agent Manager](https://github.com/Kilo-Org/kilocode/tree/main/packages/kilo-vscode/src/agent-manager),
[indexing and memory services](https://github.com/Kilo-Org/kilocode/tree/main/packages/kilo-vscode/src/kilo-provider),
[browser automation service](https://github.com/Kilo-Org/kilocode/tree/main/packages/kilo-vscode/src/services/browser-automation),
[notebook service](https://github.com/Kilo-Org/kilocode/tree/main/packages/kilo-vscode/src/services/notebook),
and the OpenCode-derived
[CLI core](https://github.com/Kilo-Org/kilocode/tree/main/packages/opencode/src).

### OpenHands

Repository: [OpenHands/OpenHands](https://github.com/OpenHands/OpenHands).
The checkout audited here is the Agent Canvas frontend and its MIT-licensed
supporting tree, not a license to copy the excluded enterprise/ tree.

OpenHands adds a backend and automation perspective:

- a backend registry with local, remote, cloud, health, authentication,
  switching, and conversation persistence;
- Agent Client Protocol (ACP) support so the UI can run OpenHands, Claude
  Code, Codex, Gemini, or another ACP-compatible agent through JSON-RPC over
  stdio;
- subscription login and API-key profile handling, including credential
  materialization into isolated agent environments;
- MCP management for stdio, HTTP, and SSE servers, OAuth2, health checks,
  credential redaction, validation, and test calls;
- browser, terminal, file editor, diff/commit, image upload, plan preview,
  question, confirmation, task tracking, and event-stream rendering;
- reusable skills, plugins, secrets, LLM/agent profiles, marketplaces, and
  onboarding;
- scheduled and webhook automations, run logs, activity export, suggested
  tasks, Slack/GitHub/Linear-style integrations, and backend-specific
  sandbox lifecycle;
- cloud conversation sharing, pause/resume, organizations, and sandbox
  management.

The key references are [architecture.md](https://github.com/OpenHands/OpenHands/blob/main/docs/architecture.md),
[ACP_AGENTS.md](https://github.com/OpenHands/OpenHands/blob/main/docs/ACP_AGENTS.md),
the [backend registry](https://github.com/OpenHands/OpenHands/tree/main/src/api/backend-registry),
[ACP service](https://github.com/OpenHands/OpenHands/tree/main/src/api/acp-service),
[MCP service](https://github.com/OpenHands/OpenHands/tree/main/src/api/mcp-service),
[automation service](https://github.com/OpenHands/OpenHands/tree/main/src/api/automation-service),
and [LLM subscription service](https://github.com/OpenHands/OpenHands/blob/main/src/api/llm-subscription-service.ts).

OpenHands demonstrates the most credible route to a Claude subscription:
let a supported Claude client own the subscription login and speak ACP, rather
than attempting to recreate a private subscription API inside DoMoCode.

## Branch audit

The active branch is only one view of each project. The following
non-active refs contained concrete feature work and were included in the
roadmap audit. A branch is evidence of an implementation direction, not a
promise that its API is stable or that its code is eligible for porting.

| Project | Feature-bearing ref checked | What it showed |
|---|---|---|
| Pi | [theme-selector](https://github.com/earendil-works/pi/tree/theme-selector), [switchable-tui](https://github.com/earendil-works/pi/tree/switchable-tui) | First-run themes and switchable terminal renderers. |
| Pi | [add-openai-background-requests](https://github.com/earendil-works/pi/tree/feat/add-openai-background-requests), [anthropic-token](https://github.com/earendil-works/pi/tree/anthropic-token) | Background Responses work and alternate Anthropic bearer-token auth. |
| Pi | [issue-6647-retry-summary-requests](https://github.com/earendil-works/pi/tree/fix/issue-6647-retry-summary-requests), [loadout](https://github.com/earendil-works/pi/tree/loadout) | Retry for compaction summaries and loadout/model/resource selection. |
| Pi | [better-approvals](https://github.com/earendil-works/pi/tree/better-approvals) | Project-trust and approval improvements. |
| OpenCode | [desktop-image-backgrounds](https://github.com/anomalyco/opencode/tree/desktop-image-backgrounds), [opencode-v2-theme](https://github.com/anomalyco/opencode/tree/opencode-v2-theme) | Image-backed UI presentation and native theme loading. |
| OpenCode | [nxl-acp-lifecycle](https://github.com/anomalyco/opencode/tree/nxl-acp-lifecycle), [session-handoff](https://github.com/anomalyco/opencode/tree/feature/session-handoff) | ACP lifecycle/permissions and session handoff. |
| OpenCode | [effect-dynamic-tools](https://github.com/anomalyco/opencode/tree/effect-dynamic-tools), [core-v2-background-agent](https://github.com/anomalyco/opencode/tree/feat/core-v2-background-agent) | Runtime-created tools and correlated background agents. |
| OpenCode | [provider-session-failures](https://github.com/anomalyco/opencode/tree/fix/provider-session-failures), [agent-skills](https://github.com/anomalyco/opencode/tree/feature/agent-skills) | Typed provider errors and Agent Skills support. |
| Kilo | [add-debug-orchestrator-agents](https://github.com/Kilo-Org/kilocode/tree/feat/add-debug-orchestrator-agents), [local-code-review-mode](https://github.com/Kilo-Org/kilocode/tree/feat/local-code-review-mode) | Wave planning, conflict avoidance, and local review. |
| Kilo | [agent-manager-global-worktree-storage](https://github.com/Kilo-Org/kilocode/tree/feat/agent-manager-global-worktree-storage), [session-portability](https://github.com/Kilo-Org/kilocode/tree/feat/session-portability) | Worktree-backed sessions and portable checkpoint/session state. |
| Kilo | [tui-auto-mode](https://github.com/Kilo-Org/kilocode/tree/feat/tui-auto-mode), [7796-rate-limit-cancel-during-backoff](https://github.com/Kilo-Org/kilocode/tree/fix/7796-rate-limit-cancel-during-backoff) | Auto-mode retry and cancellation during retry backoff. |
| Kilo | [empty-provider-response](https://github.com/Kilo-Org/kilocode/tree/fix/empty-provider-response), [enable-sandbox-feature-by-default](https://github.com/Kilo-Org/kilocode/tree/enable-sandbox-feature-by-default) | Empty-response recovery and default sandbox activation. |
| OpenHands | [acp-support](https://github.com/OpenHands/OpenHands/tree/openhands/acp-support), [acp-integration](https://github.com/OpenHands/OpenHands/tree/feature/acp-integration) | An ACP JSON-RPC server, event mapping, permissions, and end-to-end tests. |
| OpenHands | [planning-delegate](https://github.com/OpenHands/OpenHands/tree/feat/planning-delegate), [structured-thought](https://github.com/OpenHands/OpenHands/tree/feature/structured-thought) | Read-only plan/execute delegation and structured thought events. |
| OpenHands | [add-retry-for-mcp-client](https://github.com/OpenHands/OpenHands/tree/ht/add-retry-for-mcp-client), [paused-sandbox-status](https://github.com/OpenHands/OpenHands/tree/paused_sandbox_status) | MCP retry behavior and truthful paused/stopped sandbox status. |

## What the audit means for DoMoCode

The high-value common pattern is not “copy every feature.” It is a set of
seams:

| Seam | Evidence | DoMoCode position |
|---|---|---|
| Normalized provider events | Pi, OpenCode, ACP | AgentEvent and ServerEvent exist; provider-neutral input is next. |
| Late-bound tools | Pi, OpenCode, MCP, plugins | The registry is late-bound, but the client cannot yet inspect it in one catalog. |
| Delegated work | Pi child sessions, OpenCode tasks, Kilo orchestration, OpenHands tasks | DoMoCode has resumable child sessions; workflow composition is next. |
| Plan/research/synthesis | OpenHands plan delegation, Kilo orchestrator, OpenCode plan/explore agents | DoMoCode has plan mode, not a durable research workflow. |
| Retry/error taxonomy | Pi, OpenCode, Kilo, OpenHands | DoMoCode has ten-attempt retry and classification; long-scale recovery is next. |
| Subscription auth | Pi provider auth, OpenHands ACP, Kilo gateway | No direct subscription adapter exists. ACP is the safe feasibility path. |
| Snapshots and isolation | OpenCode snapshots/worktrees, Kilo worktrees/sandbox, OpenHands backends | DoMoCode has shadow-Git and local sandboxes; portable backends are next. |
| Terminal polish | Pi themes/TUI, OpenCode image backgrounds/themes, Kilo UI | DoMoCode has theme values and a cell renderer; blank-cell painting and marquees are next. |
| Automation | OpenHands automations, Kilo cloud sessions | DoMoCode is currently local and manually driven. |

Native code is appropriate for the agent loop, safety policy, session model,
tool catalog, and terminal UX. Browser control, remote MCP, notebook kernels,
and provider-specific subscription clients should first be adapters through
MCP or ACP. This keeps the core small, avoids copying non-MIT code, and lets
the user choose the external capability.

## Roadmap

Phases 0–21 below preserve the existing roadmap and its completion status.
The new phases are deliberately ordered by dependency. A phase is not
complete until it has focused unit tests, a headless integration test where
applicable, and a release build under Swift 6.3.

### Completed phases

| Status | Phase | Preserved scope |
|---|---|---|
| [x] | 0 — Skeleton | SwiftPM targets, strict concurrency/safety settings, core JSON/schema/error/JSONL vocabulary, and CI. |
| [x] | 1 — Talk to LiteLLM headlessly | Streaming transport, SSE, tool-call assembly, usage/cost, model catalog, retries, subprocess seam, and headless tools. |
| [x] | 2 — The agent loop | Pure turn loop, tool dispatch, truncated-call refusal, steering/follow-up queues, and awaited event sinks. |
| [x] | 3 — Persistence and harness | Append-only session trees, context, compaction, branch summaries, trust, resume, fork, and session selection. |
| [x] | 4 — Terminal | POSIX input/lifecycle, terminal oracle, inline renderer, components, editor, Markdown, autocomplete, REPL, and tool renderers. |
| [x] | 5 — Polish | [x] 5a truth/plumbing; [x] 5b command layer; [x] 5c dialogs, themes, and client hands; [x] 5d terminal-native polish. |
| [x] | 5.5 — Inline images, input half | User attachments and tool-returned image blocks through the normalized message seam. |
| [x] | 6 — Headless HTTP/SSE runtime server | Hummingbird REST/SSE server, broadcast sink, authentication, session routes, permissions, status, and force-clear. |
| [x] | 7 — Full-screen widget TUI | Alternate screen, cell buffer, layout tree, focus, overlays, client/server transport, two-pane UI, and selection. |
| [x] | 7.5 — Inline images, display half | Kitty/iTerm2 encoding, capability detection, dimensions, and image placement in both renderers. |
| [x] | 8 — Permission engine, then MCP | [x] 8a policy; [x] 8b server/client approval; [x] 8c stdio MCP; [x] 8d integration and hardening. |
| [x] | 8.5 — Hardening and quality of life | Client lifecycle, reconnects, sanitization, tool state, clipboard/selection, scrolling, error surface, retries, and stream idle guard. |
| [x] | 9 — Steering, queues, and run control | Mid-run steering, delivery modes, cost ceiling, no-progress guard, and server/client queue state. |
| [x] | 10 — Context engineering | Compaction recovery, cross-provider overflow detection, pruning, spill-to-disk, /compact, and /context. |
| [x] | 11 — Mutable tool set and tool suite | Per-request resolution, todo, question, webfetch, glob, finish, background process, edit strategies, and MCP refresh. |
| [x] | 12 — Git facade, diff, and review | Non-interactive Git policy, session-start HEAD, diff sources, review UI, restore, and commit subjects. |
| [x] | 13 — Checkpoints and undo | Shadow-Git snapshots, append-only history actions, conflict-safe revert, undo/redo, timeline, fork, and clone. |
| [x] | 14 — Agents, personas, and plan mode | Trusted Markdown profiles, build/plan modes, model/reasoning/permission overrides, plan files, and plan_exit. |
| [x] | 15 — Subagents | Child sessions, foreground/background tasks, resumable task IDs, depth limits, permission bubbling, and navigation. |
| [x] | 16 — LSP and code intelligence | Compiler diagnostics, pooled LSP, push/pull diagnostics, post-edit error context, and trusted auto-format. |
| [x] | 17 — Memory and recall | Session recall and redaction-checked, byte-budgeted project memory outside the checkout. |
| [x] | 18 — Sandboxing and permission hardening | Fail-closed Seatbelt/bubblewrap, environment scrubbing, project policy tightening, and process-path coverage. |
| [x] | 19 — PTY and interactive terminal | Server-owned PTYs, replay/attach, bounded VT projection, inline interactive terminal, cancellation, and sandbox reuse. |
| [x] | 20 — Export, replay, and scriptability | Markdown/HTML export, /copy, trajectory replay, and resumeable replay branches. |
| [x] | 21 — Split-footer render mode | Scrollback transcript, measured DECSTBM footer, OSC 133 boundaries, mini mode, resize, and cleanup. |

### Planned phases

#### Phase 22 — MIT source compliance and dependency audit — P0 — complete

- [x] Produce a machine-readable inventory of every direct and transitive
  package in Package.resolved, its GitHub URL, exact license, copyright,
  SPDX identifier, and whether it is runtime or test-only. Non-MIT package
  licenses are allowed; their notices must travel with the deliverable.
- [x] Inventory every copied or derived source file, verify its exact
  upstream path and commit, and preserve SPDX/copyright headers. Approved
  permissive source licenses, including MIT and Apache-2.0, remain eligible
  when the exact provenance is recorded; unreviewed, proprietary, and
  PolyForm-derived source remains ineligible. Keep non-MIT package
  dependencies as separately noticed dependencies rather than misclassifying
  them as source violations.
- [x] Add a repeatable CI admission check for new code: approved permissive
  source provenance, no proprietary/PolyForm subtree, no secrets, and a
  matching NOTICES.md entry. Add a separate package-license check that permits
  approved non-MIT dependencies from public GitHub.
- [x] Define provider, backend, workflow, tool-catalog, adapter, extension,
  and theme protocols without baking LiteLLM, macOS, JSONL, or the
  full-screen client into the abstractions.

#### Phase 23 — TUI theme contract, divider, marquees, and image thumbnails — P0 — complete

- [x] Make ThemePalette.background a real full-page paint contract. The
  alternate-screen frame must fill every cell, including blank rows and
  spaces around short components, with the selected background SGR. inherit
  remains an explicit opt-out; it must not be the accidental default that lets
  a desktop terminal background image show through.
- [x] Draw a theme-colored vertical divider between the sidebar and main
  content. Derive its column from ClientLayout so hit testing, selection,
  width measurement, and the visible divider cannot disagree.
- [x] Render terminal image blocks as bounded thumbnails by default. Start
  with a configurable maximum of 40 terminal columns by 12 rows, clamp both
  dimensions to the available content pane, preserve aspect ratio using the
  terminal's cell/pixel geometry, and never let an image displace the footer,
  sidebar, or surrounding transcript. An explicit user action may open a
  larger view; ordinary tool output must remain layout-safe.
- [x] Replace right truncation of the bottom status/control line with a
  deterministic horizontal marquee. Keep critical controls discoverable,
  pause at both ends, reset predictably on state changes, and make the clock
  injectable so screen-oracle tests do not depend on wall time. Apply the same
  contract to the full-screen and mini footer controls where they scroll.
- [x] Add pointer hover state to the sidebar. When a hovered session label
  exceeds the sidebar width, marquee the label within its row; do not scroll
  unrelated rows or alter the stable session marker/id columns.
- [x] Test blank-cell background coverage, stale-cell clearing, divider
  placement, thumbnail caps, aspect-ratio preservation, image resize and
  fallback behavior, true-color/indexed-color fallback, marquee timing,
  hover enter/exit, and narrow terminals with the existing cell oracle and
  real-PTY tests on compatible Kitty/iTerm2-style terminals.

The current theme value type and dark/light palettes are Phase 5c
foundations. This phase is the missing renderer/layout behavior, not a claim
that the existing theme work was absent. Phase 7.5 established image
encoding, capability detection, and placement; this phase adds the
layout-safe thumbnail policy.

#### Phase 24 — Live tool catalog, lifecycle hooks, and remote MCP — P0 — complete

- [x] Pressing / in the full-screen prompt opens a tool catalog. Keep slash
  commands available through their existing completion path, and provide an
  unambiguous /tools alias for keyboards or clients that prefer a command.
- [x] Add a server/client tool-catalog route backed by the same late-bound
  resolver used for the next model request. Show every currently callable
  built-in and MCP tool with name, short description, source, schema summary,
  permission state, and the reason an otherwise-known tool is hidden.
- [x] Refresh the catalog when a session changes mode/model, permissions
  change, or an MCP tools/list_changed notification arrives. The catalog
  must never advertise a tool that the model cannot receive on the next
  request.
- [x] Add a deterministic tool lifecycle around built-in, MCP, ACP, and
  adapter-backed tools: resolve, preflight, permission, invoke, result,
  postflight, cancellation, and failure. Hooks may observe, reject, or add
  safe metadata, but may never silently widen permissions or mutate a
  committed tool result. Keep ordering, idempotence, redaction, and hook
  timeouts explicit.
- [x] Extend MCP beyond today's stdio client to remote HTTP/SSE or
  streamable-HTTP servers. Add capability negotiation, reconnect/backoff,
  OAuth or other credential references, resources, resource templates,
  health/test calls, network policy, and secret redaction. Remote MCP must
  enter the same permission and tool-catalog path as local MCP.
- [x] Add focused parity tools in priority order: a canonical apply_patch
  or patch tool with the existing mutation safety; websearch behind an
  injectable provider or MCP; MCP resource/template inspection; and a skill
  invocation tool for already trusted skill resources.
- [x] Add browser, notebook, and remote search adapter roles through MCP before
  considering native implementations. A server may declare `adapterKind` as
  `browser`, `notebook`, or `remoteSearch`; the resulting adapter view remains
  schema-validated, cataloged, and permission-gated like any other MCP tool.
- [x] Defer first-class worktree/session actions to the tool and command
  vocabulary until Phase 28 supplies their safety model. The current phase
  deliberately exposes no convenience path that can bypass permission,
  checkpoint, or approval policy.
- [x] Preserve parallel dispatch, sequential overrides, per-turn snapshots,
  schema validation, and stable registration order. Test tool visibility in
  build, plan, ask, debug, review, headless, child, denied, local-MCP,
  remote-MCP, and MCP-refresh states. Test lifecycle hook ordering,
  cancellation, timeout, and permission non-escalation.

The audit found that DoMoCode already has more of the OpenCode/Pi tool
surface than the old README implied. This phase makes it inspectable and
fills only the high-value gaps.

#### Phase 25 — Ask, debug, review, research, plan, execute, and synthesize workflows — P0 — complete

Workflow UI target: provide a dedicated full-screen workspace rather than folding
workflow state into the ordinary transcript view. The initial layout has phases in
a left pane and the selected phase's agent content on the right. Enter drills into
a phase; the left pane then lists that phase's agents, and the right pane follows
the selected agent's live content. Escape returns to the parent phase list. This
is the interaction model to preserve when the durable workflow records below land.

- [x] Add a durable workflow definition and run record. A workflow is a
  sequence or DAG of named stages with a tool policy, model/profile,
  context inputs, output artifact, budget, timeout, cancellation policy, and
  approval boundary.
- [x] Ship a Claude-Code-like terminal experience without copying proprietary
  implementation: /research gathers evidence, /plan writes a reviewable
  plan, /execute performs approved work, and /synthesize produces the final
  answer. Existing plan mode remains the safety boundary.
- [x] Add explicit Ask, Debug, and Review modes alongside Build and Plan.
  Ask is read-only question/research work; Debug emphasizes reproduction,
  isolation, test execution, and evidence; Review is a read-only diff,
  checkpoint, or worktree audit that produces findings with severity,
  locations, evidence, and suggested fixes. Each mode gets a named profile
  containing its prompt, model, tool visibility, permission policy, budget,
  and output contract.
- [x] Research stages use read-only tools by default and can fan out to
  child sessions for repository search, web/MCP search, LSP inspection, and
  document comparison. Each result carries source/session provenance and an
  untrusted-data marker.
- [x] Plan stages produce a stable .domocode/plans/<workflow>.md or
  equivalent artifact with assumptions, alternatives, affected files,
  commands, risks, and acceptance tests. A user can edit or reject it before
  execution.
- [x] Execution stages reuse checkpoints, permissions, sandboxing, steering,
  PTYs, and child-session task IDs. A failed or cancelled stage can resume
  without duplicating already committed artifacts.
- [x] Synthesis stages combine stage outputs, cite their evidence, distinguish
  observed facts from inference, and return through the normal assistant
  response structure. The workflow itself must be exportable and replayable.
- [x] Add serial/parallel DAG tests, mode-policy tests for Ask/Debug/Review,
  approval tests, cancellation tests, failure/resume tests,
  prompt-injection tests, and a complete research-to-synthesis end-to-end
  test.

#### Phase 26 — Long-scale retry and LLM-assisted failure recovery — P0 — complete

The implementation has ten configured retry attempts, exponential backoff,
jitter, Retry-After, a five-minute sleep budget, a shorter pre-connect budget,
visible retry notices, and a bounded read-only diagnostic recovery turn.

The target state is:

~~~text
LiteLLM response
  ├─ service unavailable / transient overload
  │    └─ bounded backoff, at most the configured ten-attempt ceiling
  ├─ 404 / model or route not found
  │    └─ fail promptly with an actionable configuration error
  └─ any other non-cancellation error
       ├─ redact and persist a safe diagnostic envelope
       ├─ ask an available connected LLM to interpret it once
       ├─ permit only read-only diagnostic tools by default
       └─ map the result back to DoMo's normal assistant/error events
~~~

- [x] Rename or clearly document the count semantics as maxAttempts versus
  maxRetries; never silently exceed ten network attempts. Keep the
  pre-connect cap separate from a request that has proven the gateway alive.
- [x] Move from a sleep-only budget to an explicit wall-clock retry budget
  that accounts for Retry-After, connection time, stream idle time, and
  backoff. Make the longer time scale configurable and cancellable. A model
  change, abort, shutdown, or user retry must stop the wait immediately.
- [x] Continue to retry only classified transient failures: rate limits,
  service unavailable/overload, transient 5xx, and transport failures.
  Never hide authentication, quota, context-overflow, malformed-request, or
  404 failures behind ten waits.
- [x] After the normal retry path is exhausted, or immediately for a
  non-transient response, create a bounded diagnostic sub-turn when a usable
  connected model is available. Pass the redacted status/body, provider
  metadata, model alias, retry history, and safe session context as
  untrusted data—not instructions.
- [x] Give that sub-turn read-only harness tools: model catalog, configuration
  diagnostics, tool catalog, recent sanitized event history, session status,
  filesystem/log inspection within policy, and provider capability metadata.
  Mutation, credential changes, shell execution, and new network actions
  require a separate explicit approval.
- [x] Prevent recursion: a diagnostic turn cannot invoke diagnostic recovery,
  cannot spend the entire retry budget again, and has a strict token/time
  budget. If no alternate model or route is available, return the original
  classified failure with a useful remediation.
- [x] Persist a typed recovery envelope so text, JSON, SSE, replay, and the UI
  agree about the original error, attempted remedies, final diagnosis, and
  whether the user approved an action. Redaction happens before persistence,
  display, or model input.

#### Phase 27 — Provider profiles, fallback, explicit adapters, and ACP — P1 — complete

- [x] Introduce a provider protocol around the existing normalized
  AssistantMessage, tool calls/results, usage, thinking/reasoning,
  stop-reason, error, retry, and permission events. Keep LiteLLM as the
  first adapter, not the protocol itself.
- [x] Keep LiteLLM as the OpenAI-compatible Chat adapter and add hand-written,
  lenient HTTP adapters for OpenAI Responses and Anthropic Messages. Consider
  Gemini and Bedrock only after the source/license admission gate; provider
  breadth is not a reason to accept opaque or unreviewed code.
- [x] Add named provider profiles containing endpoint, model, credential
  reference, capabilities, usage/cost policy, cache controls, context-window
  metadata, and provider-specific error normalization. Keep secrets outside
  profiles and make profiles inspectable without exposing credential values.
- [x] Add ordered, permissioned provider fallback routes and a circuit-breaker
  state. Fallback is allowed only for pre-commit transient failures or an
  explicitly approved route change; never replay a committed stream or tool
  call automatically. A model/provider switch cancels backoff and rebuilds
  the correct tool/schema projection.
- [x] Ship explicit adapter tooling: an adapter registry and
  `domo adapters list`, `domo adapters doctor`, and handshake/test surfaces
  (or their equivalent API). Show adapter kind, capabilities, health,
  credential requirements, source/license metadata, and supported event
  mappings. Provider, MCP, ACP, backend, browser, and notebook integrations
  must be adapters with the same permission and redaction contract.
- [x] Make Agent Client Protocol (ACP) a first-class adapter boundary for
  external agents. Support bounded stdio JSON-RPC lifecycle, capabilities,
  permissions, tool calls, task/plan events, cancellation, resume, and
  correlation IDs rather than treating ACP as a Claude-only special case.
- [x] Investigate direct use of a Claude subscription through a supported
  Claude Code/Claude Agent ACP or equivalent stdio client. The external
  client owns login, subscription entitlement, and proprietary protocol
  details; DoMoCode launches it as a bounded process and does not scrape
  tokens, reproduce private endpoints, or copy proprietary code.
- [x] Map ACP events into DoMo's current response structure: text deltas,
  thinking, tool calls, tool results, images, permission requests, plan/task
  events, usage, retry, cancellation, and errors. Preserve correlation IDs
  and append the normalized form to JSONL/SSE.
- [x] If the supported Claude client or subscription login is unavailable,
  report the adapter as unsupported and use LiteLLM or another configured
  provider. The direct subscription path remains explicitly unsupported until
  login, streaming, tool use, permissions, cancellation, resume, and error
  mapping pass without an API key.

This is the only technically credible subscription path found in the audit.
Pi has provider-specific OAuth/subscription code and OpenHands has an ACP
integration; neither justifies reimplementing a private subscription API.

#### Phase 28 — Portable execution, worktrees, conflict-aware orchestration, and backend lifecycle — P1 — complete

- [x] Separate workspace/backend selection from the current macOS/Linux
  process implementation. Retain fail-closed local Seatbelt/bubblewrap and
  add optional adapters for user-installed Docker, Gondolin, OpenShell, or a
  remote worker; do not vendor a binary or add an unreviewed SDK. A non-MIT
  SwiftPM library is allowed when its public GitHub source and notices are
  recorded.
- [x] Add session-scoped worktrees with safe branch naming, setup scripts,
  checkpoint integration, diff/review, promotion, cleanup, and conflict
  reporting. A child agent must never accidentally mutate its parent's
  worktree.
- [x] Add conflict-aware orchestration for parallel workflow stages: assign
  declared file/resource ownership, schedule non-overlapping waves, detect
  unexpected overlap before mutation, and require an explicit merge or
  promotion step for competing changes. Preserve per-agent checkpoints and
  make unresolved conflicts visible to the user and the parent workflow.
- [x] Make sandbox policy cover shell, background processes, MCP, LSP,
  formatter, Git, PTY, browser, notebook, and provider subprocesses through
  one launch-plan contract.
- [x] Add a backend registry and lifecycle manager with health, capability,
  authentication, start/stop, pause/resume, reconnect, cleanup, and truthful
  state events. A paused or stopped backend must not be presented as a
  healthy running session, and an adapter must report when required isolation
  is unavailable.
- [x] Add platform adapters incrementally, with capability negotiation rather
  than compile-time assumptions. Every backend has a testable refusal when
  its required isolation cannot be established.

The optional backend boundary is `ExternalCommandBackend`: a user-installed
command receives one JSON request and returns one JSON result. Its health
handshake must advertise capabilities and prove isolation before the backend
can be selected. `domo adapters list` and `domo adapters doctor` expose the
Docker, Gondolin, OpenShell, and remote-worker slots without pretending that a
missing command or an unverified sandbox is usable.

#### Phase 29 — Durable jobs, session handoff, and local automation — P1 — complete

- [x] Promote child sessions and background agents into a durable job manager
  with job records, correlation, progress, cancellation, retry, notification,
  event cursors, ownership, and restart recovery. Reuse the existing session
  tree and task IDs, and make job state truthful across headless, inline, and
  full-screen clients.
- [x] Add explicit session handoff: attach another client, continue in a
  different worktree/backend/provider, or transfer a plan and artifacts to a
  new session without losing provenance.
- [x] Replace the current single-client-first server assumption with safe
  multi-client mirroring, resumable event cursors, conflict-free writes, and
  permission prompts routed to one authoritative owner.
- [x] Add opt-in local automation after the job/security model is complete:
  schedules, manual/CLI triggers, filesystem or repository triggers, and
  optional authenticated webhooks. Automations must run with a named
  profile, bounded budget, explicit workspace, sandbox, secret scope,
  cancellation policy, and audit trail.
- [x] Provide machine-readable activity logs, run export, failure replay,
  and a clear distinction between a user prompt, a scheduled trigger, and
  a child-agent result.

OpenHands supplies the automation model; OpenCode and Kilo supply the
handoff, server, and worktree patterns. DoMoCode should adopt the state
contracts, not their web application or cloud assumptions.

#### Phase 30 — Safe resource packages and permissioned out-of-process extensions — P1 — complete

- [x] Allow GitHub-hosted, MIT-licensed skills, commands, and themes to be
  fetched into a content-addressed, reviewable cache. Installation is data
  loading, not arbitrary code execution. Pin commits, record license and
  provenance metadata, validate schemas, and require explicit trust before a
  code-bearing resource can affect a session.
- [x] Add theme import/export and live reload with a fallback palette,
  background coverage, semantic colors, accessibility contrast checks, and
  terminal capability negotiation.
- [x] Add a permissioned out-of-process extension host. Extensions must have
  a manifest, versioned protocol, declared capabilities, resource limits,
  executable/source/license metadata, lifecycle health, and explicit user or
  project approval. Use MCP, ACP, or a compatible JSON-RPC adapter boundary;
  do not load arbitrary code into the DoMoCode process or let an extension
  bypass tool permissions.
- [x] Add file watching for trusted resource and workspace changes, with
  debounce, cancellation, and a prompt-visible reload notice. A changed
  skill, command, theme, or tool must not silently mutate a running turn's
  snapshot.

#### Phase 31 — Indexing, richer code intelligence, browser, and notebook — P2 — complete

- [x] Add an index provider protocol and an incremental file watcher. Start
  with symbol/LSP/search indexes; add semantic embeddings only when an
  acceptable SwiftPM library with a reviewed license and provider path are
  available.
- [x] Extend DoMoLSP and the / catalog with definitions, declarations,
  references, implementations, document/workspace symbols, call hierarchy,
  diagnostics, rename/related locations where the server supports them, and
  repository navigation. Keep each operation permission-aware, cancellable,
  bounded, and usable by Ask, Debug, Review, and research workflows.
- [x] Add incremental symbol and dependency indexes with explicit freshness
  state, invalidation, ignored paths, and a graceful search-only fallback.
  Never present stale index results as current source facts.
- [x] Integrate browser automation and notebook kernels through MCP/ACP first,
  including screenshot/image results, approvals, sandboxing, and output
  truncation. A native implementation needs a demonstrated GitHub/SPM
  dependency path and a platform test matrix.
- [x] Add provider/model capability checks for images, long context, tools,
  reasoning, and background requests without hardcoding a provider name into
  the agent loop.

Browser, notebook, and remote-search behavior remains an explicitly configured
MCP/ACP capability. DoMoCode carries image results, approvals, cancellation,
output bounds, and permission metadata across that boundary; it does not ship
a native browser or notebook runtime.

#### Phase 32 — TUI interaction polish, model discovery, and help — P1 — complete

- [x] Give every modal, dialog, palette, and selector a shared outlined frame
  that always paints its bottom border, including on first render, resize, and
  content overflow. Cover the frame and stale-cell behavior with cell-oracle
  and PTY tests.
- [x] Generalize the horizontal marquee to every focused or selected label that
  exceeds its available area, including command-palette entries, sessions,
  theme/model selectors, and workflow lists. Preserve stable columns, pause at
  both ends, and reset predictably after selection, resize, or content changes.
- [x] Make the command palette's theme action a `Select Theme` command that
  opens its own outlined, navigable dialog. Include the existing light/dark
  themes plus Gruvbox dark/light and Solarized dark/light, and persist the
  selected theme as the active default for every session until changed.
- [x] Make `Switch model` query and refresh the configured LiteLLM `/models`
  endpoint, merge endpoint results with configured aliases, show loading and
  failure states, and let the user select any returned model. Persist the
  selected model in trusted user settings so it applies across sessions without
  leaking credentials.
- [x] Add a `Help` command-palette entry that opens an outlined, scrollable
  dialog. Generate its shortcut list from the canonical keymap, describe all
  registered commands, and explain how to trigger and navigate workflows.
- [x] Change mode cycling from `Ctrl+Tab` to `Shift+Tab` to avoid iTerm2's
  `Ctrl+Tab` handling. Update input routing, footer hints, palette/help text,
  and terminal regression tests while retaining `Tab` for content-to-sessions
  pane navigation.
- [x] Make the tool catalog directly usable from the prompt: pressing `Tab` or
  `Enter` on a selected tool inserts its canonical slash-command form into the
  editor, while `Enter` in the prompt submits a command such as `/read foo.txt`.
  Resolve the catalog entry, validate and parse its arguments, then invoke the
  corresponding tool on the normal permission, cancellation, error-result, and
  session-recording paths. Unknown commands and malformed arguments must remain
  prompt-visible errors rather than becoming model turns.

The phase is complete: the same keymap and command metadata drive the
footer, palette, and Help dialog, and every new state is covered by component,
cell-oracle, and PTY tests where terminal bytes or lifecycle matter.

#### Phase 33 — Copilot-compatible .github prompt resources — P1 — complete

- [x] Discover `.github/skills/*/SKILL.md`, `.github/skills/*.md`,
  `.github/agents/*.md`, and `.github/commands/*.md` as a fourth trust-gated
  project resource root, so a repo vendoring a GitHub Copilot-style resource
  pack works in place with no copies or symlinks. `.github/` loads first and
  every loader is last-write-wins, so same-named resources in `.domocode/`,
  `.claude/`, or `.agents/` override the vendored pack per-repo without
  editing it. User-scope resources stay below the project layer, unchanged.
- [x] Extend the trust gate's candidate list with
  `.github/{commands,skills,agents}` so the new root cannot inject prompt
  content without an explicit trust decision. A `.github/` holding only CI
  workflows or templates never prompts: only the three resource
  subdirectories are consulted, and absent or empty ones do not count.
- [x] Accept the `<name>.agent.md` agent filename convention: the `.agent`
  suffix is stripped from the fallback profile name, and an explicit `name:`
  frontmatter key still wins over any filename.
- [x] Parse `disable-model-invocation` skill frontmatter (kebab, camel, and
  snake spellings; boolean, numeric, and quoted truthy scalars; a present but
  unparseable value fails closed). A disabled skill's body is never
  auto-injected on a keyword match and is not served by the model-facing
  `skill` tool; the skill stays in the `<available-skills>` catalogue marked
  not model-invocable and remains user-invocable as its promoted command.
- [x] Promote every loaded skill to a user-invocable `/name` prompt command,
  matching the harnesses that expose skills as slash commands. The skill's
  `argument-hint` surfaces on the command, and promotion never shadows:
  built-ins and real command files win name collisions. A promoted command
  injects the skill body verbatim with the user's words appended — skill
  prose is not a command template, so `$1` substitution, inline shell, and
  `@file` inclusion do not run over it — and the invoked skill excludes
  itself from that resolution's keyword injection, so a fresh invocation
  never delivers the body twice. A `/name` typed into an in-flight run
  steers as a plain user message against the run's already-fixed system
  prompt, which may still carry the body from an earlier keyword match.
- [x] Parse `tools:` frontmatter onto skills and agent profiles as a verbatim
  allow-list — sequence or scalar names preserved unchanged (except a scalar
  spelled empty, `~`, or `null` — even quoted — which reads as the empty
  list; a tool literally named `null` needs list form), a truthy-flag mapping
  reduced to its allowed names, and `nil` only when the key is absent so
  "undeclared" stays distinct from every declared form, which fails closed.
  Stored as data only; wiring it into the runtime tool-visibility filter is a
  follow-up, the same parsed-before-enforced path permission rules took.

The phase is complete: discovery, trust gating, precedence, and both new
frontmatter keys are covered by loader and trust-store tests. A repo with no
`.github` prompt resources gains no new resource root; the `.agent` filename
convention and both frontmatter keys apply uniformly in every resource root,
so a pre-existing `<name>.agent.md` profile is now addressed without the
suffix and skills already declaring the new keys pick up their meaning.

#### Phase 34 — Gateway ceiling discovery, timeout continuation, unified palette — P1 — complete

- [x] Append an adaptive character-limit sentence to the last user message of
  every run, on the wire and in the session file, and discover the gateway's
  real ceiling from what comes back: probe above the current ceiling on a
  cadence, promote a probe that returns a response at least as long as the old
  ceiling, binary-search downward from a probe that fails, and walk the ceiling
  down after two consecutive ordinary failures. Learned per model alias in
  `<configDir>/response-limit.json` under an atomic, locked, merging write, so
  two `domo` processes cannot erase each other's learning. A cancelled run is
  never evidence. On by default; see [Configuration](#configuration).
- [x] Re-ask a run the gateway timed out on with
  `Refer to previous context and continue.`, up to ten times, rebuilding the
  context each attempt so the model continues from the partial turn the file
  now holds. Strictly downstream of overflow recovery, provably terminating,
  and restricted to genuine timeouts — 408/504/522/524 or a transport failure
  whose prose says so — so a rate limit, an overflow or a cancellation never
  enters it. Each attempt emits a run-scoped `gateway_continue` notice.
- [x] List commands, tools and agents together in both the `^P` palette and the
  `/` popup, each row labelled with the text it will insert, and insert by
  REPLACING the whitespace-delimited token under the caret rather than
  appending to the draft. That one change is what makes `/` + `/read` insert
  `/read` instead of `//read`, makes a bare-name entry eat the `/` that opened
  the list, and leaves the words on either side of the caret intact. New
  `GET /agents` route projects agent profiles without putting a system prompt
  on the wire.

The phase is complete in both the full-screen client and the inline REPL, with
the response-limit arithmetic, the continuation loop's termination, the timeout
classifier and all four insertion rules covered by tests.

## Retry and provider behavior today

The current retry and recovery path behaves as follows:

- DOMOCODE_MAX_RETRIES defaults to 10 for classified retryable failures. The
  historical name counts retries after the initial request, but the effective
  network budget is capped at ten total requests; zero means one request and no
  retry.
- exponential backoff starts at 1 second, caps at 60 seconds, and uses
  jitter; Retry-After is honored within the cap;
- the total scheduled sleep budget defaults to 300 seconds;
- a six-hundred-second wall-clock budget covers connection, committed-stream,
  backoff, and retry time; DOMOCODE_RETRY_WALL_CLOCK_MS=0 disables that
  cross-attempt bound;
- a request that never receives a response head has a smaller pre-connect
  retry cap, while a gateway that has answered earns the full request budget;
- 429/5xx, transient transport failures, and narrowly matched LiteLLM
  overload/service-unavailable bodies are retryable;
- authentication, quota, context overflow, malformed responses, and 404 are
  not retried;
- a failure after a committed 2xx stream is surfaced rather than replayed,
  because replaying may duplicate tool calls or side effects;
- retry notices are visible in the full-screen status line, inline transcript,
  and headless stderr;
- after an exhausted transient retry path, or immediately for a non-transient
  failure, DoMo persists a redacted recovery envelope and may run one bounded
  diagnostic sub-turn with read-only tools. Diagnostic turns cannot recurse,
  mutate credentials, execute shell commands, or start new network actions.

## Configuration

Precedence is CLI flag, environment, trusted project settings, user settings,
then built-in defaults. Current environment names:

| Variable | Purpose |
|---|---|
| DOMOCODE_BASE_URL | Current LiteLLM/OpenAI-compatible base URL. |
| DOMOCODE_API_KEY | Credential variable value; falls back to LITELLM_API_KEY and OPENAI_API_KEY. |
| DOMOCODE_MODEL | Current model alias. |
| DOMOCODE_SMALL_MODEL | Optional compaction model. |
| DOMOCODE_REASONING_EFFORT | Current reasoning effort override. |
| DOMOCODE_TIMEOUT_MS | Overall request timeout. |
| DOMOCODE_STREAM_TIMEOUT_MS | Committed-stream idle timeout. |
| DOMOCODE_MAX_RETRIES | Historical retry-count setting; the effective ceiling is ten total network attempts including the initial request. |
| DOMOCODE_RETRY_BASE_MS | Current initial backoff. |
| DOMOCODE_RETRY_MAX_MS | Current backoff ceiling. |
| DOMOCODE_RETRY_BUDGET_MS | Current scheduled-sleep budget. |
| DOMOCODE_RETRY_WALL_CLOCK_MS | Wall-clock budget for the request, response stream, backoff, and all retries; zero disables this bound. |
| DOMOCODE_CONFIG_DIR | Settings, trust, commands, skills, and project memory root. |
| DOMOCODE_SESSION_DIR | Session JSONL and prompt-history root. |
| DOMOCODE_RESPONSE_LIMIT | `0`/`false` disables the adaptive response-character limit; on by default. |
| DOMOCODE_RESPONSE_LIMIT_CHARS | Starting character ceiling advertised to the model (default 500). |
| DOMOCODE_RESPONSE_LIMIT_JUMP_PCT | How far above the ceiling a probe may reach, in percent (default 10). |
| DOMOCODE_RESPONSE_LIMIT_PROBE_EVERY | Probe cadence: one probe every N prompts (default 4). |
| DOMOCODE_GATEWAY_CONTINUE | `0`/`false` disables gateway-timeout continuation; on by default. |
| DOMOCODE_GATEWAY_CONTINUE_MAX | Continuation attempts per run (default 10, hard cap 100). |

The settings file currently supports model overrides, compaction, context
window metadata, trusted auto-format, MCP servers, interpolation, the adaptive
response limit, and gateway continuation. Project settings cannot introduce
credentials or widen permissions. Any future provider/profile/workflow setting
must preserve those redaction and trust rules.

### Adaptive response-character limit

Some gateways refuse to return a response over an undocumented size, and say so
only by failing. DoMoCode appends a limit sentence to the last user message of
each run — on the wire and in the session file, so the transcript records what
the model was actually asked — and then *learns* the real ceiling:

- the ceiling starts at `thresholdCharacters` and is remembered **per model
  alias** in `<configDir>/response-limit.json`;
- every `probeEvery`-th prompt advertises a probe up to `jumpPercentage` above
  the ceiling. A probe that comes back with a response at least as long as the
  old ceiling promotes the probe value to the new ceiling;
- a probe that fails records that value as known-bad and the next probe is the
  midpoint between the ceiling and it, so the search converges rather than
  retrying the same failing number;
- two consecutive ordinary failures walk the ceiling down 10%, floored at
  `minimumThreshold`. A cancelled run teaches it nothing.

~~~json
{
  "responseLimit": {
    "enabled": true,
    "thresholdCharacters": 500,
    "jumpPercentage": 10,
    "probeEvery": 4,
    "minimumThreshold": 200,
    "maximumThreshold": 200000,
    "template": "Respond in less than {limit} characters or less."
  }
}
~~~

`{limit}` is the only substitution. The template is deliberately **not** run
through `{env:}`/`{file:}` interpolation: it is text sent to the model every
turn, and a cloned repository must not be able to read a file into it.

### Gateway-timeout continuation

A gateway that times out mid-answer leaves real work on the far side, so the
run re-asks with a short continuation prompt instead of surfacing a dead turn.
Only genuine timeouts qualify — HTTP 408/504/522/524, or a transport failure
whose prose says it timed out, stalled or missed a deadline. A rate limit, an
overflow, an auth failure or a cancellation never does.

~~~json
{
  "gatewayContinuation": {
    "enabled": true,
    "maxAttempts": 10,
    "message": "Refer to previous context and continue."
  }
}
~~~

Each attempt emits a `gateway_continue` notice, so the status line reads
`Gateway timed out — continuing (3/10)` rather than going quiet.

## Testing and contribution rules

Run **target by target**, and suite by suite for the fixture-bearing targets,
because the suite uses subprocesses, sockets, PTYs, and timing-sensitive
fixtures. A package-wide run is not merely slow: Swift Testing overlaps suites
inside one process even under `--no-parallel`, and the server, client and PTY
fixtures then wait forever on a neighbour's torn-down event loop. The Test step
in [.github/workflows/ci.yml](.github/workflows/ci.yml) is the authoritative
invocation — mirror it locally rather than running `swift test` bare:

~~~sh
swift build
swift test --no-parallel --filter "^DoMoCoreTests\."          # one target at a time
swift test --no-parallel --filter "^DoMoServerTests\.Suite/"  # one suite for server/client/CLI
swift run domo -p "prompt"
~~~

Release matters and is not optional: `precondition` compiles out under
`-Onone`, and `@testable import` cannot build in release.

New terminal behavior needs a pure component test, a cell-oracle test, and a
PTY test where bytes or lifecycle matter. New tools need schema, permission,
headless, error-result, cancellation, and integration coverage. New provider
adapters need recorded wire fixtures, redaction tests, retry/error
classification, tool-loop tests, and normalized event assertions.

Use four-space indentation, strict Swift concurrency, and the existing target
boundaries. Keep POSIX imports in DoMoTermIO and UI work on the TUI main-actor
boundary. Do not commit API keys, settings containing secrets, or generated
session data.

Before porting code:

1. inspect the exact upstream path and commit;
2. verify the license and copyright holders;
3. copy required SPDX/copyright headers;
4. update [NOTICES.md](NOTICES.md);
5. add a focused test that proves the behavior rather than copying an
   implementation blindly.

## License and notices

DoMoCode is released under the [MIT License](LICENSE), Copyright (c) 2026 Sam
Stegall. DoMoCode-derived source from Pi, OpenCode, and Kilo is credited under
their MIT licenses. OpenHands prior art was studied from the MIT-licensed tree
only; enterprise/ is not eligible for porting.

[NOTICES.md](NOTICES.md) is authoritative for existing derived code,
copyrights, third-party licenses, and dependency obligations.
