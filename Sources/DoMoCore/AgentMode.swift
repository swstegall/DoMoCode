// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

/// The two execution modes exposed by the interactive surfaces.
///
/// This is deliberately a value in the core vocabulary. A mode is policy data
/// selected by the caller; it is not an extension point and it carries no
/// executable behavior.
public enum AgentMode: String, Codable, CaseIterable, Hashable, Sendable {
    case build
    case plan
}
