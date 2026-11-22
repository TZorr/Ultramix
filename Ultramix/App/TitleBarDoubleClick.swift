//
//  TitleBarDoubleClick.swift
//  Ultramix
//
//  A double-click on the empty part of the title bar does what System
//  Settings › Desktop & Dock says - by default it zooms the window to fill
//  the screen between the menu bar and the Dock, and a second double-click
//  puts it back.
//
//  AppKit does this on its own in a plain window. In this one the toolbar is
//  SwiftUI's, spread over a NavigationSplitView and an inspector, and the
//  double-click never reaches the title bar. So it is caught here, before
//  any view sees it: only a double-click in the band above the content, and
//  only where no toolbar item is - a double-click on the transport, the meter
//  or a button stays theirs.
//

import AppKit

enum TitleBarDoubleClick {
    private static var monitor: Any?

    /// Once, at launch.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { handle(event) ? nil : event }
        }
    }

    /// True when the event was a title-bar double-click and has been acted on.
    @MainActor
    private static func handle(_ event: NSEvent) -> Bool {
        guard event.clickCount == 2,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let window = event.window,
              window.styleMask.contains(.titled),
              !window.styleMask.contains(.fullScreen),
              isOnEmptyTitleBar(event.locationInWindow, of: window)
        else { return false }

        switch action {
        case .zoom:
            guard window.styleMask.contains(.resizable) else { return false }
            window.performZoom(nil)
        case .minimize:
            guard window.styleMask.contains(.miniaturizable) else { return false }
            window.performMiniaturize(nil)
        case .none:
            break
        }
        return true
    }

    /// Above the content, and not on anything that takes a click itself.
    @MainActor
    private static func isOnEmptyTitleBar(_ point: NSPoint, of window: NSWindow) -> Bool {
        guard point.y >= window.contentLayoutRect.maxY,
              let frameView = window.contentView?.superview,
              var view = frameView.hitTest(frameView.convert(point, from: nil))
        else { return false }

        while true {
            if takesClicks(view) { return false }
            guard let parent = view.superview else { return true }
            view = parent
        }
    }

    /// A control, or a toolbar item's own view - SwiftUI hosts each item in a
    /// view of its own, which is no NSControl but takes the click all the
    /// same. The window's title and subtitle are labels, not controls: a
    /// double-click on them zooms, as everywhere else on the Mac.
    private static func takesClicks(_ view: NSView) -> Bool {
        if let label = view as? NSTextField, !label.isEditable, !label.isSelectable { return false }
        if view is NSControl { return true }
        let name = NSStringFromClass(type(of: view))
        return name.contains("Hosting") || name.contains("ToolbarItemViewer")
    }

    private enum Action { case zoom, minimize, none }

    /// System Settings › Desktop & Dock › "Double-click a window's title bar
    /// to". Unset means the default, which zooms.
    private static var action: Action {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        case nil: return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? .minimize : .zoom
        default: return .zoom   // "Maximize", "Fill"
        }
    }
}
