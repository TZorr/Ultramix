//
//  LoudnessTarget.swift
//  Ultramix
//
//  The optional loudness target from Settings: while it is on, every clip
//  plays at one LUFS value and its gain becomes an offset from it.
//
//  Per Mac, not per mix: the mix keeps the gains set by hand, so switching the
//  target off gives them back exactly. A bounce made while it is on follows
//  it.
//

import Foundation

nonisolated enum LoudnessTarget {
    static let enabledKey = "loudnessTargetEnabled"
    static let lufsKey = "loudnessTargetLUFS"
    static let defaultLUFS = -14.0
    static let range: ClosedRange<Double> = -30.0 ... -5.0

    /// Held to the range; anything that is not a number is the default.
    static func clamped(_ lufs: Double) -> Double {
        lufs.isFinite ? min(max(lufs, range.lowerBound), range.upperBound) : defaultLUFS
    }

    /// The target, or nil while the option is off.
    static func current(_ defaults: UserDefaults = .standard) -> Double? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        return clamped(defaults.object(forKey: lufsKey) as? Double ?? defaultLUFS)
    }
}
