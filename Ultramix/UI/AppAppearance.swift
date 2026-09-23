//
//  AppAppearance.swift
//  Ultramix
//
//  Light, dark, or whatever the system says - independent of the system
//  setting, because a mix is often built in a dark room on a machine that is
//  light the rest of the day.
//
//  Applied through NSApp.appearance rather than preferredColorScheme: the
//  app-wide appearance also reaches what SwiftUI does not draw - panels,
//  alerts, menus - and going back to "System" really goes back.
//  preferredColorScheme(nil) does not undo an earlier explicit scheme on
//  macOS; NSApp.appearance = nil does.
//

import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.fill"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func apply() {
        NSApp.appearance = nsAppearance
    }
}
