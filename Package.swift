// swift-tools-version: 6.2
//
// DoMoCode — a Swift port of the Pi Agent Harness (earendil-works/pi, MIT).
// See NOTICES.md for attribution and README.md for the module map.
//
// `swift-tools-version` stays at 6.2 — it is the manifest FORMAT this file uses,
// and nothing here needs a 6.3 manifest feature. The *toolchain* floor is 6.3,
// pinned by CI; see below.
//
// The floor was 6.2 originally because that is what gates `.defaultIsolation`,
// and SE-0461 changes the runtime meaning of every `nonisolated async` function
// in the package. Both still hold at 6.3.
//
// It moved to 6.3 on 2026-08-01 because 6.2 stopped being buildable, not because
// anything here wanted a newer feature. Two dependencies now need a toolchain
// newer than 6.2 ships: swift-system 1.7+ references `AT_RESOLVE_BENEATH` behind
// a `canImport(Darwin, _version: 346)` gate that admits it on an SDK which does
// not declare it, and swift-configuration — a Hummingbird transitive since 2.18,
// in every 1.x release — reaches for `Data.bytes`, a Foundation API 6.2 does not
// have. Holding 6.2 would have meant pinning swift-system back two minors AND
// Hummingbird back nine, indefinitely, to keep a promise nothing in this package
// actually depended on. The floor exists to be tested rather than assumed, which
// is exactly how this was found — it failed only in CI, because development
// happens on a newer toolchain.

import PackageDescription

// MARK: - Shared build settings

/// Settings every target gets.
///
/// `NonisolatedNonsendingByDefault` (SE-0461) makes an unmarked `nonisolated
/// async func` inherit its caller's isolation rather than hop to the global
/// executor. `@concurrent` is the new spelling for the old behavior, and is
/// reserved for module seams — see README, "Concurrency and isolation".
let baseSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .treatAllWarnings(as: .error),
]

/// `baseSettings` plus strict memory safety.
///
/// On for every target except `DoMoTermIO`, which is POSIX calls by design:
/// annotating roughly one `unsafe` per call there teaches you to stop reading
/// the warnings, which defeats the point. Everywhere else a strict-memory-safety
/// diagnostic means unsafety leaked out of that seam.
let safeSettings: [SwiftSetting] = baseSettings + [.strictMemorySafety()]

