//
//  TransitionMoves.swift
//  Ultramix
//
//  What a transition does, kind by kind and side by side: how the outgoing
//  record's volume, low-pass, high-pass and pan move over the overlap, and how
//  the incoming one's do. Every preset style is a set of these moves
//  (`TransitionStyle.moves`); a custom transition is one chosen move by move
//  in the inspector.
//
//  A move is a named shape, not free numbers: the same handful the presets
//  are made of, so a custom transition sounds like a relative of the presets
//  and stays readable as words. Each is written as ordinary points by
//  `MixDocument.apply`, as the presets always were.
//
//  `t` runs from 0 at the start of the overlap to 1 at its end. Volume is a
//  gain from 0 to 1 of the lane's full level; the filters and pan are in
//  their own units (AutomationKind). On the outgoing side a move goes away
//  from neutral - a fade, a filter closing; on the incoming side it comes
//  back to it, the same shape mirrored in time.
//

import Foundation

/// Equal-power fall over the first `fraction` of the overlap, silence after.
nonisolated private func fall(_ t: Double, over fraction: Double = 1) -> Double { cos(min(t / fraction, 1) * .pi / 2) }

nonisolated enum VolumeMove: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, equalPower, linear, late40, late50, late75, quick, slow

    var id: String { rawValue }

    func title(incoming: Bool) -> String {
        switch self {
        case .none: "None"
        case .equalPower: incoming ? "Equal-power rise" : "Equal-power fade"
        case .linear: incoming ? "Linear rise" : "Linear fade"
        case .late40: incoming ? "Come in late (40 %)" : "Fade late (40 %)"
        case .late50: incoming ? "Come in late (50 %)" : "Fade late (50 %)"
        case .late75: incoming ? "Come in late (75 %)" : "Fade late (75 %)"
        case .quick: incoming ? "Quick rise" : "Quick drop"
        case .slow: incoming ? "Slow rise" : "Early fade"
        }
    }

    func value(_ t: Double, incoming: Bool) -> Double? {
        /// Outgoing: full until `hold`, then the equal-power fall over the
        /// rest. Incoming: silent until `hold`, then the equal-power rise.
        func late(_ hold: Double, _ t: Double) -> Double {
            if incoming { return t <= hold ? 0 : sin((t - hold) / (1 - hold) * .pi / 2) }
            return t <= hold ? 1 : cos((t - hold) / (1 - hold) * .pi / 2)
        }
        switch self {
        case .none: return nil
        case .equalPower: return incoming ? sin(t * .pi / 2) : fall(t)
        case .linear: return incoming ? t : 1 - t
        case .late40: return late(0.4, t)
        case .late50: return late(0.5, t)
        case .late75: return late(0.75, t)
        case .quick: return incoming ? sin(min(t / 0.25, 1) * .pi / 2) : fall(t, over: 0.25)
        case .slow: return incoming ? t * t : (1 - t) * (1 - t)
        }
    }
}

/// A low-pass closing as the outgoing record leaves, or opening as the
/// incoming one arrives. 1 is open.
nonisolated enum LowPassMove: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, gentle, deep, quick

    var id: String { rawValue }

    func title(incoming: Bool) -> String {
        switch self {
        case .none: "None"
        case .gentle: incoming ? "Open gently" : "Close gently"
        case .deep: incoming ? "Open from deep" : "Close deep"
        case .quick: incoming ? "Open late" : "Close quickly"
        }
    }

    func value(_ t: Double, incoming: Bool) -> Double? {
        let s = incoming ? 1 - t : t
        switch self {
        case .none: return nil
        case .gentle: return 1 - 0.75 * s
        case .deep: return 1 - 0.85 * s
        case .quick: return 1 - 0.6 * min(s / 0.4, 1)
        }
    }
}

/// A high-pass thinning the outgoing record, or the incoming one starting
/// thin and filling out. 0 is off.
nonisolated enum HighPassMove: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, gentle, quick

    var id: String { rawValue }

    func title(incoming: Bool) -> String {
        switch self {
        case .none: "None"
        case .gentle: incoming ? "Fill out gently" : "Thin gently"
        case .quick: incoming ? "Fill out late" : "Thin quickly"
        }
    }

    func value(_ t: Double, incoming: Bool) -> Double? {
        let s = incoming ? 1 - t : t
        switch self {
        case .none: return nil
        case .gentle: return 0.45 * s
        case .quick: return 0.6 * min(s / 0.4, 1)
        }
    }
}

