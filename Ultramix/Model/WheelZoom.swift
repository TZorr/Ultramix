//
//  WheelZoom.swift
//  Ultramix
//
//  Zooming the timeline with the mouse wheel: how far one wheel event zooms,
//  and where to scroll so the beat under the pointer stays under it. The
//  timeline (TimelinePanel) takes the events; this is the arithmetic, kept
//  apart so the harness can check it.
//
//  A wheel reports lines, a trackpad or Magic Mouse points (precise deltas);
//  40 points count as a line, so a flick on one zooms about as far as a few
//  notches on the other. Each line is 1.2×, and one event never zooms more
//  than four lines' worth - a fast spin on a free-wheeling mouse would
//  otherwise jump from bars to the whole mix in one go.
//
//  The direction is the hand's, not the system's: wheel away or fingers up
//  zooms in, whether or not natural scrolling turns the scroll deltas round.
//

import Foundation

nonisolated enum WheelZoom {
    static let factorPerLine = 1.2
    static let pointsPerLine = 40.0
    static let maxLinesPerEvent = 4.0
    /// Wheel events come faster than the scroll position follows a zoom, so
    /// the beat under the pointer is worked out once and held while the
    /// pointer stays put and the events keep coming.
    static let anchorHold: TimeInterval = 0.6

    /// The zoom factor for one wheel event. `deltaY` as the event reports it,
    /// `inverted` when the system turned it round (natural scrolling).
    static func factor(deltaY: Double, precise: Bool, inverted: Bool) -> Double {
        let physical = inverted ? -deltaY : deltaY
        let lines = precise ? physical / pointsPerLine : physical
        return pow(factorPerLine, min(max(lines, -maxLinesPerEvent), maxLinesPerEvent))
    }

    /// The scroll offset that puts `beat` at `x` in the view at the new zoom.
    static func scrollX(keeping beat: Double, at x: Double, pixelsPerBeat: Double, leadingPad: Double) -> Double {
        max(0, beat * pixelsPerBeat + leadingPad - x)
    }
}
