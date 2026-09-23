//
//  AutomationRecording.swift
//  Ultramix
//
//  What the Rec button writes: the lane knobs' movements as ordinary clip
//  automation. Each knob function writes the automation kind of the same name
//  over that kind's whole range, so a recorded curve and a drawn one mean the
//  same thing.
//
//  Touch: a knob writes while its Control Changes arrive and lets go a moment
//  after the last, the curve returning to what was drawn before. A pass
//  replaces what lay under it and nothing else.
//
//  Only inside a clip, since automation belongs to the clip; a locked one
//  writes nothing. The pure rules are here where the harness can reach them;
//  KnobRecorder (App) listens to the knobs and the clock.
//

import Foundation

nonisolated extension KnobFunction {
    /// The automation kind a knob of this function records into.
    var automationKind: AutomationKind {
        switch self {
        case .lowPass: .lowPass
        case .highPass: .highPass
        case .pan: .pan
        case .volume: .volume
        }
    }

    /// A knob value, 0…127, as a value of `automationKind`, over the kind's
    /// whole range. Pan keeps the knob's law - 64 is exactly the centre, the
    /// halves are 64 and 63 steps - and volume runs along the fader taper, so
    /// the bottom is silence and the top +12 dB.
    func automationValue(_ knob: Int) -> Double {
        let v = min(max(knob, 0), 127)
        switch self {
        case .lowPass, .highPass:
            return Double(v) / 127
        case .pan:
            guard v != 64 else { return 0 }
            return v < 64 ? Double(v - 64) / 64 : Double(v - 64) / 63
        case .volume:
            return Automation.dB(faderTravel: Double(v) / 127)
        }
    }
}

nonisolated extension MixDocument {
    /// Closer than this, two recorded points on a steady knob say nothing
    /// the line between them does not; a sixteenth keeps a filter sweep
    /// smooth at any mixing tempo.
    static let touchSpacing = 1.0 / 16
    /// How long the curve takes to go back to what was drawn before, once a
    /// knob lets go. A jump would click; a quarter beat is a quick return.
    static let touchReturnBeats = 0.25

    /// Writes one touch pass on one clip: `samples` in timeline beats, in
    /// order. The nodes of `kind` between the first and the last sample -
    /// and, with `returnTo`, up to the end of the return - are replaced;
    /// gestures of `kind` the pass crosses are removed, since a gesture
    /// would cover what was recorded. Samples outside the clip's visible
    /// span are dropped: recording stays inside the region.
    ///
    /// A recorder calls this again with the whole pass so far on every
    /// flush, so the replaced range grows from the same start and writing
    /// the same pass twice changes nothing.
    ///
    /// - Parameter returnTo: the value to go back to after the last sample -
    ///   what the clip's curve had there before the pass; nil while the knob
    ///   is still being turned.
    /// - Returns: whether anything was written - false for a locked clip, no
    ///   such clip, or no sample inside it.
    @discardableResult
    mutating func writeTouch(clip id: UUID, kind: AutomationKind, samples: [AutomationNode],
                             returnTo: Double?, grids: GridLookup) -> Bool {
        guard let i = editable(id), let shape = geometry(clips[i], grids) else { return false }
        let anchor = Double(clips[i].anchorBeat)
        let range = kind.range
        let inside = samples.filter { $0.beat >= shape.start - 1e-9 && $0.beat <= shape.end + 1e-9 }
            .map { AutomationNode(beat: $0.beat - anchor, value: min(max($0.value, range.lowerBound), range.upperBound)) }
        guard let first = inside.first, let last = inside.last else { return false }

        // Thinned: a point is kept when the knob has moved and a sixteenth
        // has passed. Where it rested, the end of the rest is kept too, so
        // the curve holds there instead of sloping into the next movement.
        let still = (range.upperBound - range.lowerBound) * 0.005
        var kept: [AutomationNode] = []
        var skipped: AutomationNode?
        for node in inside {
            guard let previous = kept.last else { kept.append(node); continue }
            let moved = abs(node.value - previous.value) >= still
            guard moved, node.beat - previous.beat >= Self.touchSpacing else { skipped = node; continue }
            if let rest = skipped, abs(rest.value - previous.value) < still, rest.beat - previous.beat >= Self.touchSpacing {
                kept.append(rest)
            }
            kept.append(node)
            skipped = nil
        }
        if kept.last != last { kept.append(last) }

        let end = shape.end - anchor
        var through = last.beat
        if let returnTo, last.beat < end - 1e-9 {
            let back = min(last.beat + Self.touchReturnBeats, end)
            kept.append(AutomationNode(beat: back, value: min(max(returnTo, range.lowerBound), range.upperBound)))
            through = back
        }
        let outside = clips[i].automation.nodes(kind).filter { $0.beat < first.beat - 1e-9 || $0.beat > through + 1e-9 }
        clips[i].automation.setNodes(kind, outside + kept)
        clips[i].automation.gestures.removeAll { $0.kind == kind && $0.start <= through && $0.end >= first.beat }
        return true
    }
}
