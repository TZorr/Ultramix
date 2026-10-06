//
//  MusicalKey.swift
//  Ultramix
//
//  A key as the library shows it: its name and its Camelot code, the wheel DJs
//  mix by - the same number, or one either side with the same letter, mixes in
//  key.
//

import Foundation

nonisolated struct MusicalKey: Codable, Sendable, Hashable {
    /// Pitch class of the tonic, 0 = C … 11 = B.
    var tonic: Int
    var minor: Bool

    private static let names = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    private static let minorNames = ["Cm", "C♯m", "Dm", "E♭m", "Em", "Fm", "F♯m", "Gm", "G♯m", "Am", "B♭m", "Bm"]

    var name: String { minor ? Self.minorNames[tonic] : Self.names[tonic] }

    /// 1…12: each step round the wheel is a fifth. C major is 8B, A minor 8A.
    var camelotNumber: Int {
        ((7 * tonic) % 12 + (minor ? 4 : 7)) % 12 + 1
    }
    var camelot: String { "\(camelotNumber)\(minor ? "A" : "B")" }

    /// Round the wheel, the minor keys before the major ones of each number.
    var sortValue: Int { camelotNumber * 2 + (minor ? 0 : 1) }

    /// The key `semitones` higher (lower if negative). Seven semitones is one
    /// step round the Camelot wheel, one semitone seven steps.
    func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(tonic: ((tonic + semitones) % 12 + 12) % 12, minor: minor)
    }
}

/// What the key analysis found for a track.
nonisolated struct KeyAnalysis: Codable, Sendable, Equatable {
    var key: MusicalKey
    /// How far the best key's correlation is ahead of the next best.
    var margin: Double
    /// The `KeyAnalyzer` version that produced it.
    var version: Int

    /// Below this the library shows the key dimmed. Measured on 361 tracks
    /// carrying a key tag: in the quarter with the smallest margin (below
    /// 0.044) the analysis named the tag's key for 20 %, in the quarter with
    /// the largest for 59 %.
    static let uncertainBelow = 0.045
    var isUncertain: Bool { margin < Self.uncertainBelow }
}
