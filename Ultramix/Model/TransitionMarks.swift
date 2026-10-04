//
//  TransitionMarks.swift
//  Ultramix
//
//  The bars in the strip under the ruler: where a transition was written, as
//  one thing to grab. A beatmix and ⇧⌘X leave one over the overlap they wrote;
//  a drag in empty strip draws one and writes the current style there.
//
//  A mark owns its range the way a style does (Crossfade.swift). Moving it or
//  dragging an edge takes the points out of the old range and writes the
//  style again over the new one; choosing another style rewrites it in place;
//  deleting it takes every point and movement inside it off every clip it
//  lies over, and leaves the curves on either side as they were.
//
//  A mark is stored on a clip - the incoming one, or the outgoing one when
//  that is locked - in the clip's own beats, inside its automation. So it
//  moves, copies and goes with the clip exactly as the points it stands for
//  do, ⌥⌫ takes it with them, and a lock protects it like the rest.
//

import Foundation

nonisolated struct TransitionMark: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    /// Clip-local beats of the clip holding the mark.
    var start: Double
    var end: Double
    /// The style written there. Nil for a beatmix's handover, which is no
    /// style; moving one writes the current style.
    var style: TransitionStyle?

    init(id: UUID = UUID(), start: Double, end: Double, style: TransitionStyle?) {
        self.id = id
        self.start = start
        self.end = end
        self.style = style
    }

    enum CodingKeys: String, CodingKey { case id, start, end, style }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(style?.rawValue, forKey: .style)
    }

    /// A style this build does not know reads as none rather than failing
    /// the mix.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        style = (try? c.decodeIfPresent(String.self, forKey: .style)).flatMap { $0 }.flatMap(TransitionStyle.init)
    }
}

/// Which mark: the clip holding it and its id.
nonisolated struct MarkRef: Hashable, Sendable {
    var clip: UUID
    var id: UUID
}

/// A mark where the timeline draws it, in timeline beats.
nonisolated struct PlacedMark: Equatable, Sendable {
    let ref: MarkRef
    let start: Double
    let end: Double
    let style: TransitionStyle?
    let locked: Bool

    var title: String { style?.title ?? "Beatmix" }
}

