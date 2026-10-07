//
//  Automation.swift
//  Ultramix
//
//  Volume, pan, low-pass and high-pass curves drawn on clips.
//
//  Low-pass and high-pass are separate lanes, not one bipolar filter: a band,
//  and a sweep handing one filter to the other, need both at once. Mixes saved
//  with the old bipolar filter open without it; nothing is converted.
//
//  Automation belongs to the clip and exists only inside it. On the lane, in
//  timeline beats, every clip edit had to keep it in step by hand, and what
//  those rules missed was left standing over empty lane where nothing could
//  select it. On the clip, in clip beats, a move, copy and delete carry it
//  with no rule at all.
//
//  Positions are clip-local beats: timeline beat − `Clip.anchorBeat`, so bar
//  one is 0 and the pre-roll is negative. Beats, not seconds, so the tempo map
//  stretches a curve with the music it was drawn against. What a trim hides
//  stays stored and silent; a looping clip has one curve across its length.
//
//  Nodes are exact points. A gesture (step, sine or triangle across a range)
//  is one object with a shape, a period and two levels, stored as that
//  description rather than the hundreds of points it evaluates to, so it can
//  be deleted in one click and is expanded only when the plan is built. Within
//  a gesture's range the gesture wins over nodes.
//

import Foundation

nonisolated enum AutomationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case volume, pan
    /// 0…1: 1 is open (the top of the lane), 0 the lowest cutoff.
    case lowPass = "lpf"
    /// 0…1: 0 is off (the bottom of the lane), 1 the highest cutoff.
    case highPass = "hpf"
    var id: String { rawValue }

    /// The value a lane has where nothing is drawn - for the filters, out
    /// of the circuit.
    var restValue: Double {
        switch self {
        case .volume: Automation.defaultVolumeDB
        case .pan: 0
        case .lowPass: 1
        case .highPass: 0
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .volume: Automation.silenceDB...Automation.maxVolumeDB
        case .pan: -1...1
        case .lowPass, .highPass: 0...1
        }
    }

    var isFilter: Bool { self == .lowPass || self == .highPass }

    /// The filter position `Biquad.design` takes: negative is low-pass,
    /// positive high-pass, 0 out. The lane knobs map through the same, so a
    /// recorded knob and a drawn curve at the same value sound the same.
    static func filterPosition(lowPass value: Double) -> Double {
        let v = min(max(value, 0), 1)
        return v >= 1 ? 0 : -(1 - v)
    }

    static func filterPosition(highPass value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

nonisolated struct AutomationNode: Codable, Sendable, Equatable {
    var beat: Double
    /// dB for volume (`silenceDB` is −∞), −1…+1 for pan (left…right), 0…1
    /// for the two filters.
    var value: Double
    /// Bend of the segment that starts at this node, −1…+1; 0 is a straight
    /// line. Used by the filter, where a sweep that lingers and then rushes is
    /// the common case.
    var tension: Double

    init(beat: Double, value: Double, tension: Double = 0) {
        self.beat = beat
        self.value = value
        self.tension = tension
    }

    enum CodingKeys: String, CodingKey { case beat, value, tension }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beat = try c.decode(Double.self, forKey: .beat)
        value = try c.decode(Double.self, forKey: .value)
        tension = try c.decodeIfPresent(Double.self, forKey: .tension) ?? 0
    }
}

nonisolated enum GestureShape: String, Codable, Sendable, CaseIterable, Identifiable {
    case step, sine, triangle
    var id: String { rawValue }
}

