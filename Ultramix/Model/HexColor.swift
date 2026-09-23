//
//  HexColor.swift
//  Ultramix
//
//  Colours as six-digit sRGB hex strings, the form they are stored in - lane
//  colours in a mix, the accent in the preferences. A string rather than
//  components: it reads back in a JSON file or a defaults dump and cannot
//  drift through a colour-space conversion.
//
//  Free of SwiftUI so the harness can reach it, the contrast ratio included:
//  what counts as too faint against the timeline is a rule that should be
//  measured, not eyeballed.
//

import Foundation

nonisolated enum HexColor {
    /// "RRGGBB", with or without a leading "#", in either case. Anything
    /// else - five digits, a sign, a stray letter - is not a colour.
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        // `Int(_:radix:)` alone would take "+12345" as a number.
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = Int(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// The one spelling that is stored: six upper-case digits, no "#".
    static func normalized(_ hex: String) -> String? {
        guard let rgb = components(hex) else { return nil }
        let value = { (component: Double) in Int((component * 255).rounded()) }
        return String(format: "%02X%02X%02X", value(rgb.red), value(rgb.green), value(rgb.blue))
    }

    /// WCAG 2 relative luminance.
    static func luminance(_ hex: String) -> Double? {
        guard let rgb = components(hex) else { return nil }
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// WCAG 2 contrast ratio, 1 to 21. Non-text interface parts need 3.
    static func contrastRatio(_ a: String, _ b: String) -> Double? {
        guard let la = luminance(a), let lb = luminance(b) else { return nil }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
