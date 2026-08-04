// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT

import Foundation

/// A portable custom-theme document. The document carries a fallback palette so
/// inherited colors and backgrounds are resolved before a client renders it.
public nonisolated struct ThemeDocument: Sendable, Codable, Hashable {
    public var schemaVersion: Int
    public var id: String
    public var displayName: String
    public var theme: Theme
    public var fallback: ThemePalette

    public init(
        schemaVersion: Int = 1,
        id: String,
        displayName: String,
        theme: Theme,
        fallback: ThemePalette = .standardFallback
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.theme = theme
        self.fallback = fallback
    }

    public func resolvedTheme() -> Theme {
        Theme(
            dark: theme.dark.resolved(over: fallback),
            light: theme.light.resolved(over: fallback)
        )
    }
}

public nonisolated struct ThemeContrastResult: Sendable, Codable, Hashable {
    public let appearance: String
    public let foreground: Double
    public let accent: Double
    public let muted: Double
    public let error: Double
    public let warning: Double

    public init(
        appearance: String,
        foreground: Double,
        accent: Double,
        muted: Double,
        error: Double,
        warning: Double
    ) {
        self.appearance = appearance
        self.foreground = foreground
        self.accent = accent
        self.muted = muted
        self.error = error
        self.warning = warning
    }

    public var minimum: Double {
        min(foreground, accent, muted, error, warning)
    }
}

public nonisolated struct ThemeValidationReport: Sendable, Codable, Hashable {
    public let contrasts: [ThemeContrastResult]
    public let issues: [String]

    public init(contrasts: [ThemeContrastResult], issues: [String] = []) {
        self.contrasts = contrasts
        self.issues = issues
    }

    public var isAccessible: Bool { issues.isEmpty }
}

public nonisolated enum ThemeDocumentError: Error, Sendable, Equatable {
    case invalid(String)
    case inaccessible(ThemeValidationReport)
}

public nonisolated struct ThemeRenderCapabilities: Sendable, Codable, Hashable {
    public var trueColor: Bool

    public init(trueColor: Bool = true) {
        self.trueColor = trueColor
    }
}

public nonisolated enum ThemeDocumentCodec {
    public static func encode(_ document: ThemeDocument) throws(ThemeDocumentError) -> Data {
        try validate(document)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return try encoder.encode(document)
        } catch {
            throw .invalid("Could not encode theme document.")
        }
    }

    public static func decode(_ data: Data) throws(ThemeDocumentError) -> ThemeDocument {
        do {
            let document = try JSONDecoder().decode(ThemeDocument.self, from: data)
            try validate(document)
            return document
        } catch let error as ThemeDocumentError {
            throw error
        } catch {
            throw .invalid("Could not decode theme document.")
        }
    }

    @discardableResult
    public static func validate(
        _ document: ThemeDocument
    ) throws(ThemeDocumentError) -> ThemeValidationReport {
        guard document.schemaVersion == 1 else {
            throw .invalid("Unsupported theme schema version.")
        }
        guard !document.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !document.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw .invalid("Theme id and displayName must not be empty.")
        }

        let resolved = document.resolvedTheme()
        let contrasts = [
            contrastResult(resolved.dark, appearance: "dark"),
            contrastResult(resolved.light, appearance: "light"),
        ]
        let issues = contrasts.flatMap { result -> [String] in
            result.minimum >= 4.5
                ? []
                : ["\(result.appearance) palette does not meet 4.5:1 text contrast."]
        }
        let report = ThemeValidationReport(contrasts: contrasts, issues: issues)
        guard report.isAccessible else { throw .inaccessible(report) }
        return report
    }

    private static func contrastResult(
        _ palette: ThemePalette,
        appearance: String
    ) -> ThemeContrastResult {
        ThemeContrastResult(
            appearance: appearance,
            foreground: contrast(palette.foreground, palette.background),
            accent: contrast(palette.accent, palette.background),
            muted: contrast(palette.muted, palette.background),
            error: contrast(palette.error, palette.background),
            warning: contrast(palette.warning, palette.background)
        )
    }

    private static func contrast(_ foreground: ThemeColor, _ background: ThemeColor) -> Double {
        guard let foreground = rgb(foreground), let background = rgb(background) else {
            return 21
        }
        let first = luminance(foreground)
        let second = luminance(background)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func rgb(_ color: ThemeColor) -> (Double, Double, Double)? {
        switch color {
        case .rgb(let red, let green, let blue):
            (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
        case .ansiIndex, .inherit:
            nil
        }
    }

    private static func luminance(_ color: (Double, Double, Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.0) + 0.7152 * channel(color.1) + 0.0722 * channel(color.2)
    }
}

public extension ThemeColor {
    /// Converts RGB colors to a deterministic indexed fallback when a terminal
    /// does not advertise true-color support. ANSI colors remain unchanged.
    nonisolated func adapted(for capabilities: ThemeRenderCapabilities) -> ThemeColor {
        guard !capabilities.trueColor else { return self }
        switch self {
        case .rgb(let red, let green, let blue):
            return .ansiIndex(Self.nearestANSIIndexForCapabilities(red: red, green: green, blue: blue))
        case .ansiIndex, .inherit:
            return self
        }
    }

    private nonisolated static func nearestANSIIndexForCapabilities(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        let r = UInt8((Int(red) * 5 + 127) / 255)
        let g = UInt8((Int(green) * 5 + 127) / 255)
        let b = UInt8((Int(blue) * 5 + 127) / 255)
        return 16 + 36 * r + 6 * g + b
    }
}

public extension ThemePalette {
    nonisolated func adapted(for capabilities: ThemeRenderCapabilities) -> ThemePalette {
        ThemePalette(
            foreground: foreground.adapted(for: capabilities),
            accent: accent.adapted(for: capabilities),
            muted: muted.adapted(for: capabilities),
            error: error.adapted(for: capabilities),
            warning: warning.adapted(for: capabilities),
            background: background.adapted(for: capabilities)
        )
    }

    nonisolated static let standardFallback = ThemePalette(
        foreground: .rgb(red: 0xd7, green: 0xdb, blue: 0xe0),
        accent: .rgb(red: 0x78, green: 0xb7, blue: 0xff),
        muted: .rgb(red: 0x7f, green: 0x87, blue: 0x91),
        error: .rgb(red: 0xff, green: 0x6b, blue: 0x6b),
        warning: .rgb(red: 0xf5, green: 0xc4, blue: 0x51),
        background: .rgb(red: 0x11, green: 0x16, blue: 0x1c)
    )
}