/// One drawn movement: a shape repeated across a range.
nonisolated struct AutomationGesture: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var kind: AutomationKind
    var start: Double
    var end: Double
    var shape: GestureShape
    /// Length of one cycle, in beats.
    var period: Double
    /// The two levels the movement swings between, in the kind's units.
    var low: Double
    var high: Double

    init(id: UUID = UUID(), kind: AutomationKind, start: Double, end: Double,
         shape: GestureShape, period: Double, low: Double, high: Double) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.shape = shape
        self.period = period
        self.low = low
        self.high = high
    }

    /// The gesture's value at `beat`, which must lie inside it.
    func value(at beat: Double) -> Double {
        let phase = ((beat - start) / max(period, 1e-6)).truncatingRemainder(dividingBy: 1)
        let unit: Double
        switch shape {
        // High for the first half of each cycle: a gate that opens on the
        // beat, which is what a stepped volume or pan movement is for.
        case .step: unit = phase < 0.5 ? 1 : 0
        // Starts at the low level, so a sine drawn over a fade-in begins
        // where the fade does rather than half way up.
        case .sine: unit = 0.5 - 0.5 * cos(2 * .pi * phase)
        case .triangle: unit = phase < 0.5 ? phase * 2 : 2 - phase * 2
        }
        return low + (high - low) * unit
    }
}

nonisolated enum Automation {
    /// Where a lane rests when no volume is drawn. Three full-scale tracks
    /// summed need headroom; −4 dB leaves it and still lets one track alone
    /// sound like a finished record.
    static let defaultVolumeDB = -4.0
    static let maxVolumeDB = 12.0
    /// The bottom of the volume range, meaning silence. Inside a ramp it
    /// counts as −60 dB, so a fade-out follows a musical curve rather than
    /// falling off a cliff at the last moment.
    static let silenceDB = -60.0

    /// Linear gain of a dB value, with the floor meaning exactly zero.
    static func gain(dB: Double) -> Double {
        dB <= silenceDB ? 0 : pow(10, dB / 20)
    }

    // MARK: Fader taper
    //
    // The volume lane is drawn like a console fader, not like a ruler. Unity
    // sits in the middle of the lane, +12 dB at the top, and the lower half
    // runs from 0 dB down to −40 dB and then silence. A ruler would spread
    // those 40 dB evenly, which puts −20 dB half way down the lower half - a
    // tenth of the amplitude where the hand expects "half as loud" - and
    // leaves the last decibel below unity, where most of the work happens,
    // a few pixels tall. Squaring the distance from unity puts that half-way
    // point at −10 dB and makes the region just under 0 dB ten times finer.
    // The engine only ever sees decibels; this is purely how they are drawn.

    /// Travel 0…1 of a volume in dB. 0.5 is unity.
    static func faderTravel(dB: Double) -> Double {
        if dB >= 0 { return 0.5 + 0.5 * min(dB, maxVolumeDB) / maxVolumeDB }
        let bottom = -40.0
        if dB <= bottom { return 0 }
        return 0.5 * (1 - (dB / bottom).squareRoot())
    }

    /// Inverse of `faderTravel`. The bottom of the travel is silence.
    static func dB(faderTravel travel: Double) -> Double {
        if travel >= 0.5 { return (travel - 0.5) / 0.5 * maxVolumeDB }
        if travel <= 0.001 { return silenceDB }
        let x = 1 - travel / 0.5
        return -40 * x * x
    }
}