/// Where the record sits while it changes hands. Absolute: the same on
/// either side.
nonisolated enum PanMove: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, centre, driftLeft, toLeft, driftRight, toRight, fromLeft, fromRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .centre: "Centre"
        case .driftLeft: "Drift left"
        case .toLeft: "Move to the left"
        case .driftRight: "Drift right"
        case .toRight: "Move to the right"
        case .fromLeft: "From the left to the centre"
        case .fromRight: "From the right to the centre"
        }
    }

    func value(_ t: Double) -> Double? {
        switch self {
        case .none: return nil
        case .centre: return 0
        case .driftLeft: return -0.8 * t
        case .toLeft: return -t
        case .driftRight: return 0.8 * t
        case .toRight: return t
        case .fromLeft: return -1 + t
        case .fromRight: return 1 - t
        }
    }
}

/// One record's part in a transition.
nonisolated struct TransitionSide: Codable, Equatable, Sendable {
    var volume: VolumeMove = .equalPower
    var lowPass: LowPassMove = .none
    var highPass: HighPassMove = .none
    var pan: PanMove = .none

    init(volume: VolumeMove = .equalPower, lowPass: LowPassMove = .none, highPass: HighPassMove = .none,
         pan: PanMove = .none) {
        self.volume = volume
        self.lowPass = lowPass
        self.highPass = highPass
        self.pan = pan
    }

    enum CodingKeys: String, CodingKey { case volume, lowPass, highPass, pan }

    /// A move this build does not know reads as none, rather than failing
    /// the mix.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func move<M: RawRepresentable>(_ key: CodingKeys, _: M.Type) -> M? where M.RawValue == String {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(M.init)
        }
        volume = move(.volume, VolumeMove.self) ?? .none
        lowPass = move(.lowPass, LowPassMove.self) ?? .none
        highPass = move(.highPass, HighPassMove.self) ?? .none
        pan = move(.pan, PanMove.self) ?? .none
    }
}

/// Both records' parts: a whole transition.
nonisolated struct TransitionMoves: Codable, Equatable, Sendable {
    var outgoing: TransitionSide
    var incoming: TransitionSide

    /// Per kind, the value at `t`; a kind that is missing is not moved.
    func recipe(incoming: Bool) -> [AutomationKind: (Double) -> Double] {
        let side = incoming ? self.incoming : outgoing
        var recipe: [AutomationKind: (Double) -> Double] = [:]
        if side.volume != .none { recipe[.volume] = { side.volume.value($0, incoming: incoming) ?? 1 } }
        if side.lowPass != .none { recipe[.lowPass] = { side.lowPass.value($0, incoming: incoming) ?? 1 } }
        if side.highPass != .none { recipe[.highPass] = { side.highPass.value($0, incoming: incoming) ?? 0 } }
        if side.pan != .none { recipe[.pan] = { side.pan.value($0) ?? 0 } }
        return recipe
    }
}

/// What a transition bar writes: one of the styles, or moves of its own.
nonisolated enum TransitionChoice: Equatable, Sendable {
    case preset(TransitionStyle)
    case custom(TransitionMoves)

    var moves: TransitionMoves {
        switch self {
        case .preset(let style): style.moves
        case .custom(let moves): moves
        }
    }

    var title: String {
        switch self {
        case .preset(let style): style.title
        case .custom: "Custom"
        }
    }
}

nonisolated extension TransitionStyle {
    /// Each style as moves - what the inspector shows for it, and where a
    /// custom transition starts from.
    var moves: TransitionMoves {
        switch self {
        case .crossfade:
            TransitionMoves(outgoing: TransitionSide(), incoming: TransitionSide())
        case .soft:
            TransitionMoves(outgoing: TransitionSide(volume: .linear), incoming: TransitionSide(volume: .linear))
        case .tape:
            TransitionMoves(outgoing: TransitionSide(lowPass: .gentle), incoming: TransitionSide())
        case .air:
            TransitionMoves(outgoing: TransitionSide(highPass: .gentle), incoming: TransitionSide())
        case .underwater:
            TransitionMoves(outgoing: TransitionSide(volume: .late50, lowPass: .deep),
                            incoming: TransitionSide(volume: .slow))
        case .telephone:
            TransitionMoves(outgoing: TransitionSide(volume: .late40, lowPass: .quick, highPass: .quick),
                            incoming: TransitionSide())
        case .stereoDrift:
            TransitionMoves(outgoing: TransitionSide(pan: .driftLeft), incoming: TransitionSide(pan: .centre))
        case .stereoHandoff:
            TransitionMoves(outgoing: TransitionSide(volume: .late75, pan: .toLeft),
                            incoming: TransitionSide(pan: .fromRight))
        case .filterReveal:
            TransitionMoves(outgoing: TransitionSide(), incoming: TransitionSide(volume: .quick, lowPass: .deep))
        }
    }
}
