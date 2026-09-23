//
//  BPMInput.swift
//  Ultramix
//
//  Reading a tempo someone typed. In the model rather than in BPMField so the
//  harness can check it: what "12" or "124,5" becomes is a rule, and a rule
//  that lives only in a view goes untested.
//

import Foundation

nonisolated enum BPMInput {
    /// The tempo in `text`, clamped to what the tempo map allows; nil when it
    /// is not a number. A comma is read as the decimal point - on a German
    /// keyboard that is the key under the finger.
    static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return min(max(value, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound)
    }

    /// Tempos this far apart, as a ratio, are asked about before they are
    /// applied: a quarter faster or a fifth slower. A real correction of a
    /// track's grid is a few hundredths; the usual gross one is an octave,
    /// which has its own deliberate path (Correct BPM, ÷2 and ×2). A jump
    /// between the two - 124 to 40 because a "4" was confirmed on its own -
    /// is almost always a slip, and it changes the length of every clip of
    /// the track that is trimmed.
    static let largeChange: ClosedRange<Double> = 0.8...1.25

    /// Whether going from `old` to `new` is large enough to ask first.
    static func isLargeChange(from old: Double, to new: Double) -> Bool {
        guard old > 0, new > 0 else { return false }
        return !largeChange.contains(new / old)
    }
}