/// Everything drawn on one clip, in clip-local beats.
nonisolated struct ClipAutomation: Codable, Sendable, Equatable {
    var volume: [AutomationNode] = []
    var pan: [AutomationNode] = []
    var lowPass: [AutomationNode] = []
    var highPass: [AutomationNode] = []
    var gestures: [AutomationGesture] = []
    /// The bars over the transitions written here (TransitionMarks.swift).
    var transitions: [TransitionMark] = []

    init() {}

    var isEmpty: Bool {
        volume.isEmpty && pan.isEmpty && lowPass.isEmpty && highPass.isEmpty && gestures.isEmpty
            && transitions.isEmpty
    }

    func nodes(_ kind: AutomationKind) -> [AutomationNode] {
        switch kind {
        case .volume: volume
        case .pan: pan
        case .lowPass: lowPass
        case .highPass: highPass
        }
    }

    /// Sorts by beat and keeps the given order among nodes on the same beat:
    /// two of them make a step (a beatmix's cut), and which comes first is
    /// the whole of what the step means. `sorted` does not promise that.
    mutating func setNodes(_ kind: AutomationKind, _ nodes: [AutomationNode]) {
        let sorted = nodes.enumerated()
            .sorted { $0.element.beat != $1.element.beat ? $0.element.beat < $1.element.beat : $0.offset < $1.offset }
            .map(\.element)
        switch kind {
        case .volume: volume = sorted
        case .pan: pan = sorted
        case .lowPass: lowPass = sorted
        case .highPass: highPass = sorted
        }
    }

    /// An old mix's `filter` key is simply not asked for; keyed decoding
    /// passes over it.
    enum CodingKeys: String, CodingKey {
        case volume, pan, gestures, transitions
        case lowPass = "lpf", highPass = "hpf"
    }

    /// Empty kinds leave no key, so a clip with a fade and nothing else
    /// saves one array rather than four.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !volume.isEmpty { try c.encode(volume, forKey: .volume) }
        if !pan.isEmpty { try c.encode(pan, forKey: .pan) }
        if !lowPass.isEmpty { try c.encode(lowPass, forKey: .lowPass) }
        if !highPass.isEmpty { try c.encode(highPass, forKey: .highPass) }
        if !gestures.isEmpty { try c.encode(gestures, forKey: .gestures) }
        if !transitions.isEmpty { try c.encode(transitions, forKey: .transitions) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent([AutomationNode].self, forKey: .volume) ?? []
        pan = try c.decodeIfPresent([AutomationNode].self, forKey: .pan) ?? []
        lowPass = try c.decodeIfPresent([AutomationNode].self, forKey: .lowPass) ?? []
        highPass = try c.decodeIfPresent([AutomationNode].self, forKey: .highPass) ?? []
        // A gesture of a kind that no longer exists - the old bipolar
        // filter - is dropped, not allowed to fail the whole mix.
        gestures = (try c.decodeIfPresent([Droppable<AutomationGesture>].self, forKey: .gestures) ?? [])
            .compactMap(\.value)
        transitions = (try c.decodeIfPresent([Droppable<TransitionMark>].self, forKey: .transitions) ?? [])
            .compactMap(\.value)
    }
}

/// Decodes to nil instead of throwing, for list entries that may be dropped.
private nonisolated struct Droppable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A lane's mixer switches and colour. What used to be drawn on the lane is
/// on the clips now (see the top of this file); a v1 mix's lane curves are
/// not read; no migration.
nonisolated struct LaneSettings: Codable, Sendable, Equatable {
    var muted = false
    var solo = false
    /// The lane's colour as "RRGGBB", chosen by the user; nil is the lane's
    /// own colour from `defaultColors`. In the mix rather than on the Mac, so
    /// a mix looks the same wherever it is opened and a change is undoable.
    var color: String?

    /// Each lane's own colour - blue, orange, purple - which is what a mix
    /// that never chose one shows. FA9933 was 2.17:1 on the light
    /// background, too faint to read; DD7100 keeps the hue and reaches
    /// 3.26:1 there (5.11:1 on dark). All three are held to 3:1 on both in
    /// the harness.
    static let defaultColors = ["4294FA", "DD7100", "B870F5"]

    init() {}

    enum CodingKeys: String, CodingKey { case muted, solo, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        // A colour that is not one - hand-edited, or from a later format -
        // falls back to the lane's own rather than failing the whole mix.
        color = try c.decodeIfPresent(String.self, forKey: .color).flatMap(HexColor.normalized)
    }
}

// MARK: - Selection

/// Automation picked out on the timeline - one kind and one row at a time, on any
/// number of clips, keyed by clip id; nodes as stored, in clip-local beats.
/// Nodes have no identity of their own and are matched by value; two nodes
/// identical in beat and value are interchangeable anyway.
nonisolated struct AutomationSelection: Equatable, Sendable {
    var kind: AutomationKind
    /// Whose automation: the clips' own, or one stem's (an expanded lane's
    /// row). A rectangle stays in one row.
    var part: Stem? = nil
    var nodes: [UUID: [AutomationNode]] = [:]
    var gestures: [UUID: Set<UUID>] = [:]

    var isEmpty: Bool {
        nodes.values.allSatisfy(\.isEmpty) && gestures.values.allSatisfy(\.isEmpty)
    }

    func contains(_ node: AutomationNode, clip: UUID) -> Bool {
        nodes[clip]?.contains(node) ?? false
    }

    func contains(gesture id: UUID, clip: UUID) -> Bool {
        gestures[clip]?.contains(id) ?? false
    }
}

