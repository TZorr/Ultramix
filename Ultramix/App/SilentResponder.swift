//
//  SilentResponder.swift
//  Ultramix
//
//  The end of every window's responder chain, so a key press nobody wants does
//  nothing instead of playing the system alert sound. A beep in the middle of
//  a live set is the one sound a DJ app must never make.
//
//  Nothing that works loses a key by this: menu key equivalents are dispatched
//  before the chain is walked, and every view, text field and `onKeyPress`
//  handler sits before this responder in it.
//

import AppKit

final class SilentResponder: NSResponder {
    private static let shared = SilentResponder()

    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func noResponder(for eventSelector: Selector) {}

    /// Appends the shared instance to the end of the window's chain, once.
    /// Safe to call again - on every change of key window, which also
    /// repairs a chain the window has rebuilt since.
    static func install(in window: NSWindow) {
        var last: NSResponder = window
        while let next = last.nextResponder {
            if next is SilentResponder { return }
            last = next
        }
        last.nextResponder = shared
    }
}
