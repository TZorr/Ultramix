//
//  Crossfade.swift
//  Ultramix
//
//  Automatic transitions, drawn from how the clips overlap: a clip on one lane
//  comes in while a clip on another still plays, and the transition covers
//  exactly that overlap - the user has already said how long by how far they
//  slid the clips over each other.
//
//  How it moves is a style. The plain crossfade is equal-power - in along sin,
//  out along cos - so two unrelated records keep their loudness through the
//  middle instead of dipping 3 dB as a linear crossfade does. Other styles add
//  the lane's filter or pan. Every style is written as ordinary points on the
//  two clips, so it can be reshaped by hand afterwards.
//
//  A style owns the overlap: applying one replaces the volume, pan, low-pass
//  and high-pass points there, so switching from Tape to Soft does not leave
//  Tape's filter behind. A kind the style does not move, on a clip with
//  nothing of that kind drawn, is left alone.
//
//  Two guard points per kind, a sixty-fourth of a beat outside the overlap,
//  hold the clip's curve as it was on either side. One lies just past the
//  clip's edge, hidden like a trimmed part, so the curve stays right should
//  the clip be extended there later.
//

import Foundation

nonisolated struct Transition: Equatable, Sendable {
    let outgoing: UUID
    let incoming: UUID
    let outgoingLane: Int
    let incomingLane: Int
    /// The overlap, in timeline beats.
    let start: Double
    let end: Double
}

nonisolated enum TransitionStyle: String, CaseIterable, Identifiable, Sendable {
    case crossfade, soft, tape, air, underwater, telephone, stereoDrift, stereoHandoff, filterReveal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crossfade: "Crossfade"
        case .soft: "Soft Fade"
        case .tape: "Tape Fade"
        case .air: "Air Fade"
        case .underwater: "Underwater"
        case .telephone: "Telephone"
        case .stereoDrift: "Stereo Drift"
        case .stereoHandoff: "Stereo Handoff"
        case .filterReveal: "Filter Reveal"
        }
    }

    var summary: String {
        switch self {
        case .crossfade: "Equal power: the loudness stays level through the middle."
        case .soft: "A straight fade down and up - the classic, unobtrusive handover."
        case .tape: "The outgoing song gets quieter and darker, as if it walked away."
        case .air: "The outgoing song loses its bass while it fades - for a next song that starts on a strong beat."
        case .underwater: "The outgoing song sinks under a low-pass and leaves late, while the next one comes up slowly."
        case .telephone: "The outgoing song thins to a small band - bass and treble cut - then fades."
        case .stereoDrift: "The outgoing song drifts to the left as it fades; the next one stays in the centre."
        case .stereoHandoff: "The outgoing song moves from the centre to the left, the next one comes in from the right to the centre."
        case .filterReveal: "The outgoing song fades while the next one opens up from a deep low-pass."
        }
    }

    /// One side of the transition: per kind, the value at `t` - 0 at the
    /// start of the overlap, 1 at its end. Volume is a gain from 0 to 1 of
    /// the lane's full level; pan and the filters are in their own units. A kind
    /// that is missing is not moved.
    func recipe(incoming: Bool) -> [AutomationKind: (Double) -> Double] {
        let fall: (Double) -> Double = { cos($0 * .pi / 2) }
        let rise: (Double) -> Double = { sin($0 * .pi / 2) }
        /// Holds full level until `hold`, then falls along the equal-power
        /// curve over what is left.
        func late(_ hold: Double) -> (Double) -> Double {
            { t in t <= hold ? 1 : cos((t - hold) / (1 - hold) * .pi / 2) }
        }
        switch (self, incoming) {
        case (.crossfade, false): return [.volume: fall]
        case (.crossfade, true): return [.volume: rise]
        case (.soft, false): return [.volume: { 1 - $0 }]
        case (.soft, true): return [.volume: { $0 }]
        case (.tape, false): return [.volume: fall, .lowPass: { 1 - 0.75 * $0 }]
        case (.air, false): return [.volume: fall, .highPass: { 0.45 * $0 }]
        case (.underwater, false): return [.volume: late(0.5), .lowPass: { 1 - 0.85 * $0 }]
        case (.underwater, true): return [.volume: { $0 * $0 }]
        case (.telephone, false):
            return [.volume: late(0.4), .highPass: { 0.6 * min($0 / 0.4, 1) },
                    .lowPass: { 1 - 0.6 * min($0 / 0.4, 1) }]
        case (.stereoDrift, false): return [.volume: fall, .pan: { -0.8 * $0 }]
        case (.stereoDrift, true): return [.volume: rise, .pan: { _ in 0 }]
        case (.stereoHandoff, false): return [.volume: late(0.75), .pan: { -$0 }]
        case (.stereoHandoff, true): return [.volume: rise, .pan: { 1 - $0 }]
        case (.filterReveal, false): return [.volume: fall]
        case (.filterReveal, true):
            return [.volume: { sin(min($0 / 0.25, 1) * .pi / 2) }, .lowPass: { 1 - 0.85 * (1 - $0) }]
        case (.tape, true), (.air, true), (.telephone, true): return [.volume: rise]
        }
    }
}

