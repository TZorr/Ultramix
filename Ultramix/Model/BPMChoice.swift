//
//  BPMChoice.swift
//  Ultramix
//
//  Which tempo to use when the analysis may be an octave out. Whether a record
//  is 87 or 174 cannot be read from the audio - the kick pattern fits both - so
//  the measured value is offered at half, as it is and at double, and the one
//  nearest a few rough taps is suggested. Taps matching none of the three are
//  a wrong measurement, not a wrong octave, and are offered as they are.
//

import Foundation

nonisolated enum BPMChoice {
    struct Candidate: Equatable, Sendable, Identifiable {
        enum Kind: String, Sendable {
            case halfTime = "Half-time"
            case detected = "Detected"
            case doubleTime = "Double-time"
            case tap = "Tap"
        }

        var bpm: Double
        var kind: Kind
        var isSuggested = false

        var id: String { kind.rawValue }
    }

    /// How far the nearest octave may be from the taps and still count as
    /// what they meant.
    static let tapTolerance = 0.04

    static func candidates(detected: Double?, tapped: Double?) -> [Candidate] {
        guard let base = detected ?? tapped else { return [] }
        let range = TempoMap.bpmRange
        var list = [Candidate(bpm: base / 2, kind: .halfTime),
                    Candidate(bpm: base, kind: detected == nil ? .tap : .detected),
                    Candidate(bpm: base * 2, kind: .doubleTime)]
            .filter { range.contains($0.bpm) }
        if list.isEmpty {
            list = [Candidate(bpm: min(max(base, range.lowerBound), range.upperBound),
                              kind: detected == nil ? .tap : .detected)]
        }

        guard let tapped, detected != nil else {
            if let i = list.firstIndex(where: { $0.kind == .detected || $0.kind == .tap }) {
                list[i].isSuggested = true
            }
            return list
        }
        let distance = { (bpm: Double) in abs(log2(bpm / tapped)) }
        let nearest = list.indices.min { distance(list[$0].bpm) < distance(list[$1].bpm) }!
        if abs(list[nearest].bpm / tapped - 1) <= tapTolerance {
            list[nearest].isSuggested = true
        } else if range.contains(tapped) {
            list.append(Candidate(bpm: tapped, kind: .tap, isSuggested: true))
            list.sort { $0.bpm < $1.bpm }
        } else {
            list[nearest].isSuggested = true
        }
        return list
    }
}
