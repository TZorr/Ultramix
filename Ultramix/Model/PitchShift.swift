//
//  PitchShift.swift
//  Ultramix
//
//  How far a clip plays from its file's pitch: whole semitones (Key) and a
//  fine tune in cents. One value because one render makes it - the key
//  shifter moves the audio by the sum - and one cache file holds it, so a
//  clip at +2 and +15 cents is not +2 shifted again by 15.
//

import Foundation

nonisolated struct PitchShift: Hashable, Sendable {
    var semitones: Int
    var cents: Int

    static let none = PitchShift(semitones: 0, cents: 0)

    var isNone: Bool { semitones == 0 && cents == 0 }

    /// The whole shift in semitones, as the key shifter takes it.
    var amount: Float { Float(semitones) + Float(cents) / 100 }

    /// "+2", "+2 +15 ct", "−25 ct" - for a clip's title.
    var label: String {
        let key = String(format: "%+d", semitones)
        let fine = String(format: "%+d ct", cents)
        switch (semitones, cents) {
        case (_, 0): return key
        case (0, _): return fine
        default: return "\(key) \(fine)"
        }
    }
}

nonisolated extension Clip {
    var pitch: PitchShift { PitchShift(semitones: keyShift, cents: fineTune) }
}