nonisolated extension MixDocument {
    /// Points per movement, ends included. Sixteen keeps the delayed shapes
    /// - Underwater's late fade, Filter Reveal's quick rise - round.
    static let crossfadeSteps = 16
    static let crossfadeGuard = 1.0 / 64

    /// Every place where one clip hands over to another on a different
    /// lane, in timeline order. A clip that starts and ends inside another
    /// is an overlay, not a transition, and is left alone.
    func transitions(_ grids: GridLookup) -> [Transition] {
        let placed = clips.compactMap { clip in geometry(clip, grids).map { (clip, $0) } }
        var result: [Transition] = []
        for (outgoing, out) in placed {
            for (incoming, into) in placed where incoming.lane != outgoing.lane {
                guard into.start > out.start + 1e-6, into.start < out.end - 1e-6, into.end > out.end + 1e-6 else { continue }
                result.append(Transition(outgoing: outgoing.id, incoming: incoming.id,
                                         outgoingLane: outgoing.lane, incomingLane: incoming.lane,
                                         start: into.start, end: out.end))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Writes `style` over every transition that involves one of `ids`, or
    /// over every transition when `ids` is nil. Returns how many. A locked
    /// clip keeps its automation: only the other side of its transition is
    /// written, and a transition locked on both sides is skipped.
    @discardableResult
    mutating func autoCrossfade(_ ids: Set<UUID>?, style: TransitionStyle = .crossfade, grids: GridLookup) throws -> Int {
        let chosen = transitions(grids).filter { transition in
            guard let ids else { return true }
            return ids.contains(transition.outgoing) || ids.contains(transition.incoming)
        }
        guard !chosen.isEmpty else {
            throw EditError(ids == nil
                ? "No clips overlap on different lanes, so there is nothing to cross-fade."
                : "The selected clip does not overlap a clip on another lane.")
        }
        let open = chosen.filter { editable($0.outgoing) != nil || editable($0.incoming) != nil }
        guard !open.isEmpty else {
            throw EditError(chosen.count == 1 ? "Both clips of the transition are locked."
                                              : "Every clip of these transitions is locked.")
        }
        for transition in open {
            apply(style, clip: transition.outgoing, from: transition.start, to: transition.end, incoming: false)
            apply(style, clip: transition.incoming, from: transition.start, to: transition.end, incoming: true)
        }
        return open.count
    }

    /// One side of a transition on one clip, every kind. `start` and `end`
    /// are timeline beats.
    private mutating func apply(_ style: TransitionStyle, clip id: UUID, from start: Double, to end: Double,
                                incoming: Bool) {
        guard let i = editable(id) else { return }
        let anchor = Double(clips[i].anchorBeat)
        let (localStart, localEnd) = (start - anchor, end - anchor)
        // The clip's level when fully in: what it was drawn at on the far
        // side of the fade - unless that was silence, in which case the
        // resting level, since fading to or from silence would be no fade.
        let reference = AutomationCurve(kind: .volume, automation: clips[i].automation)
            .value(at: incoming ? localEnd : localStart)
        let full = reference <= Automation.silenceDB + 0.5 ? Automation.defaultVolumeDB : reference
        let recipe = style.recipe(incoming: incoming)
        for kind in AutomationKind.allCases {
            write(kind, into: &clips[i].automation, from: localStart, to: localEnd, full: full, value: recipe[kind])
        }
    }

    /// Replaces a clip's points of `kind` over `start…end` (clip-local) with
    /// `value`, or - with no value - clears them, keeping the curve on either
    /// side.
    private func write(_ kind: AutomationKind, into automation: inout ClipAutomation, from start: Double,
                       to end: Double, full: Double, value: ((Double) -> Double)?) {
        let existing = automation.nodes(kind)
        guard value != nil || !existing.isEmpty else { return }
        let before = AutomationCurve(kind: kind, automation: automation)
        let margin = Self.crossfadeGuard
        var nodes = existing.filter { $0.beat < start - margin || $0.beat > end + margin }
        nodes.append(AutomationNode(beat: start - margin, value: before.value(at: start - margin)))
        nodes.append(AutomationNode(beat: end + margin, value: before.value(at: end + margin)))
        if let value {
            for step in 0...Self.crossfadeSteps {
                let t = Double(step) / Double(Self.crossfadeSteps)
                let raw = value(t)
                let stored: Double
                if kind == .volume {
                    stored = raw < 0.001 ? Automation.silenceDB : max(Automation.silenceDB, full + 20 * log10(raw))
                } else {
                    stored = min(max(raw, kind.range.lowerBound), kind.range.upperBound)
                }
                nodes.append(AutomationNode(beat: start + t * (end - start), value: stored))
            }
        }
        automation.setNodes(kind, nodes)
    }
}
