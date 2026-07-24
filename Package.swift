// swift-tools-version: 6.2
//
// DoMoCode — a Swift port of the Pi Agent Harness (earendil-works/pi, MIT).
// See NOTICES.md for attribution and README.md for the module map.
//
// The 6.2 floor is deliberate: it is what gates `.defaultIsolation`, and SE-0461
// changes the runtime meaning of every `nonisolated async` function in the
// package. Adopting that now, against an empty package, is free.

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
        .executable(name: "domocode", targets: ["domocode"]),
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
        // Arriving later, already validated against this graph:
        //   groue/GRDB.swift         from: "7.11.1"   — Phase 6, optional storage
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
                .product(name: "DisplayWidth", package: "swift-displaywidth"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            swiftSettings: safeSettings + [.defaultIsolation(MainActor.self)]
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

        .target(
            name: "DoMoHarness",
            dependencies: [
                "DoMoCore", "DoMoAgent", "DoMoLLM", "DoMoExec",
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

        // MARK: CLI

        .target(
            name: "DoMoCLI",
            dependencies: [
                "DoMoCore", "DoMoTUI", "DoMoLLM", "DoMoAgent",
                "DoMoHarness", "DoMoExec", "DoMoTools", "DoMoToolsUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: safeSettings
        ),

        .executableTarget(
            name: "domocode",
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
            name: "DoMoExecTests",
            dependencies: ["DoMoExec", "DoMoCore"],
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
            name: "DoMoHarnessTests",
            dependencies: ["DoMoHarness", "DoMoAgent", "DoMoLLM", "DoMoExec", "DoMoCore"],
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
                "DoMoTUI", "DoMoTermIO", "DoMoCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: baseSettings
        ),

        // Strict memory safety is off here, matching DoMoTermIO's rationale: the
        // end-to-end test stands up a loopback HTTP gateway with raw POSIX
        // sockets, which is `unsafe` by design and has nothing to audit.
        .testTarget(
            name: "DoMoCLITests",
            dependencies: ["DoMoCLI", "DoMoCore", "DoMoLLM"],
            swiftSettings: baseSettings
        ),
    ]
)
