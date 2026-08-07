// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The harness knobs one `domo` process resolves ONCE and every surface it builds
// has to share: the adaptive response-character-limit controller and the
// gateway-continuation policy.
//
// Sharing the controller is a requirement, not a tidiness preference. It learns a
// per-alias ceiling by occasionally probing above the last known-good one, and it
// persists what it learned to a single file under the config directory. Two
// controllers in one process would each hold their own in-memory copy of that
// state, take turns clobbering the file behind its lock, and hand the model a
// limit derived from half the evidence — which is indistinguishable from the
// feature simply not working, because nothing crashes and every prompt still
// carries a plausible number.
//
// It is a published process value rather than a parameter threaded through each
// surface because the surfaces share no constructor: `-p` builds a ``PrintMode``,
// `--inline` builds an `InteractiveMode` through a factory with two dozen
// parameters, and the default full-screen client builds a `ServerRuntime`. Adding
// the argument to three unrelated lists is exactly how the fourth surface — the
// next one somebody writes by copying whichever call site they were nearest —
// ends up constructing its own. Reading it from one place means the surface that
// forgets gets `nil`, which sends prompts unchanged, rather than a private
// controller fighting the shared one for the state file.
//
// `DoMoServer` cannot read this: DoMoCLI depends on DoMoServer, not the reverse.
// The server's harness has to receive the controller as a `ServerRuntime.Config`
// field set from ``DoMoCodeCommand``.

import DoMoCore
import DoMoHarness
import DoMoLLM
import Synchronization
import SystemPackage

/// The per-process harness knobs, installed once by ``DoMoCodeCommand`` and read
/// by every surface that builds an `AgentHarness.Configuration`.
public struct ProcessHarnessDefaults: Sendable {

    /// The one adaptive response-limit controller, or `nil` when none has been
    /// installed — the state a unit test and the `--replay` path run in. `nil`
    /// means the prompt travels exactly as the user wrote it.
    public var responseLimit: ResponseLimitController?

    /// What a run does when the gateway times out mid-answer rather than the model
    /// declining to continue.
    public var gatewayContinuation: GatewayContinuationSettings

    /// How this process reaches the network.
    ///
    /// Published here for the reason in this file's header: the surfaces share no
    /// constructor, and the MCP manager is built in two of them from argument
    /// lists that do not carry a `ResolvedConfiguration`. Threading it would mean
    /// a third list to remember — and the first version of proxy support was
    /// dropped at every site that had to remember it.
    public var proxy: ProxySettings

    public init(
        responseLimit: ResponseLimitController? = nil,
        gatewayContinuation: GatewayContinuationSettings = .default,
        proxy: ProxySettings = .disabled
    ) {
        self.responseLimit = responseLimit
        self.gatewayContinuation = gatewayContinuation
        self.proxy = proxy
    }

    /// Nothing installed: no prompt decoration, stock continuation policy.
    ///
    /// This is what ``current`` answers before ``install(for:)`` runs, and it is
    /// the answer a harness built outside a `domo` invocation — a test, a library
    /// embedding — should get. Decorating a prompt is a visible change to what is
    /// stored in the session file, so the un-installed default is "don't".
    public static let unconfigured = ProcessHarnessDefaults()

    private static let published = Mutex<ProcessHarnessDefaults>(.unconfigured)

    /// What every surface reads when it builds a harness configuration.
    public static var current: ProcessHarnessDefaults { published.withLock { $0 } }

    /// Builds this process's controller from resolved configuration and publishes
    /// it alongside the continuation policy.
    ///
    /// Called once, from ``DoMoCodeCommand``'s `execute()`, straight after the
    /// configuration is resolved and before any surface exists to read it. A later
    /// call replaces what an earlier one published rather than being ignored: an
    /// install that silently discarded its argument would let a test — or a second
    /// entry point added later — believe it had configured something it had not.
    @discardableResult
    public static func install(for configuration: ResolvedConfiguration) -> ProcessHarnessDefaults {
        let defaults = ProcessHarnessDefaults(
            responseLimit: makeResponseLimitController(for: configuration),
            gatewayContinuation: configuration.gatewayContinuation,
            proxy: configuration.proxy
        )
        published.withLock { $0 = defaults }
        // The proxy is installed at the same moment and for the same reason as
        // the rest of this type: it is a fact about the PROCESS, and a knob that
        // has to be remembered at each construction site is a knob that gets
        // dropped. It was, at all five of them, which is why the first version of
        // proxy support resolved the settings correctly and then sent every
        // request direct. Nothing is installed when nothing is configured, so a
        // run with no proxy keeps the exact behaviour it had before.
        installSharedProxy(for: configuration)
        return defaults
    }

    /// Publish the process's proxy pool, or leave none installed.
    ///
    /// Separate from ``install(for:)`` only so a caller that builds no harness —
    /// a diagnostic subcommand, a test — can still route its traffic correctly.
    /// Replacing an existing pool shuts the old one down rather than leaking it.
    public static func installSharedProxy(for configuration: ResolvedConfiguration) {
        let replacement = configuration.proxy.isConfigured
            ? ProxiedHTTPClients(settings: configuration.proxy)
            : nil
        // Whatever was installed before is shut down, never dropped: its clients
        // hold connection pools, and a pool nobody shuts down can hang exit.
        if let previous = SharedProxy.install(replacement) {
            Task { await previous.shutdown() }
        }
    }

    /// A controller over the configured settings and state file, without
    /// publishing it.
    ///
    /// Built even when the settings say the feature is off. The disabled case
    /// belongs to the controller — it returns the text unchanged and no ticket —
    /// and giving the CLI a second way to spell "off" is how the two spellings
    /// come to disagree about, say, whether an already-decorated resumed prompt
    /// still gets its limit line stripped.
    public static func makeResponseLimitController(
        for configuration: ResolvedConfiguration
    ) -> ResponseLimitController {
        ResponseLimitController(
            settings: configuration.responseLimit,
            store: FileResponseLimitStore(path: configuration.responseLimitStatePath)
        )
    }
}
