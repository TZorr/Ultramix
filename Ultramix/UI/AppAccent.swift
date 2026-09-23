//
//  AppAccent.swift
//  Ultramix
//
//  The accent colour: the system's, or one chosen in Settings.
//
//  `Color.accentColor` is always the *system's* accent and ignores `.tint`, so
//  a chosen colour cannot simply be tinted onto the hierarchy and picked up by
//  what Ultramix draws itself. It travels in the environment as `\.accent`,
//  and `.tint` carries the same colour to the controls SwiftUI draws.
//
//  Stored as a six-digit sRGB hex string; the empty string means "whatever the
//  system says", which is also the default.
//

import SwiftUI
import AppKit

enum AppAccent {
    /// The setting's value while no colour has been chosen.
    static let system = ""

    static func color(_ hex: String) -> Color {
        guard let rgb = components(hex) else { return .accentColor }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// "RRGGBB" in sRGB. A colour that cannot be converted - a pattern, or a
    /// catalogue colour with no components - falls back to the system.
    static func hex(_ color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return system }
        let value = { (component: CGFloat) in Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", value(srgb.redComponent), value(srgb.greenComponent),
                      value(srgb.blueComponent))
    }

    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        HexColor.components(hex)
    }
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    /// The accent colour to draw with. Everything Ultramix paints itself
    /// reads this instead of `Color.accentColor`.
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}
