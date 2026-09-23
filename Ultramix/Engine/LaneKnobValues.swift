//
//  LaneKnobValues.swift
//  Ultramix
//
//  The lane knobs where the audio thread can read them: all six in one atomic
//  word (LaneKnobMath.pack), written by the main actor and read once per block.
//
//  One shared instance, handed to the playback engines' renderers only: a
//  bounce and an audition must not hear them. A renderer without it
//  (`MixRenderer.knobs == nil`) runs the code it ran before the knobs existed.
//

import Foundation
import Synchronization

nonisolated final class LaneKnobValues: Sendable {
    static let shared = LaneKnobValues()

    private let word: Atomic<UInt64>

    init(_ knobs: [KnobState] = KnobSetup.standard.slots.map { KnobState(function: $0.function, value: $0.function.neutral) }) {
        word = Atomic(LaneKnobMath.pack(knobs))
    }

    func store(_ knobs: [KnobState]) {
        word.store(LaneKnobMath.pack(knobs), ordering: .relaxed)
    }

    func load() -> UInt64 {
        word.load(ordering: .relaxed)
    }
}
