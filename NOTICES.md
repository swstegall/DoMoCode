# Notices and Attributions

This file records the third-party works from which DoMoCode is derived, the works it depends on, and
the sibling projects it studied as prior art. It supplements — and does not replace — the
[`LICENSE`](LICENSE) file at the root of this repository.

DoMoCode is licensed under the MIT License, Copyright (c) 2026 Sam Stegall. See
[`LICENSE`](LICENSE) for the full text.

---

## Upstream project: Pi Agent Harness

DoMoCode is a port of the **Pi Agent Harness** to Swift and the Swift Package Manager.

- **Project:** Pi Agent Harness (`pi`)
- **Upstream repository:** https://github.com/earendil-works/pi
- **Upstream author:** Mario Zechner and the Pi contributors
- **Upstream license:** MIT License
- **Ported from:** `v0.81.1`, commit
  [`9b3a2059171bcc74ad9d2cadeea6d186776cf2db`](https://github.com/earendil-works/pi/commit/9b3a2059171bcc74ad9d2cadeea6d186776cf2db)
  (2026-07-22)

Portions of DoMoCode are derived from the Pi Agent Harness, including its overall architecture and
the design of its agent loop, tool interfaces, terminal rendering strategy, and message and session
formats. Those portions remain Copyright (c) 2025 Mario Zechner and are used under the terms of the
MIT License, reproduced verbatim below.

### Pi Agent Harness — MIT License

```
MIT License

Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### OpenTUI (via pi-tui)

Two pi-tui files from which `DoMoTermIO` is ported are themselves derived from OpenTUI and carry that
project's copyright line upstream: `packages/tui/src/stdin-buffer.ts` (escape-sequence reassembly, ported
to `StdinFraming.swift`) and `packages/tui/src/keys.ts` (key decoding, ported to `KeyDecoding.swift`).

- **Repository:** https://github.com/anomalyco/opentui
- **License:** MIT
- **Copyright:** (c) 2025 opentui

Both Swift files carry OpenTUI's copyright line in addition to pi's and DoMoCode's; they are the only
two in the package that do.

### string-width (via pi-tui `utils.ts`)

`packages/tui/src/utils.ts` documents its grapheme-width and character-classification logic as based
on the `string-width` library. Upstream pi carries no copyright line for it; it is named here rather
than inheriting that gap.

- **Repository:** https://github.com/sindresorhus/string-width
- **License:** MIT
- **Copyright:** Sindre Sorhus

### Scope of the derivation

DoMoCode is a narrowed port. The table below records which module derives from which upstream package.
Every module listed here ships.

| DoMoCode module | Derived from (upstream path) |
|---|---|
| `DoMoTermIO` | `packages/tui/src/terminal.ts`, `packages/tui/src/stdin-buffer.ts` |
| `DoMoTUI` | `packages/tui/src/tui.ts`, `keys.ts`, `keybindings.ts`, `utils.ts`, `fuzzy.ts`, `autocomplete.ts`, `kill-ring.ts`, `undo-stack.ts`, `word-navigation.ts`, `components/`. Its full-screen (alternate-screen) layer — `AltScreenCore`, `CellBuffer`, `LayoutNode`, `FocusRing`, `ScreenSurface` — is original to DoMoCode; OpenTUI's retained-cell-buffer + flexbox *design* is referenced as architecture only, and no OpenTUI code is used (it is TypeScript) |
| `DoMoLLM` | `packages/ai/src/` — type model, streaming assembly, retry and overflow classification, and cost accounting, narrowed to the OpenAI Chat Completions API |
| `DoMoAgent` | `packages/agent/src/agent-loop.ts`, `agent.ts`, `types.ts` |
| `DoMoHarness` | `packages/agent/src/harness/` |
| `DoMoExec` | `packages/agent/src/harness/env/`, file mutation queue |
| `DoMoTools`, `DoMoToolsUI` | `packages/coding-agent/src/core/tools/` |
| `DoMoCLI` | `packages/coding-agent/src/` — session orchestration, settings, project trust, output modes |
| `DoMoCore` | Original to DoMoCode, with the tolerant JSON repair behavior modeled on upstream's |
| `DoMoTermGraphics` | `packages/tui/src/terminal-image.ts` — Kitty/iTerm2 image encoders and header-only dimension parsers (a direct port; the BMP reader is a DoMoCode addition, as pi has none) |
| `DoMoServer` | Original to DoMoCode — a local HTTP/SSE server. Its shape is modeled on opencode's server (studied prior art, no code derived); pi's own `packages/server` is *not* ported |
| `DoMoClient` | Original to DoMoCode — the full-screen terminal client for `DoMoServer`. No upstream: pi has no client/server split |
| `DoMoPermissions` | **Not pi.** pi has no permission engine; the allow/ask/deny policy core is ported from **opencode**, and the saved-versus-base layering and config writer from **kilocode**. Both are MIT and both are credited in the dual-copyright headers of the files concerned — see [Other prior art](#other-prior-art) for the file-by-file list |
| `DoMoMCP` | Original to DoMoCode — a hand-rolled stdio MCP client (no SDK). Modeled on opencode/kilocode `mcp/` (studied prior art, no code derived); pi has no MCP |

Swift source files that closely follow a specific upstream TypeScript file carry a dual copyright
header naming that file and the commit it was read at, in the following form:

```swift
// Copyright (c) 2025 Mario Zechner. MIT license.
// https://github.com/earendil-works/pi/blob/9b3a2059/packages/<pkg>/src/<file>.ts
// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Ported to Swift from the Pi Agent Harness.
```

Files whose upstream source itself derives from a third work carry that work's copyright line as
well, above the two above — for example, files ported from `stdin-buffer.ts`:

```swift
// Copyright (c) 2025 opentui. MIT license.
// https://github.com/anomalyco/opentui
```

The following upstream components are **not** ported and are not derived from: `packages/server`,
`packages/storage/sqlite-node`, the TypeScript extension system, the pi package manager, and all
non-OpenAI provider implementations in `packages/ai`.

---

## Other prior art

Beyond its upstream, DoMoCode was informed by three other open-source coding-agent harnesses, read
closely during design. Each remains the property of its authors under its own license. The features
taken as *ideas* are catalogued in the project's
[README](README.md#sibling-harnesses-and-prior-art).

Two of the three are more than idea sources, and this section used to say otherwise. **`DoMoPermissions`
contains code derived from opencode and from kilocode**, ported in Phase 8a: the wildcard matcher, the
bash arity table, the policy evaluator, the config codec, the engine, the request vocabulary and the
request factory all carry opencode's copyright, and the config codec and the settings-file writer carry
kilocode's. Those files carry dual copyright headers in the same form as the pi-derived sources above —
see the table below for the exact per-file record. Nothing is derived from OpenHands.

### opencode

- **Repository:** https://github.com/anomalyco/opencode
- **License:** MIT
- **Copyright:** (c) 2025 opencode. The vendored `packages/docs` uses a Mintlify documentation
  template, (c) 2023 Mintlify — noted here in case that subtree is ever referenced.

opencode is also relevant transitively: DoMoCode's `DoMoTermIO` escape-sequence reassembly is ported
from pi-tui's `stdin-buffer.ts`, which upstream derives from **OpenTUI** — a project by the same
authors (the `anomalyco` org). OpenTUI's own attribution is recorded above under the Pi Agent
Harness section.

The Phase 13 shadow-workspace snapshot shape and its separate `GIT_DIR` approach are derived from
opencode's MIT-licensed snapshot service:
`packages/opencode/src/snapshot/index.ts` at
[`anomalyco/opencode`](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/snapshot/index.ts).
The Swift implementation, append-only session integration, and conflict-safe restore planner are
original DoMoCode work. `Sources/DoMoGit/ShadowGit.swift` retains the upstream copyright and SPDX
header.

The `DoMoServer` and `DoMoMCP` modules model their *architecture* on opencode's server
(`server.ts` / `event.ts` / `session.ts`) and `mcp/` respectively — design reference only, no code
derived — and `DoMoTUI`'s full-screen layer re-derives OpenTUI's retained-cell-buffer + flexbox design
without using OpenTUI, which is TypeScript.

**`DoMoPermissions` is different: it contains ported code.** The table below is transcribed from the
copyright headers of the files themselves, which are the authoritative record; four of them also cite
the upstream path, and the rest name only the holder.

| DoMoCode file | Copyright lines it carries, besides DoMoCode's | Upstream path cited in the header |
|---|---|---|
| `Wildcard.swift` | opencode contributors | `packages/core/src/util/wildcard.ts` |
| `BashArity.swift` | opencode contributors | `packages/opencode/src/permission/arity.ts` |
| `PermissionPolicy.swift` | opencode contributors | `packages/opencode/src/permission/index.ts` |
| `PermissionConfig.swift` | opencode contributors **and** Kilo Code / opencode contributors | `permission/index.ts` (`fromConfig` / `toConfig` / `expand`) |
| `PermissionConfigWriter.swift` | Kilo Code / opencode contributors | — |
| `PermissionEngine.swift` | opencode contributors | — |
| `PermissionRequest.swift` | opencode contributors | — |
| `PermissionRequestFactory.swift` | opencode contributors | — |

The remaining five files — `OrderedJSON.swift`, `PermissionConfigLoader.swift`, `PermissionHook.swift`,
`PrompterBox.swift` and `ShellCommand.swift` — carry DoMoCode's copyright alone. Two of them describe
their behavior by reference to opencode (`PermissionConfigLoader` follows its `normalizeInput`
normalization; `ShellCommand` deliberately replaces its tree-sitter parse with a hand-rolled scanner),
but neither reproduces its code.

Note that the headers cite `github.com/sst/opencode`, the organization's name when they were written;
the repository is now at `github.com/anomalyco/opencode`. Both refer to the same project.

### kilocode

- **Repository:** https://github.com/Kilo-Org/kilocode
- **License:** MIT
- **Copyright:** (c) 2026 Kilo Code, **and** (c) 2025 opencode. kilocode's CLI harness
  (`@kilocode/cli`, binary `kilo`) is itself a fork of opencode, so its root `LICENSE` carries both
  copyright lines verbatim; were any snippet ever adopted, both holders would need crediting. The
  repository's VS Code and JetBrains extensions descend from a separate Cline → Roo Code → Kilo Code
  lineage. kilocode's `mcp/` (itself an opencode fork) was read as a cross-reference for the
  `DoMoMCP` client — design reference only, no code derived. **Two `DoMoPermissions` files are ported
  from it**, not merely referenced: `PermissionConfig.swift` and `PermissionConfigWriter.swift` carry
  `Copyright (c) 2025 Kilo Code / opencode contributors`. Because kilocode's CLI is an opencode fork,
  both holders are named, exactly as its own `LICENSE` does. (`PermissionPolicy.swift`'s `.env` read
  guard and saved-versus-base resolution also follow kilocode's, under opencode's copyright line.)

### OpenHands

- **Repository:** https://github.com/OpenHands/OpenHands (formerly OpenDevin; org and repo formerly
  `All-Hands-AI/OpenHands`), controlled by All Hands AI.
- **License:** **Split.** The core tree (`openhands/`, `frontend/`, `skills/`, `openhands-ui/`, and
  the rest outside `enterprise/`) is MIT, Copyright (c) 2025. The `enterprise/` subtree is under the
  **PolyForm Free Trial License 1.0.0**, Copyright (c) 2026 All Hands AI — source-available but
  **not** an open-source license and not redistributable. **Only the MIT-licensed tree was studied;
  the `enterprise/` subtree was excluded entirely.**
- **Note:** Per its `CREDITS.md`, OpenHands itself adapts SWE-Agent (MIT), Aider's linter module
  (Apache-2.0), and BrowserGym (Apache-2.0). Those would carry their own notice obligations if any
  OpenHands-adapted code were ever taken into DoMoCode — none is.

---

## Third-party dependencies

The Swift Package Manager dependencies declared in `Package.swift`, plus — clearly marked as such —
the few that were considered and not taken. The Apache-2.0 entries carry live section 4(d)
obligations: their notices must travel with any redistributed binary.

### swift-argument-parser

- **Repository:** https://github.com/apple/swift-argument-parser
- **License:** Apache-2.0
- **Copyright:** Apple Inc. and the Swift project authors

DoMoCode's terminal-size detection additionally adapts the per-platform `TIOCGWINSZ` handling from
this project's internal `Sources/ArgumentParser/Utilities/Platform.swift`, under the Apache License,
Version 2.0.

### async-http-client

- **Repository:** https://github.com/swift-server/async-http-client
- **License:** Apache-2.0
- **Copyright:** Apple Inc. and the SwiftNIO project authors

### swift-http-types

- **Repository:** https://github.com/apple/swift-http-types
- **License:** Apache-2.0
- **Copyright:** Apple Inc. and the Swift project authors

### EventSource

- **Repository:** https://github.com/mattt/EventSource
- **License:** MIT
- **Copyright:** Mattt

### swift-displaywidth

- **Repository:** https://github.com/ainame/swift-displaywidth
- **License:** MIT
- **Copyright:** Satoshi Namai

### swift-system

- **Repository:** https://github.com/apple/swift-system
- **License:** Apache-2.0
- **Copyright:** Apple Inc. and the Swift System project authors

### swift-subprocess

- **Repository:** https://github.com/swiftlang/swift-subprocess
- **License:** Apache-2.0
- **Copyright:** Apple Inc. and the Swift project authors

### swift-log

- **Repository:** https://github.com/apple/swift-log
- **License:** Apache-2.0
- **Copyright:** Apple Inc. and the Swift project authors

### Yams

- **Repository:** https://github.com/jpsim/Yams
- **License:** MIT
- **Copyright:** JP Simard and the Yams project authors

### swift-json-schema

- **Repository:** https://github.com/ajevans99/swift-json-schema
- **License:** MIT
- **Copyright:** Andrew Evans

### swift-markdown

- **Repository:** https://github.com/swiftlang/swift-markdown
- **License:** Apache-2.0 WITH Swift-exception
- **Copyright:** Apple Inc. and the Swift project authors

### swift-cmark

- **Repository:** https://github.com/swiftlang/swift-cmark
- **License:** Apache-2.0 WITH Swift-exception; bundles cmark under BSD-2-Clause
- **Copyright:** Apple Inc. and the Swift project authors; cmark Copyright (c) 2014 John MacFarlane

Arrives transitively via swift-markdown.

### GRDB.swift

- **Repository:** https://github.com/groue/GRDB.swift
- **License:** MIT
- **Copyright:** Gwendal Roué

**Not a declared dependency.** Held for optional SQLite session storage, which remains unbuilt — JSONL
is still the only `SessionStorage` implementation. Listed here so the license is on record if it lands.

### SwiftTerm

- **Repository:** https://github.com/migueldeicaza/SwiftTerm
- **License:** MIT
- **Copyright:** Miguel de Icaza. Its license additionally carries the copyrights of the xterm.js
  project, SourceLair Private Company, and Christopher Jeffrey, from which SwiftTerm derives.

Used in test targets only, as a headless terminal emulator against which renderer output is asserted.

### Hummingbird

- **Repository:** https://github.com/hummingbird-project/hummingbird
- **License:** Apache-2.0
- **Copyright:** the Hummingbird project authors

The HTTP/SSE server for `DoMoServer`, added in Phase 6 at `from: "2.25.1"`. Built on SwiftNIO, which
was already resolved transitively via async-http-client.

### Considered and not taken

The [scope expansion](README.md#what-expanded-and-what-did-not) was expected to add three more
dependencies. None was: no code from any of them is used, and none appears in `Package.swift` or
`Package.resolved`. They are recorded here only so the reasoning is not lost.

- **[modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)** (MIT) — was
  to be the MCP client for Phase 8. Its `StdioTransport` does not spawn the server subprocess, and it
  pins `swift-docc-plugin` to a git branch. `DoMoMCP` is a hand-rolled JSON-RPC-2.0-over-stdio client
  instead, built on the already-present `JSONValue` and swift-subprocess.
- **[swift-png](https://github.com/tayloraswift/swift-png)** and
  **[swift-jpeg](https://github.com/tayloraswift/swift-jpeg)** (both Apache-2.0) — were to resize
  image attachments for Phase 7.5. Images are passed through unresized and an oversized one is
  rejected, so nothing decodes pixels; only hand-written header readers touch image bytes.

---

## Distribution

Several dependencies above are licensed under Apache-2.0, whose section 4(d) requires attribution
notices to travel with redistributed works. A file in this repository does not travel with a release
tarball or a package-manager bottle, so binary distributions will ship a generated
`THIRD-PARTY-NOTICES.txt` alongside the executable, and `domo --licenses` will print the same
content.

That generated file must be built from the dual-copyright headers in `Sources/`, not from the
dependency list alone: the MIT-licensed code DoMoCode *ports* — pi throughout, and opencode/kilocode
in `DoMoPermissions` — is not a package-manager dependency and would otherwise be omitted, which is
exactly the attribution MIT requires to travel with the binary.

---

## Interoperating projects

DoMoCode is a client of the following project. It is not derived from it and does not redistribute
it, but it is named here because DoMoCode is built specifically to work with it.

### LiteLLM

- **Repository:** https://github.com/BerriAI/litellm
- **License:** MIT (with some enterprise components under a separate license)
- **Copyright:** BerriAI

---

## Trademarks and non-affiliation

DoMoCode is an independent project. It is not affiliated with, associated with, authorized by,
endorsed by, or in any way officially connected with the Pi Agent Harness project, Earendil Works,
or Mario Zechner.

The official Pi Agent Harness project can be found at https://github.com/earendil-works/pi and
https://pi.dev.

DoMoCode is likewise not affiliated with, authorized by, or endorsed by BerriAI or the LiteLLM
project, Apple Inc., Kilo Code, the opencode project (Anomaly Innovations), OpenHands / All Hands AI,
or any other project named in this file. The sibling harnesses are named only as studied prior art.

"Pi", "Pi Agent Harness", "LiteLLM", "Swift", "opencode", "kilocode", "Kilo Code", "OpenHands", and
any related names, marks, emblems, and images are the property of their respective owners and are
used here for identification purposes only.

---

## Corrections

If you believe a work is used here without proper attribution, please open an issue at
https://github.com/swstegall/DoMoCode/issues and it will be corrected promptly.