nonisolated extension MixDocument {
    /// Shortest a mark may be drawn or dragged.
    static let minimumMarkBeats = 1.0

    /// Every mark on a clip it still lies over, left to right. One a trim
    /// moved the clip away from is hidden with the points it stands for.
    func placedMarks(_ grids: GridLookup) -> [PlacedMark] {
        var result: [PlacedMark] = []
        for clip in clips {
            guard let shape = geometry(clip, grids) else { continue }
            let anchor = Double(clip.anchorBeat)
            for mark in clip.automation.transitions {
                let (start, end) = (anchor + mark.start, anchor + mark.end)
                guard end > shape.start + 1e-6, start < shape.end - 1e-6 else { continue }
                result.append(PlacedMark(ref: MarkRef(clip: clip.id, id: mark.id), start: start, end: end,
                                         style: mark.style, locked: clip.locked))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    func hasMark(_ ref: MarkRef) -> Bool {
        clips.contains { $0.id == ref.clip && $0.automation.transitions.contains { $0.id == ref.id } }
    }

    /// The transition a range belongs to: of those it overlaps, the one it
    /// overlaps most.
    func transition(over start: Double, _ end: Double, grids: GridLookup) -> Transition? {
        func shared(_ t: Transition) -> Double { min(end, t.end) - max(start, t.start) }
        return transitions(grids).filter { shared($0) > 1e-6 }.max { shared($0) < shared($1) }
    }

    /// Draws a mark over `start…end` (timeline beats, either order) and
    /// writes `style` there.
    @discardableResult
    mutating func addMark(from a: Double, to b: Double, style: TransitionStyle, grids: GridLookup) throws -> MarkRef {
        let (start, end) = (min(a, b), max(a, b))
        guard end - start >= Self.minimumMarkBeats - 1e-9 else {
            throw EditError("A transition is at least a beat long.")
        }
        guard let transition = transition(over: start, end, grids: grids) else {
            throw EditError("Draw the transition over two clips that overlap on different lanes.")
        }
        guard let owner = editable(transition.incoming) ?? editable(transition.outgoing) else {
            throw EditError("Both clips of the transition are locked.")
        }
        write(style, transition, from: start, to: end)
        let anchor = Double(clips[owner].anchorBeat)
        let mark = TransitionMark(start: start - anchor, end: end - anchor, style: style)
        clips[owner].automation.transitions.append(mark)
        return MarkRef(clip: clips[owner].id, id: mark.id)
    }

    /// Moves a mark to `start…end`: the points of its old range go, its
    /// style - the current one, for a beatmix's - is written over the new.
    /// Returns where the mark is now, which is another clip when the new
    /// range belongs to another transition.
    @discardableResult
    mutating func moveMark(_ ref: MarkRef, from a: Double, to b: Double, currentStyle: TransitionStyle,
                           grids: GridLookup) throws -> MarkRef {
        let (start, end) = (min(a, b), max(a, b))
        guard let (i, k) = locate(ref) else { throw EditError("That transition is gone.") }
        guard !clips[i].locked else { throw EditError("The clip is locked.") }
        guard end - start >= Self.minimumMarkBeats - 1e-9 else {
            throw EditError("A transition is at least a beat long.")
        }
        guard let transition = transition(over: start, end, grids: grids) else {
            throw EditError("A transition has to lie over two clips that overlap on different lanes.")
        }
        let mark = clips[i].automation.transitions[k]
        let anchor = Double(clips[i].anchorBeat)
        let (oldStart, oldEnd) = (anchor + mark.start, anchor + mark.end)
        if let old = self.transition(over: oldStart, oldEnd, grids: grids) {
            for id in [old.outgoing, old.incoming] { clearAutomation(clip: id, from: oldStart, to: oldEnd) }
        }
        let style = mark.style ?? currentStyle
        write(style, transition, from: start, to: end)

        clips[i].automation.transitions.remove(at: k)
        guard let owner = editable(transition.incoming) ?? editable(transition.outgoing) else {
            throw EditError("Both clips of the transition are locked.")
        }
        let ownerAnchor = Double(clips[owner].anchorBeat)
        clips[owner].automation.transitions.append(
            TransitionMark(id: mark.id, start: start - ownerAnchor, end: end - ownerAnchor, style: style))
        return MarkRef(clip: clips[owner].id, id: mark.id)
    }

    /// Writes another style over a mark's range, in place of what was there.
    mutating func applyStyle(_ style: TransitionStyle, toMark ref: MarkRef, grids: GridLookup) throws {
        guard let (i, k) = locate(ref) else { throw EditError("That transition is gone.") }
        let anchor = Double(clips[i].anchorBeat)
        let mark = clips[i].automation.transitions[k]
        clips[i].automation.transitions[k].style = style
        try moveMark(ref, from: anchor + mark.start, to: anchor + mark.end, currentStyle: style, grids: grids)
    }

    /// Deletes a mark, and with it every point and movement inside its
    /// range on every clip it lies over - all four kinds, on every lane.
    /// The curves either side stay as they were. Locked clips keep theirs.
    mutating func removeMark(_ ref: MarkRef, grids: GridLookup) throws {
        guard let (i, k) = locate(ref) else { throw EditError("That transition is gone.") }
        guard !clips[i].locked else { throw EditError("The clip is locked.") }
        let anchor = Double(clips[i].anchorBeat)
        let mark = clips[i].automation.transitions.remove(at: k)
        let (start, end) = (anchor + mark.start, anchor + mark.end)
        for clip in clips {
            guard let shape = geometry(clip, grids), shape.end > start, shape.start < end else { continue }
            clearAutomation(clip: clip.id, from: start, to: end)
        }
    }

    /// The mark over a transition just written by ⇧⌘X: marks of those two
    /// clips that overlap it give way to it.
    mutating func setMark(over transition: Transition, style: TransitionStyle?) {
        for id in [transition.outgoing, transition.incoming] {
            guard let i = editable(id) else { continue }
            let anchor = Double(clips[i].anchorBeat)
            clips[i].automation.transitions.removeAll {
                anchor + $0.end > transition.start + 1e-6 && anchor + $0.start < transition.end - 1e-6
            }
        }
        guard let owner = editable(transition.incoming) ?? editable(transition.outgoing) else { return }
        let anchor = Double(clips[owner].anchorBeat)
        clips[owner].automation.transitions.append(
            TransitionMark(start: transition.start - anchor, end: transition.end - anchor, style: style))
    }

    // MARK: - Helpers

    private func locate(_ ref: MarkRef) -> (Int, Int)? {
        guard let i = index(of: ref.clip),
              let k = clips[i].automation.transitions.firstIndex(where: { $0.id == ref.id }) else { return nil }
        return (i, k)
    }

    /// Both sides of a transition, written over `start…end`.
    private mutating func write(_ style: TransitionStyle, _ transition: Transition, from start: Double, to end: Double) {
        apply(style, clip: transition.outgoing, from: start, to: end, incoming: false)
        apply(style, clip: transition.incoming, from: start, to: end, incoming: true)
    }

    /// Takes every point inside `start…end` (timeline beats) off a clip,
    /// with the guard points a style left just outside, and cuts its
    /// movements there. What remains of a movement after the range keeps its
    /// rhythm: it starts on its next whole cycle. A locked clip is left alone.
    mutating func clearAutomation(clip id: UUID, from start: Double, to end: Double) {
        guard let i = editable(id) else { return }
        let anchor = Double(clips[i].anchorBeat)
        let margin = Self.crossfadeGuard + 1e-9
        let (low, high) = (start - anchor - margin, end - anchor + margin)
        for kind in AutomationKind.allCases {
            let kept = clips[i].automation.nodes(kind).filter { $0.beat < low || $0.beat > high }
            clips[i].automation.setNodes(kind, kept)
        }
        var gestures: [AutomationGesture] = []
        for gesture in clips[i].automation.gestures {
            guard gesture.end > low, gesture.start < high else {
                gestures.append(gesture)
                continue
            }
            if gesture.start < low {
                var before = gesture
                before.end = low
                if before.end - before.start >= 0.25 { gestures.append(before) }
            }
            if gesture.end > high {
                let period = max(gesture.period, 1e-6)
                let cycles = ((high - gesture.start) / period).rounded(.up)
                let after = AutomationGesture(kind: gesture.kind, start: gesture.start + cycles * period,
                                              end: gesture.end, shape: gesture.shape, period: gesture.period,
                                              low: gesture.low, high: gesture.high)
                if after.end - after.start >= 0.25 { gestures.append(after) }
            }
        }
        clips[i].automation.gestures = gestures
    }
}
