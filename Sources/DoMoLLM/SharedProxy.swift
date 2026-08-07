// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// The one place a process says "everything outbound goes through this proxy".

import Foundation
import Synchronization

import DoMoCore

/// The process-wide proxy pool that every default HTTP path consults.
///
/// This exists because the first shape of proxy support did not work at all,
/// and the reason is worth keeping written down. The policy, the pool, the
/// settings resolution and their tests were all correct and all passed — and
/// nothing was proxied, because routing through the pool was an OPTIONAL
/// argument at five separate construction sites and every one of them was left
/// at its default. A knob a user can set and nothing reads is worse than an
/// absent feature: the tool reports the setting back, the documentation
/// describes it, and the traffic goes direct anyway.
///
/// So the wiring is inverted. A caller installs once, at startup, and the
/// DEFAULTS consult this — ``LiteLLMClient`` when it builds its own transport,
/// and the MCP client when it is given no HTTP client of its own. Adding a new
/// call site now opts IN to the proxy by doing nothing, which is the only
/// arrangement that survives someone forgetting.
///
/// Nothing is installed by default, and with nothing installed every consumer
/// behaves exactly as it did before proxy support existed.
public enum SharedProxy {

    private static let pool = Mutex<ProxiedHTTPClients?>(nil)

    /// Install the pool for the rest of the process.
    ///
    /// Replacing an existing pool returns the old one so the caller can shut it
    /// down; dropping a pool without shutting it down leaks its clients.
    @discardableResult
    public static func install(_ replacement: ProxiedHTTPClients?) -> ProxiedHTTPClients? {
        pool.withLock { current in
            let previous = current
            current = replacement
            return previous
        }
    }

    /// The installed pool, or `nil` when this process proxies nothing.
    public static var current: ProxiedHTTPClients? {
        pool.withLock { $0 }
    }

    /// Uninstall and shut down whatever is installed. Idempotent.
    ///
    /// Every owned client has to be shut down or the process can hang at exit,
    /// and the pool is deliberately the only thing that knows what it built.
    public static func shutdown() async {
        let previous = pool.withLock { current -> ProxiedHTTPClients? in
            let value = current
            current = nil
            return value
        }
        await previous?.shutdown()
    }
}