let package = Package(
    name: "DoMoCode",
    platforms: [
        // `Synchronization.Mutex` and `Atomic` are gated @available(macOS 15)
        // on Apple platforms; they are unconditional on Linux.
        .macOS(.v15)
    ],
    products: [
        .executable(name: "domo", targets: ["domo"]),
        .library(name: "DoMoCore", targets: ["DoMoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", from: "1.7.5"),
        .package(url: "https://github.com/apple/swift-log", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.35.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.6.0"),
        // The AsyncHTTPClient trait is enabled deliberately. It is the transport
        // this package uses, and leaving the trait off also miscompiles: a
        // release build with --build-tests fails to emit EventSource's module
        // with "missing required module '_NumericsShims'", a Clang module
        // reached through async-http-client -> swift-algorithms -> RealModule.
        .package(url: "https://github.com/mattt/EventSource", from: "1.4.1", traits: ["AsyncHTTPClient"]),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "0.5.0"),
        .package(url: "https://github.com/ainame/swift-displaywidth", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/swiftlang/swift-markdown", .upToNextMinor(from: "0.8.0")),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/ajevans99/swift-json-schema", .upToNextMinor(from: "0.13.1")),
        // A headless VT100 emulator used as a test oracle: renderer bytes go in,
        // assertions run against the resulting cell grid. Test targets only.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.15.0"),
        // Phase 6 — the headless HTTP/SSE server. Resolves at 2.25.1 sharing one
        // swift-nio (2.101.x) with async-http-client, so it adds only itself plus
        // the already-present swift-service-lifecycle / NIO tail. Apache-2.0.
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.25.1"),
        // Arriving later, already validated against this graph:
        //   groue/GRDB.swift         from: "7.11.1"   — SQLite session storage (Later)
    ],
    targets: [
        // MARK: Core

        // The vocabulary every other module shares. Deliberately thin on
        // dependencies: everything above imports it, so its build cost is
        // everyone's build cost.
        .target(
            name: "DoMoCore",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system")
            ],
            swiftSettings: safeSettings
        ),

        // MARK: Terminal

        // The POSIX seam. The only target permitted to import Darwin/Glibc/Musl,
        // and the only one built without strict memory safety.
        .target(
            name: "DoMoTermIO",
            dependencies: [
                "DoMoCore",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: baseSettings
        ),

        // Inline differential renderer and component library. MainActor by
        // default — the render loop, input dispatch and timers are all one
        // thread, and saying so once here removes the annotation from every
        // Component conformance.
        .target(
            name: "DoMoTUI",
            dependencies: [
                "DoMoCore",
                "DoMoTermIO",
                "DoMoTermGraphics",
                .product(name: "DisplayWidth", package: "swift-displaywidth"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            swiftSettings: safeSettings + [.defaultIsolation(MainActor.self)]
        ),

        // MARK: Terminal graphics

        // Inline terminal image display (Phase 7.5), a faithful port of pi's
        // terminal-image.ts: capability detection, the Kitty + iTerm2 image
        // encoders, header-only pixel-dimension parsers, and cell sizing. Pure and
        // dependency-light (Foundation + Synchronization) — no TUI, no POSIX; the
        // cell pixel size is injected via setCellDimensions by whoever owns the tty.
        .target(
            name: "DoMoTermGraphics",
            dependencies: ["DoMoCore"],
            swiftSettings: safeSettings
        ),

        // MARK: Model access

        .target(
            name: "DoMoLLM",
            dependencies: [
                "DoMoCore",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "EventSource", package: "EventSource"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        // MARK: Agent

        // The agent loop, kept free of I/O and persistence so it stays cheap to
        // test and expensive to get wrong in only one place.
        .target(
            name: "DoMoAgent",
            dependencies: [
                "DoMoCore",
                "DoMoLLM",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        // The single place subprocesses and the filesystem are touched.
        .target(
            name: "DoMoExec",
            dependencies: [
                "DoMoCore",
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        // The Git policy seam (Phase 12). Git is deliberately its own target:
        // session persistence receives only the resolved start HEAD, while the
        // CLI and later review surfaces depend on this facade for all repository
        // operations. Keeping the command policy here prevents a future caller
        // from quietly reintroducing interactive prompts or unsafe ref arguments.
        .target(
            name: "DoMoGit",
            dependencies: ["DoMoCore", "DoMoExec"],
            swiftSettings: safeSettings
        ),

        .target(
            name: "DoMoHarness",
            dependencies: [
                "DoMoCore", "DoMoAgent", "DoMoLLM", "DoMoExec", "DoMoGit",
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        // MARK: Tools

        // Headless by design — no TUI import. The rendering lives next door in
        // DoMoToolsUI and is composed in at wiring time.
        .target(
            name: "DoMoTools",
            dependencies: [
                "DoMoCore", "DoMoExec",
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        .target(
            name: "DoMoToolsUI",
            dependencies: ["DoMoCore", "DoMoTools", "DoMoTUI"],
            swiftSettings: safeSettings
        ),

        // The granular permission engine (Phase 8a). A pure policy core faithfully
        // ported from opencode/kilocode (wildcard, evaluate, config, bash arity,
        // .env guard) plus the actor + request factory + before-tool-call hook
        // adapter that gate the pure agent loop. Depends on DoMoCore (JSONValue) and
        // DoMoAgent (the BeforeToolCallHook type) only.
        .target(
            name: "DoMoPermissions",
            dependencies: ["DoMoCore", "DoMoAgent"],
            swiftSettings: safeSettings
        ),

        // The MCP client (Phase 8c). A hand-rolled, stdio-local, tools-only Model
        // Context Protocol client: spawns each configured server as a subprocess,
        // speaks newline-delimited JSON-RPC 2.0 over its stdin/stdout, discovers tools
        // and bridges each as an `AgentTool`. No SDK (the official one doesn't spawn
        // the subprocess and drags a branch-pinned docc plugin). Reuses swift-subprocess
        // (as DoMoExec does) + DoMoCore's JSONValue/JSONSchema for framing.
        .target(
            name: "DoMoMCP",
            dependencies: [
                "DoMoCore", "DoMoAgent", "DoMoLLM",
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        // MARK: Server

        // The headless HTTP/SSE runtime server (Phase 6). Wraps the existing
        // runtime — DoMoHarness / DoMoAgent / DoMoLLM — behind Hummingbird;
        // loopback-only, single-client-first, broadcast-capable. No TUI import.
        .target(
            name: "DoMoServer",
            dependencies: [
                "DoMoCore", "DoMoAgent", "DoMoLLM", "DoMoHarness", "DoMoGit", "DoMoPermissions",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        // MARK: Client

        // The remote full-screen TUI client (Phase 7d). Consumes the DoMoServer
        // wire — `ServerEvent` over SSE + the REST endpoints — through
        // AsyncHTTPClient, folds the delta-only stream into a normalized transcript,
        // and drives a two-pane full-screen `ScreenSurface`. It imports DoMoServer
        // only for the wire DTOs (not the Hummingbird server), and never touches
        // POSIX directly. The transport is `Sendable`/off-main; the UI layer marks
        // `@MainActor` explicitly (DoMoTUI sets `.defaultIsolation` on itself, not on
        // dependents), so this target keeps the default nonisolated settings.
        .target(
            name: "DoMoClient",
            dependencies: [
                "DoMoCore", "DoMoServer", "DoMoGit", "DoMoLLM", "DoMoHarness", "DoMoPermissions",
                // DoMoExec is the package's single image loader
                // (`ImageAttachmentLoader`) and its single filesystem seam. The
                // client reads a dropped file locally before staging it, so it
                // needs both. Already in the graph via DoMoHarness — this adds no
                // third-party dependency and no new build edge of consequence.
                "DoMoExec",
                "DoMoTUI", "DoMoTermIO", "DoMoTermGraphics", "DoMoToolsUI",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        // MARK: CLI

        .target(
            name: "DoMoCLI",
            dependencies: [
                "DoMoCore", "DoMoTUI", "DoMoTermIO", "DoMoTermGraphics", "DoMoLLM", "DoMoAgent",
                "DoMoHarness", "DoMoExec", "DoMoGit", "DoMoTools", "DoMoToolsUI", "DoMoPermissions", "DoMoMCP", "DoMoServer", "DoMoClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        .executableTarget(
            name: "domo",
            dependencies: ["DoMoCLI"],
            swiftSettings: safeSettings
        ),

        // MARK: Tests

        .testTarget(
            name: "DoMoCoreTests",
            dependencies: ["DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoLLMTests",
            dependencies: ["DoMoLLM", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoTermGraphicsTests",
            dependencies: ["DoMoTermGraphics", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoExecTests",
            dependencies: ["DoMoExec", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoGitTests",
            dependencies: ["DoMoGit", "DoMoExec", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoToolsTests",
            dependencies: ["DoMoTools", "DoMoExec", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoAgentTests",
            dependencies: ["DoMoAgent", "DoMoLLM", "DoMoTools", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoPermissionsTests",
            dependencies: ["DoMoPermissions", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoMCPTests",
            dependencies: ["DoMoMCP", "DoMoCore", "DoMoAgent", "DoMoLLM"],
            swiftSettings: safeSettings
        ),

        .testTarget(
            name: "DoMoHarnessTests",
            dependencies: ["DoMoHarness", "DoMoAgent", "DoMoLLM", "DoMoExec", "DoMoCore", "DoMoGit"],
            swiftSettings: safeSettings
        ),

        // baseSettings (strict memory safety off): terminal tests open PTYs and
        // touch termios/ioctl directly, which is `unsafe` by design.
        .testTarget(
            name: "DoMoTermIOTests",
            dependencies: ["DoMoTermIO", "DoMoCore"],
            swiftSettings: baseSettings
        ),

        // baseSettings: the SwiftTerm-backed screen-state oracle bridges a Swift-5
        // language-mode dependency, and strict memory safety on the test bridge
        // buys nothing.
        .testTarget(
            name: "DoMoTUITests",
            dependencies: [
                "DoMoTUI", "DoMoTermIO", "DoMoTermGraphics", "DoMoCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: baseSettings
        ),

        .testTarget(
            name: "DoMoToolsUITests",
            dependencies: ["DoMoToolsUI", "DoMoTUI", "DoMoTools", "DoMoExec", "DoMoCore"],
            swiftSettings: safeSettings
        ),

        // Strict memory safety is off here, matching DoMoTermIO's rationale: the
        // end-to-end test stands up a loopback HTTP gateway with raw POSIX
        // sockets, which is `unsafe` by design and has nothing to audit.
        .testTarget(
            name: "DoMoCLITests",
            dependencies: [
                "DoMoCLI", "DoMoCore", "DoMoLLM", "DoMoTUI", "DoMoTermIO", "DoMoTermGraphics",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: baseSettings
        ),

        // The server e2e stands up DoMoServer on a loopback port and drives it with
        // a real AsyncHTTPClient, with a scripted stream function in place of the
        // LiteLLM client, so no mock LLM gateway is needed.
        .testTarget(
            name: "DoMoServerTests",
            dependencies: [
                "DoMoServer", "DoMoCore", "DoMoLLM", "DoMoAgent", "DoMoHarness", "DoMoPermissions",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
            ],
            swiftSettings: safeSettings
        ),

        // baseSettings: the client's two-pane UI is asserted through the same
        // SwiftTerm cell-grid oracle the TUI tests use, and the transport is proven
        // against a real in-process DoMoServer over AsyncHTTPClient.
        .testTarget(
            name: "DoMoClientTests",
            dependencies: [
                "DoMoClient", "DoMoServer", "DoMoCore", "DoMoLLM", "DoMoAgent", "DoMoPermissions",
                "DoMoHarness", "DoMoExec", "DoMoTUI", "DoMoTermIO", "DoMoTermGraphics",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: baseSettings
        ),
    ]
)
