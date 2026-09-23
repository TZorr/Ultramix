//
//  LaneKnobController.swift
//  Ultramix
//
//  The six lane knobs on the main actor: values, functions, CC assignments and
//  Learn. Written through to LaneKnobValues for the audio thread.
//
//  One for the app rather than one per session - the mix and the live set are
//  played with the same controller. Values are not remembered (every launch
//  starts neutral); the assignments are, per Mac.
//

import Foundation
import Observation

@Observable
final class LaneKnobController {
    static let shared = LaneKnobController()

    /// 0…127 per knob, lane by lane: A1, A2, B1, B2, C1, C2.
    private(set) var values: [Int]
    private(set) var setup: KnobSetup
    /// The knob waiting for Learn's next Control Change, if any.
    private(set) var learning: Int?

    /// Told of every change, by hand or by MIDI - the Rec button's ear.
    @ObservationIgnored var onChange: ((Int, Int) -> Void)?
    /// While Rec is armed the knobs are heard only through the automation
    /// they write, so the audio thread is handed neutral knobs: a knob that
    /// also still acted on its own would count twice.
    var monitorsThroughAutomation = false {
        didSet { if monitorsThroughAutomation != oldValue { publish() } }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let output: LaneKnobValues

    init(defaults: UserDefaults = .standard, output: LaneKnobValues = .shared,
         input: MIDIControllerInput? = .shared) {
        self.defaults = defaults
        self.output = output
        let setup = KnobSetup.load(defaults)
        self.setup = setup
        values = setup.slots.map(\.function.neutral)
        publish()
        input?.onControlChange = { [weak self] change in self?.handle(change) }
    }

    func state(_ slot: Int) -> KnobState {
        KnobState(function: setup.slots[slot].function, value: values[slot])
    }

    /// Sets a knob by hand or by MIDI, held to 0…127.
    func set(_ slot: Int, to value: Int) {
        let held = min(max(value, 0), 127)
        guard values.indices.contains(slot), values[slot] != held else { return }
        values[slot] = held
        publish()
        onChange?(slot, held)
    }

    /// Back to where the knob does nothing - a double-click.
    func reset(_ slot: Int) {
        set(slot, to: setup.slots[slot].function.neutral)
    }

    /// A new function starts at *its* neutral: a low-pass turned to 0 must
    /// not become a volume at 0 and silence the lane. The controller's knob
    /// then jumps on its next move - there is no pick-up.
    func setFunction(_ slot: Int, _ function: KnobFunction) {
        guard setup.slots.indices.contains(slot), setup.slots[slot].function != function else { return }
        setup.slots[slot].function = function
        values[slot] = function.neutral
        setup.save(defaults)
        publish()
    }

    /// Arms Learn for `slot`, or disarms it when it was already armed.
    func toggleLearn(_ slot: Int) {
        learning = learning == slot ? nil : slot
    }

    func cancelLearn() {
        learning = nil
    }

    func forget(_ slot: Int) {
        setup.forget(slot: slot)
        setup.save(defaults)
        if learning == slot { learning = nil }
    }

    /// A Control Change from a connected controller. While Learn is armed it
    /// is taken as the address - its value is not applied, the knob is not
    /// where the hand is yet in any sense that matters - and otherwise it
    /// moves every knob it is assigned to.
    func handle(_ change: MIDIControlChange) {
        if let slot = learning {
            setup.learn(slot: slot, from: change)
            setup.save(defaults)
            learning = nil
            return
        }
        for slot in setup.slots(matching: change) {
            set(slot, to: change.value)
        }
    }

    /// Every knob back to where it does nothing - after a recording, so
    /// the knobs do not come back on top of what they wrote.
    func resetAll() {
        values = setup.slots.map(\.function.neutral)
        publish()
    }

    private func publish() {
        output.store(values.indices.map { slot in
            monitorsThroughAutomation
                ? KnobState(function: setup.slots[slot].function, value: setup.slots[slot].function.neutral)
                : state(slot)
        })
    }
}
