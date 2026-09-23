//
//  MoveMode.swift
//  Ultramix
//
//  What dragging a clip snaps to: nothing, every beat, every half bar or every
//  bar. The arrow keys still move a beat at a time whatever is chosen; the
//  mode is about the mouse.
//

import Foundation

nonisolated enum MoveMode: String, CaseIterable, Identifiable, Sendable {
    case off, free, half, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .free: "Free"
        case .half: "Half"
        case .full: "Full"
        }
    }

    /// The step a dragged clip's bar one lands on, in beats; nil when
    /// dragging does not move clips.
    var step: Int? {
        switch self {
        case .off: nil
        case .free: 1
        case .half: Clip.beatsPerBar / 2
        case .full: Clip.beatsPerBar
        }
    }

    var help: String {
        switch self {
        case .off: "Dragging does not move clips"
        case .free: "Dragged clips land on any beat"
        case .half: "Dragged clips land on every half bar"
        case .full: "Dragged clips land on bar lines"
        }
    }

    static let storageKey = "moveMode"

    /// The mode chosen last on this Mac; Full, as dragging always was,
    /// until one has been chosen.
    static var current: MoveMode {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(MoveMode.init) ?? .full }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
