//
//  LaneKnobValues.swift
//  Ultramix
//
//  The lane knobs where the audio thread can read them: all twelve in two
//  atomic words (LaneKnobMath.pack), a lane's pair always in the same one,
//  written by the main actor and read once per block.
//
//  One shared instance, handed to the playback engines' renderers only: a
//  bounce and an audition must not hear them. A renderer without it
//  (`MixRenderer.knobs == nil`) runs the code it ran before the knobs existed.
//

import Foundation
import Synchronization

nonisolated final class LaneKnobValues: Sendable {
    static let shared = LaneKnobValues()

    private let low: Atomic<UInt64>
    private let high: Atomic<UInt64>

    init(_ knobs: [KnobState] = KnobSetup.standard.slots.map { KnobState(function: $0.function, value: $0.function.neutral) }) {
        let words = LaneKnobMath.pack(knobs)
        low = Atomic(words.low)
        high = Atomic(words.high)
    }

    func store(_ knobs: [KnobState]) {
        let words = LaneKnobMath.pack(knobs)
        low.store(words.low, ordering: .relaxed)
        high.store(words.high, ordering: .relaxed)
    }

    func load() -> KnobWords {
        KnobWords(low: low.load(ordering: .relaxed), high: high.load(ordering: .relaxed))
    }
}
