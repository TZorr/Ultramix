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

/// Whether the main window lets the desktop and its own content show through
/// its glass - the sidebar, the inspector, the toolbar and the bars - or is
/// drawn solid. On by default, the way macOS draws it; off for a ground that
/// does not change colour with whatever lies behind the window.
enum WindowSurface {
    static let opaqueKey = "opaqueWindow"
}

extension View {
    /// A sidebar or inspector column: the window's own ground under it while
    /// transparency is off, untouched while it is on. Switched through the
    /// colour rather than an `if`, so the column keeps its identity - the
    /// library table its scroll position - when the setting changes.
    func windowSurface() -> some View {
        modifier(WindowSurfaceModifier())
    }

    /// A bar along an edge: the system's bar material, or the window's
    /// ground while transparency is off.
    func barSurface() -> some View {
        modifier(BarSurfaceModifier())
    }

    /// The window's toolbar, drawn solid while transparency is off.
    func toolbarSurface() -> some View {
        modifier(ToolbarSurfaceModifier())
    }
}

private struct WindowSurfaceModifier: ViewModifier {
    @AppStorage(WindowSurface.opaqueKey) private var opaque = false

    func body(content: Content) -> some View {
        // The full column, not just the content's own height: the
        // inspector's "No Clip Selected" stood in a solid band otherwise.
        content
            .scrollContentBackground(opaque ? .hidden : .automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(opaque ? Color(nsColor: .windowBackgroundColor) : .clear)
    }
}

private struct BarSurfaceModifier: ViewModifier {
    @AppStorage(WindowSurface.opaqueKey) private var opaque = false

    func body(content: Content) -> some View {
        content.background(opaque ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.bar))
    }
}

private struct ToolbarSurfaceModifier: ViewModifier {
    @AppStorage(WindowSurface.opaqueKey) private var opaque = false

    func body(content: Content) -> some View {
        content
            .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
            .toolbarBackgroundVisibility(opaque ? .visible : .automatic, for: .windowToolbar)
    }
}
