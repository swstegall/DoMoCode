// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// A terminal colour that can be expressed without assuming true-colour
/// support. `inherit` intentionally emits no SGR sequence: the terminal then
/// keeps the colour supplied by the component underneath it.
public nonisolated enum ThemeColor: Sendable, Hashable, Codable {
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
    case ansiIndex(UInt8)
    case inherit

    /// The spelling used by theme files and by the built-in palette.
    public init?(specification: String) {
        let value = specification.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "none" || value == "inherit" {
            self = .inherit
            return
        }
        if value.hasPrefix("ansi:") || value.hasPrefix("index:") {
            let number = value.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            guard let index = UInt8(number) else { return nil }
            self = .ansiIndex(index)
            return
        }
        guard let rgb = Self.parseHex(value) else { return nil }
        self = .rgb(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public init?(hex: String) {
        self.init(specification: hex)
    }

    public static let none: ThemeColor = .inherit

    /// An ANSI foreground sequence, or the empty string for inherited colour.
    public func foreground(trueColor: Bool = true) -> String {
        switch self {
        case .inherit:
            return ""
        case .ansiIndex(let index):
            return "\u{1b}[38;5;\(index)m"
        case .rgb(let red, let green, let blue):
            if trueColor {
                return "\u{1b}[38;2;\(red);\(green);\(blue)m"
            }
            return "\u{1b}[38;5;\(Self.nearestANSIIndex(red: red, green: green, blue: blue))m"
        }
    }

    public func background(trueColor: Bool = true) -> String {
        switch self {
        case .inherit:
            return ""
        case .ansiIndex(let index):
            return "\u{1b}[48;5;\(index)m"
        case .rgb(let red, let green, let blue):
            if trueColor {
                return "\u{1b}[48;2;\(red);\(green);\(blue)m"
            }
            return "\u{1b}[48;5;\(Self.nearestANSIIndex(red: red, green: green, blue: blue))m"
        }
    }

    public func resolved(over fallback: ThemeColor) -> ThemeColor {
        self == .inherit ? fallback : self
    }

    private static func parseHex(_ value: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let expanded: String
        if digits.count == 3 {
            expanded = digits.map { String(repeating: String($0), count: 2) }.joined()
        } else {
            expanded = digits
        }
        guard expanded.count == 6,
              let red = UInt8(String(expanded.prefix(2)), radix: 16),
              let green = UInt8(String(expanded.dropFirst(2).prefix(2)), radix: 16),
              let blue = UInt8(String(expanded.dropFirst(4).prefix(2)), radix: 16)
        else { return nil }
        return (red, green, blue)
    }

    private static func nearestANSIIndex(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        // The xterm 6×6×6 cube is a useful deterministic fallback. It is not
        // presented as colourimetry; it merely keeps a true-colour theme usable
        // on a terminal that only advertises indexed colour.
        let r = UInt8((Int(red) * 5 + 127) / 255)
        let g = UInt8((Int(green) * 5 + 127) / 255)
        let b = UInt8((Int(blue) * 5 + 127) / 255)
        return 16 + 36 * r + 6 * g + b
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .inherit:
            try container.encode("none")
        case .ansiIndex(let index):
            try container.encode("ansi:\(index)")
        case .rgb(let red, let green, let blue):
            let digits = Array("0123456789abcdef")
            let text = "#\(digits[Int(red >> 4)])\(digits[Int(red & 0x0f)])"
                + "\(digits[Int(green >> 4)])\(digits[Int(green & 0x0f)])"
                + "\(digits[Int(blue >> 4)])\(digits[Int(blue & 0x0f)])"
            try container.encode(text)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let color = ThemeColor(specification: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid theme colour: \(value)"
            )
        }
        self = color
    }
}

/// The semantic colours a component can ask a theme for. Individual values may
/// be `none`; `resolved(over:)` fills those holes from the selected fallback.
///
/// The built-in palettes use concrete page backgrounds. A custom palette that
/// keeps `background` as ``ThemeColor/inherit`` is making an explicit choice to
/// preserve the terminal's background rather than relying on an accidental blank
/// cell in the renderer.
public nonisolated struct ThemePalette: Sendable, Hashable, Codable {
    public var foreground: ThemeColor
    public var accent: ThemeColor
    public var muted: ThemeColor
    public var error: ThemeColor
    public var warning: ThemeColor
    public var background: ThemeColor

    public init(
        foreground: ThemeColor = .inherit,
        accent: ThemeColor = .inherit,
        muted: ThemeColor = .inherit,
        error: ThemeColor = .inherit,
        warning: ThemeColor = .inherit,
        background: ThemeColor = .inherit
    ) {
        self.foreground = foreground
        self.accent = accent
        self.muted = muted
        self.error = error
        self.warning = warning
        self.background = background
    }

    public func resolved(over fallback: ThemePalette) -> ThemePalette {
        ThemePalette(
            foreground: foreground.resolved(over: fallback.foreground),
            accent: accent.resolved(over: fallback.accent),
            muted: muted.resolved(over: fallback.muted),
            error: error.resolved(over: fallback.error),
            warning: warning.resolved(over: fallback.warning),
            background: background.resolved(over: fallback.background)
        )
    }

    public static let dark = ThemePalette(
        foreground: ThemeColor(specification: "#d7dbe0")!,
        accent: ThemeColor(specification: "#78b7ff")!,
        muted: ThemeColor(specification: "#7f8791")!,
        error: ThemeColor(specification: "#ff6b6b")!,
        warning: ThemeColor(specification: "#f5c451")!,
        background: ThemeColor(specification: "#11161c")!
    )

    public static let light = ThemePalette(
        // A warm, slightly tinted page keeps the light theme comfortable in a
        // terminal while the foreground remains dark enough for body text.
        foreground: ThemeColor(specification: "#1c2228")!,
        accent: ThemeColor(specification: "#0b4f8a")!,
        muted: ThemeColor(specification: "#46515c")!,
        error: ThemeColor(specification: "#b42318")!,
        warning: ThemeColor(specification: "#7a3e00")!,
        background: ThemeColor(specification: "#eeeae2")!
    )

    public static let gruvboxDark = ThemePalette(
        foreground: ThemeColor(specification: "#ebdbb2")!,
        accent: ThemeColor(specification: "#83a598")!,
        muted: ThemeColor(specification: "#a89984")!,
        error: ThemeColor(specification: "#fb4934")!,
        warning: ThemeColor(specification: "#fabd2f")!,
        background: ThemeColor(specification: "#282828")!
    )

    public static let gruvboxLight = ThemePalette(
        foreground: ThemeColor(specification: "#3c3836")!,
        accent: ThemeColor(specification: "#076678")!,
        muted: ThemeColor(specification: "#665c54")!,
        error: ThemeColor(specification: "#9d0006")!,
        warning: ThemeColor(specification: "#b57614")!,
        background: ThemeColor(specification: "#fbf1c7")!
    )

    public static let solarizedDark = ThemePalette(
        foreground: ThemeColor(specification: "#839496")!,
        accent: ThemeColor(specification: "#268bd2")!,
        muted: ThemeColor(specification: "#586e75")!,
        error: ThemeColor(specification: "#dc322f")!,
        warning: ThemeColor(specification: "#b58900")!,
        background: ThemeColor(specification: "#002b36")!
    )

    public static let solarizedLight = ThemePalette(
        foreground: ThemeColor(specification: "#586e75")!,
        accent: ThemeColor(specification: "#268bd2")!,
        muted: ThemeColor(specification: "#657b83")!,
        error: ThemeColor(specification: "#dc322f")!,
        warning: ThemeColor(specification: "#b58900")!,
        background: ThemeColor(specification: "#fdf6e3")!
    )
}

public nonisolated enum ThemeAppearance: String, CaseIterable, Sendable, Hashable, Codable {
    case dark
    case light
    case gruvboxDark = "gruvbox-dark"
    case gruvboxLight = "gruvbox-light"
    case solarizedDark = "solarized-dark"
    case solarizedLight = "solarized-light"

    public var displayName: String {
        switch self {
        case .dark: return "dark"
        case .light: return "light"
        case .gruvboxDark: return "gruvbox-dark"
        case .gruvboxLight: return "gruvbox-light"
        case .solarizedDark: return "solarized-dark"
        case .solarizedLight: return "solarized-light"
        }
    }

    public var isDark: Bool {
        switch self {
        case .dark, .gruvboxDark, .solarizedDark: return true
        case .light, .gruvboxLight, .solarizedLight: return false
        }
    }
}

/// A complete theme with independent dark and light palettes.
public nonisolated struct Theme: Sendable, Hashable, Codable {
    public var dark: ThemePalette
    public var light: ThemePalette

    public init(dark: ThemePalette = .dark, light: ThemePalette = .light) {
        self.dark = dark
        self.light = light
    }

    public func palette(for appearance: ThemeAppearance) -> ThemePalette {
        switch appearance {
        case .dark: return dark
        case .light: return light
        case .gruvboxDark: return .gruvboxDark
        case .gruvboxLight: return .gruvboxLight
        case .solarizedDark: return .solarizedDark
        case .solarizedLight: return .solarizedLight
        }
    }

    public static let standard = Theme()
}
