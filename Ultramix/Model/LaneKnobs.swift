//
//  LaneKnobs.swift
//  Ultramix
//
//  The two knobs in every lane header: what each does, how its value 0…127
//  turns into sound, and which MIDI Control Change turns it.
//
//  Live only: a knob acts on playback on top of the clip automation, never
//  reaches a bounce and is never saved, so the knobs start neutral at every
//  launch. Four functions per knob, picked in Settings - Low-Pass, High-Pass,
//  Pan, Volume; low-pass and high-pass are separate knobs rather than one
//  bipolar filter. The knob shows the CC value, not Hz or dB.
//
//  Every function has a neutral value at which it does *exactly* nothing -
//  gain 1, pan 1/1, the filter's wet at 0 - so a lane whose knobs rest is
//  bit-identical to one without knobs. The harness holds that.
//
//  Pure values only; the audio thread reads a packed copy (LaneKnobValues).
//

import Foundation

nonisolated enum KnobFunction: String, CaseIterable, Codable, Identifiable, Sendable {
    case lowPass = "lpf"
    case highPass = "hpf"
    case pan
    case volume

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowPass: "Low-Pass"
        case .highPass: "High-Pass"
        case .pan: "Pan"
        case .volume: "Volume"
        }
    }

    /// Under the knob. Three letters, because the header has room for no more.
    var short: String {
        switch self {
        case .lowPass: "LPF"
        case .highPass: "HPF"
        case .pan: "PAN"
        case .volume: "VOL"
        }
    }

    /// Where the knob does nothing: a low-pass wide open, a high-pass
    /// closed, pan in the middle, volume at full.
    var neutral: Int {
        switch self {
        case .lowPass: 127
        case .highPass: 0
        case .pan: 64
        case .volume: 127
        }
    }

    /// Pan fills its arc from the middle out.
    var bipolar: Bool { self == .pan }

    /// Two bits in the packed atomic.
    var code: UInt64 {
        switch self {
        case .lowPass: 0
        case .highPass: 1
        case .pan: 2
        case .volume: 3
        }
    }

    init(code: UInt64) {
        self = [.lowPass, .highPass, .pan, .volume][Int(code & 3)]
    }
}

/// One knob as the audio thread sees it.
nonisolated struct KnobState: Equatable, Sendable {
    var function: KnobFunction
    var value: Int
}

nonisolated enum LaneKnobMath {
    static let knobsPerLane = 2
    static let slotCount = Clip.laneCount * knobsPerLane
    static let valueRange = 0...127

    static func slot(lane: Int, knob: Int) -> Int { lane * knobsPerLane + knob }

    /// The lane filter position (see MixRenderer's Biquad: −1 low-pass …
    /// +1 high-pass) this knob asks for, or 0 for a knob that is not a
    /// filter. A low-pass closes from 127 (open, exactly 0) down to 0
    /// (~90 Hz); a high-pass opens from 0 (off) to 127 (~12 kHz).
    static func filterPosition(_ knob: KnobState) -> Double {
        let v = Double(min(max(knob.value, 0), 127))
        switch knob.function {
        case .lowPass: return AutomationKind.filterPosition(lowPass: v / 127)
        case .highPass: return AutomationKind.filterPosition(highPass: v / 127)
        case .pan, .volume: return 0
        }
    }

    /// Left and right gain factors. Volume is a squared taper - 127 is
    /// exactly 1, 64 about −12 dB, 0 silence - so the lower half of the
    /// travel is not all near-silent, as a linear one would be in dB.
    /// Pan is the automation's balance law (MixRenderer's LaneState): the
    /// middle is unity on both sides, and turning away lowers the other
    /// side only, on an equal-power curve. 64 is the middle, so the two
    /// halves are 64 and 63 steps.
    static func gains(_ knob: KnobState) -> (left: Double, right: Double) {
        let v = min(max(knob.value, 0), 127)
        switch knob.function {
        case .volume:
            let g = Double(v) / 127
            return (g * g, g * g)
        case .pan:
            // Exactly unity at the centre, not √2·cos(π/4), which rounds.
            guard v != 64 else { return (1, 1) }
            let pan = v < 64 ? Double(v - 64) / 64 : Double(v - 64) / 63
            let theta = (pan + 1) * Double.pi / 4
            return (min(1, 2.0.squareRoot() * cos(theta)), min(1, 2.0.squareRoot() * sin(theta)))
        case .lowPass, .highPass:
            return (1, 1)
        }
    }

    /// All six knobs in one 64-bit word, ten bits each: the value in the low
    /// seven, the function in the next two. One word so the audio thread
    /// reads every knob with one atomic load, and never half an update.
    static func pack(_ knobs: [KnobState]) -> UInt64 {
        var word: UInt64 = 0
        for (index, knob) in knobs.prefix(slotCount).enumerated() {
            let bits = UInt64(min(max(knob.value, 0), 127)) | knob.function.code << 7
            word |= bits << UInt64(index * 10)
        }
        return word
    }

    static func unpack(_ word: UInt64, slot: Int) -> KnobState {
        let bits = word >> UInt64(slot * 10)
        return KnobState(function: KnobFunction(code: bits >> 7), value: Int(bits & 0x7F))
    }
}

/// What one knob does and which Control Change turns it. The channel and
/// controller are nil until Learn has heard one.
nonisolated struct KnobAssignment: Codable, Equatable, Sendable {
    var function: KnobFunction
    var channel: Int?
    var controller: Int?

    var isAssigned: Bool { channel != nil && controller != nil }

    func matches(_ change: MIDIControlChange) -> Bool {
        channel == change.channel && controller == change.controller
    }

    /// "CC 21 · Ch 1", or "–" before Learn.
    var label: String {
        guard let channel, let controller else { return "–" }
        return "CC \(controller) · Ch \(channel)"
    }
}

/// The six assignments, kept per Mac: a controller belongs to the desk it
/// sits on, not to a working directory or a mix.
nonisolated struct KnobSetup: Codable, Equatable, Sendable {
    /// UserDefaults key. Stored as JSON **Data** - a String written in its
    /// place reads back as nothing and the setup silently empties.
    static let storageKey = "laneKnobSetup"

    var slots: [KnobAssignment]

    /// Knob 1 a low-pass, knob 2 a high-pass on every lane, nothing learned.
    static let standard = KnobSetup(slots: (0..<LaneKnobMath.slotCount).map {
        KnobAssignment(function: $0 % LaneKnobMath.knobsPerLane == 0 ? .lowPass : .highPass)
    })

    /// Points `slot` at this Control Change, and takes it away from any
    /// other knob that had it: one CC turning two knobs would be a surprise
    /// found in the middle of a set, and learning is how one says which.
    mutating func learn(slot: Int, from change: MIDIControlChange) {
        guard slots.indices.contains(slot) else { return }
        for index in slots.indices where index != slot && slots[index].matches(change) {
            slots[index].channel = nil
            slots[index].controller = nil
        }
        slots[slot].channel = change.channel
        slots[slot].controller = change.controller
    }

    mutating func forget(slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot].channel = nil
        slots[slot].controller = nil
    }

    /// The knobs this Control Change turns - one, after Learn.
    func slots(matching change: MIDIControlChange) -> [Int] {
        slots.indices.filter { slots[$0].matches(change) }
    }

    static func load(_ defaults: UserDefaults = .standard) -> KnobSetup {
        guard let data = defaults.data(forKey: storageKey),
              let setup = try? JSONDecoder().decode(KnobSetup.self, from: data),
              setup.slots.count == LaneKnobMath.slotCount else { return .standard }
        return setup
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
