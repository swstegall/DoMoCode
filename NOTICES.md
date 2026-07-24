# Notices and Attributions

This file records the third-party works from which DoMoCode is derived, and the works it depends on.
It supplements — and does not replace — the [`LICENSE`](LICENSE) file at the root of this repository.

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

### OpenTUI (via pi-tui `stdin-buffer.ts`)

`packages/tui/src/stdin-buffer.ts`, from which `DoMoTermIO`'s escape-sequence reassembly is ported,
is itself derived from OpenTUI and carries that project's copyright line upstream.

- **Repository:** https://github.com/anomalyco/opentui
- **License:** MIT
- **Copyright:** (c) 2025 opentui

Swift files deriving from that path carry OpenTUI's copyright line in addition to the two below.

### string-width (via pi-tui `utils.ts`)

`packages/tui/src/utils.ts` documents its grapheme-width and character-classification logic as based
on the `string-width` library. Upstream pi carries no copyright line for it; it is named here rather
than inheriting that gap.

- **Repository:** https://github.com/sindresorhus/string-width
- **License:** MIT
- **Copyright:** Sindre Sorhus

### Scope of the derivation

DoMoCode is a narrowed port. The table below records which planned modules derive from which
upstream packages. It will be kept current as implementation lands.

| DoMoCode module | Derived from (upstream path) |
|---|---|
| `DoMoTermIO` | `packages/tui/src/terminal.ts`, `packages/tui/src/stdin-buffer.ts` |
| `DoMoTUI` | `packages/tui/src/tui.ts`, `keys.ts`, `keybindings.ts`, `utils.ts`, `fuzzy.ts`, `autocomplete.ts`, `kill-ring.ts`, `undo-stack.ts`, `word-navigation.ts`, `components/` |
| `DoMoLLM` | `packages/ai/src/` — type model, streaming assembly, retry and overflow classification, and cost accounting, narrowed to the OpenAI Chat Completions API |
| `DoMoAgent` | `packages/agent/src/agent-loop.ts`, `agent.ts`, `types.ts` |
| `DoMoHarness` | `packages/agent/src/harness/` |
| `DoMoExec` | `packages/agent/src/harness/env/`, file mutation queue |
| `DoMoTools`, `DoMoToolsUI` | `packages/coding-agent/src/core/tools/` |
| `DoMoCLI` | `packages/coding-agent/src/` — session orchestration, settings, project trust, resource loading, slash commands, output modes |
| `DoMoCore` | Original to DoMoCode, with the tolerant JSON repair behavior modeled on upstream's |

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

## Third-party dependencies

Planned Swift Package Manager dependencies. Entries will be confirmed and pinned as they are added
to `Package.swift`.

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

Planned for optional SQLite session storage.

### SwiftTerm

- **Repository:** https://github.com/migueldeicaza/SwiftTerm
- **License:** MIT
- **Copyright:** Miguel de Icaza. Its license additionally carries the copyrights of the xterm.js
  project, SourceLair Private Company, and Christopher Jeffrey, from which SwiftTerm derives.

Used in test targets only, as a headless terminal emulator against which renderer output is asserted.

---

## Distribution

Several dependencies above are licensed under Apache-2.0, whose section 4(d) requires attribution
notices to travel with redistributed works. A file in this repository does not travel with a release
tarball or a package-manager bottle, so binary distributions will ship a generated
`THIRD-PARTY-NOTICES.txt` alongside the executable, and `domo --licenses` will print the same
content.

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
project, Apple Inc., or any other project named in this file.

"Pi", "Pi Agent Harness", "LiteLLM", "Swift", and any related names, marks, emblems, and images are
the property of their respective owners and are used here for identification purposes only.

---

## Corrections

If you believe a work is used here without proper attribution, please open an issue at
https://github.com/swstegall/DoMoCode/issues and it will be corrected promptly.
