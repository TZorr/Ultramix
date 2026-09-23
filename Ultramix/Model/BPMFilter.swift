//
//  BPMFilter.swift
//  Ultramix
//
//  The library's tempo range. In the model rather than the panel so the
//  harness can hold its rules.
//
//  The bounds are inclusive and compared at the precision the BPM column
//  shows: a track listed as "125.00" is 125.004 underneath, and a range ending
//  at 125 must not hide it. The two bounds never cross - raising one past the
//  other takes it along.
//
//  Half and double tempo are an option, not the rule: a 62 BPM track mixes
//  into 124, but a list for 122-125 that also shows 250 BPM drum and bass is
//  wrong for anyone who did not ask for it.
//

import Foundation

nonisolated struct BPMFilter: Hashable {
    var isOn = false
    /// Also list tracks whose half or double tempo is in the range.
    var includesOctaves = false
    private(set) var lower: Double
    private(set) var upper: Double

    /// How far either side of a track's tempo "Around Selection" reaches.
    /// ±2 BPM is about ±1.6 % at 124: a pitch any mix takes unnoticed.
    static let aroundSpan = 2.0

    init(lower: Double = 122, upper: Double = 125, includesOctaves: Bool = false, isOn: Bool = false) {
        self.lower = Self.clamped(lower)
        self.upper = Self.clamped(upper)
        self.includesOctaves = includesOctaves
        self.isOn = isOn
        if self.upper < self.lower { self.upper = self.lower }
    }

    /// Whether a track at `bpm` is listed. Everything is while the filter is
    /// off; nothing unanalysed is while it is on, since there is no tempo to
    /// be in range.
    func matches(_ bpm: Double?) -> Bool {
        guard isOn else { return true }
        guard let bpm else { return false }
        let tempos = includesOctaves ? [bpm, bpm * 2, bpm / 2] : [bpm]
        let low = Self.displayed(lower), high = Self.displayed(upper)
        return tempos.contains { Self.displayed($0) >= low && Self.displayed($0) <= high }
    }

    /// The range ±`aroundSpan` about one tempo, as it is - 124.3 gives
    /// 122.30-126.30, not whole numbers, so the track itself sits in the
    /// middle.
    mutating func centre(on bpm: Double) {
        lower = Self.clamped(bpm - Self.aroundSpan)
        upper = Self.clamped(bpm + Self.aroundSpan)
    }

    mutating func setLower(_ value: Double) {
        lower = Self.clamped(value)
        if upper < lower { upper = lower }
    }

    mutating func setUpper(_ value: Double) {
        upper = Self.clamped(value)
        if lower > upper { lower = upper }
    }

    /// A stepper step lands on a whole BPM: 122.5 goes up to 123, not 123.5,
    /// because the ranges people look for are whole numbers.
    static func stepped(_ value: Double, by direction: Int) -> Double {
        let next = direction > 0 ? (value + 1e-9).rounded(.down) + 1 : (value - 1e-9).rounded(.up) - 1
        return clamped(next)
    }

    /// How a bound is written in its field: no decimals when it is whole.
    static func format(_ value: Double) -> String {
        displayed(value) == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound)
    }

    /// Rounded as the BPM column prints it.
    private static func displayed(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
