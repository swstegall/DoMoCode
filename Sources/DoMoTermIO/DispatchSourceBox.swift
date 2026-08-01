// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// Carries a `DispatchSource` across a `Sendable` boundary.
///
/// A PLATFORM discrepancy, not a hazard. The `DispatchSource*` protocols are
/// `Sendable` on Darwin and are NOT on swift-corelibs-libdispatch, so storing one
/// in a `Mutex`, or capturing one in an `AsyncStream.Continuation.onTermination`
/// handler, compiles on macOS and is a hard error on Linux. That asymmetry is why
/// none of it ever appeared in a local build.
///
/// Both obvious spellings fail somewhere:
///
/// - `@preconcurrency import Dispatch`, which the compiler itself suggests,
///   downgrades the error to a warning — and this package builds with
///   `treatAllWarnings(as: .error)`, so it returns as an error.
/// - `nonisolated(unsafe)` on the local is REQUIRED on Linux and diagnosed as
///   UNNECESSARY on Darwin, where the type already conforms. It is an error on
///   whichever platform you are not currently looking at.
///
/// So the discrepancy is absorbed once, here, by a type this package owns.
/// Dispatch sources are documented as safe to use from any thread — `cancel()`
/// included — so the missing conformance is a corelibs gap rather than something
/// this box is papering over.
///
/// `DispatchSourceProtocol` and not `DispatchSourceSignal`, so the same box
/// serves the signal sources in `TerminalLifecycle` / `TerminalSize` and the read
/// source behind `DoMoTUI`'s stdin stream.
public final class DispatchSourceBox: @unchecked Sendable {
    public let source: any DispatchSourceProtocol

    public init(_ source: any DispatchSourceProtocol) {
        self.source = source
    }

    /// Cancel the boxed source. The one operation every call site needs, so a
    /// caller does not have to reach through `source` and re-acquire the
    /// non-`Sendable` type it was boxed to avoid naming.
    public func cancel() {
        source.cancel()
    }
}