nonisolated extension ClipAutomation {
    /// What a selection rectangle over this clip encloses, with `beats` in
    /// clip-local beats: the nodes of `kind` inside both ranges (inclusive,
    /// so a node at silence can be caught at the bottom), and the gestures of
    /// `kind` whose range overlaps `beats` at all - a gesture spans the
    /// lane's whole height, so any rectangle across its beats touches it.
    /// The caller narrows `beats` to the visible clip, so a hidden node is
    /// never selected - and never deleted - by a rectangle.
    func selection(kind: AutomationKind, beats: ClosedRange<Double>,
                   values: ClosedRange<Double>) -> (nodes: [AutomationNode], gestures: Set<UUID>) {
        let picked = nodes(kind).filter { beats.contains($0.beat) && values.contains($0.value) }
        let touched = gestures.filter { $0.kind == kind && $0.start <= beats.upperBound && $0.end >= beats.lowerBound }
        return (picked, Set(touched.map(\.id)))
    }
}

// MARK: - Evaluation

/// A clip's curve for one parameter, in clip-local beats: nodes with the
/// gestures folded in, as a sorted breakpoint list. The lane's curve is
/// pieced together from these (see LaneCurve).
///
/// Built off the audio thread, once per edit. Reading it is a binary search
/// plus one interpolation, which the renderer does once per control point,
/// not per sample.
nonisolated struct AutomationCurve: Sendable {
    let kind: AutomationKind
    let points: [AutomationNode]

    /// Gesture expansion resolution. A 32nd of a beat keeps a step's edge
    /// within a few milliseconds at any mixing tempo, which is below what a
    /// gate can be heard to be late by.
    static let gestureResolution = 1.0 / 32

    init(kind: AutomationKind, automation: ClipAutomation) {
        self.kind = kind
        let gestures = automation.gestures.filter { $0.kind == kind && $0.end > $0.start }
        var result = automation.nodes(kind).filter { node in
            !gestures.contains { node.beat >= $0.start && node.beat <= $0.end }
        }
        for gesture in gestures {
            // The edges hold the value the curve had just outside, so a
            // gesture drawn over an existing fade drops in and out of it
            // instead of ramping from wherever the next node happens to be.
            let outside = Self.evaluate(kind: kind, points: result.sorted { $0.beat < $1.beat })
            result.append(AutomationNode(beat: gesture.start - 1e-4, value: outside(gesture.start)))
            var beat = gesture.start
            while beat < gesture.end {
                result.append(AutomationNode(beat: beat, value: gesture.value(at: beat)))
                beat += Self.gestureResolution
            }
            result.append(AutomationNode(beat: gesture.end, value: outside(gesture.end)))
        }
        points = result.sorted { $0.beat < $1.beat }
    }

    func value(at beat: Double) -> Double {
        Self.evaluate(kind: kind, points: points)(beat)
    }

    private static func evaluate(kind: AutomationKind, points: [AutomationNode]) -> (Double) -> Double {
        { beat in
            guard let first = points.first, let last = points.last else { return kind.restValue }
            // A filter is out of the circuit before its first node: drawing
            // a sweep late in the mix must not filter everything before it.
            // Volume and pan hold their first value, which is what "the fader
            // is here" means.
            if beat <= first.beat { return kind.isFilter && beat < first.beat ? kind.restValue : first.value }
            if beat >= last.beat { return last.value }
            var low = 0
            var high = points.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if points[mid].beat <= beat { low = mid } else { high = mid }
            }
            let a = points[low]
            let b = points[high]
            let span = b.beat - a.beat
            guard span > 1e-12 else { return b.value }
            var t = (beat - a.beat) / span
            if a.tension != 0 {
                t = pow(t, pow(2, min(max(a.tension * 2, -2), 2)))
            }
            return a.value + (b.value - a.value) * t
        }
    }
}
