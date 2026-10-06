//
//  EditOps.swift
//  Ultramix
//
//  Every edit a clip can undergo, as a mutation of the document that either
//  succeeds whole or throws and leaves the document untouched.
//
//  The rules live here, not in the views: the harness can reach them here, and
//  the same edit arrives from a drag, a menu item and a key, which a rule
//  living in one of those places eventually disagrees with.
//
//  Snapping: a clip's anchor snaps to a bar line, since the anchor is what
//  keeps clips phase-aligned; trim and loop handles to a quarter beat (on the
//  beat is too coarse to take out a pickup, finer is noise); a split to the
//  nearest whole beat, so no clip is left 4.0173 beats long, which no
//  bar-snapped anchor can sit end to end with.
//

import Foundation

/// How the model reaches the library without depending on it: a track id in,
/// the track's grid out. Nil while the track has no tempo yet.
typealias GridLookup = (UUID) -> SourceGrid?

nonisolated struct EditError: Error, Equatable, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated enum ClipEdge: Sendable { case start, end }

// `nonisolated` on the extension as well as on the type: with MainActor as
// the default isolation, an extension's members are MainActor-isolated
// unless it says otherwise, and the render-plan builder calls them from a
// background task.
nonisolated extension MixDocument {

    /// How far a newly added clip reaches back over the end of the mix. Eight
    /// bars is a transition's worth: long enough to mix, short enough that
    /// neither track has to be trimmed straight away.
    static let defaultOverlapBeats = 32.0

    // MARK: - Queries

    func index(of id: UUID) -> Int? {
        clips.firstIndex { $0.id == id }
    }

    func geometry(_ clip: Clip, _ grids: GridLookup) -> ClipGeometry? {
        grids(clip.trackID).map { ClipGeometry(clip: clip, grid: $0) }
    }

    /// Whether `clip` could stand where it is: inside the mix, long enough,
    /// and not overlapping another clip on its lane.
    func fits(_ clip: Clip, _ grids: GridLookup) -> Bool {
        guard (0..<Clip.laneCount).contains(clip.lane),
              let shape = geometry(clip, grids),
              shape.start >= -1e-9,
              shape.bodyLength >= Clip.minimumBeats - 1e-9 else { return false }
        return !clips.contains { other in
            other.id != clip.id && other.lane == clip.lane
                && (geometry(other, grids).map { shape.overlaps($0) } ?? false)
        }
    }

    // MARK: - Snapping

    static func quarterBeat(_ beat: Double) -> Double {
        (beat * 4).rounded() / 4
    }

    /// The lowest anchor on a multiple of `step` beats - a bar line unless
    /// asked otherwise - that keeps the clip's left edge at or after beat 0.
    static func minimumAnchor(_ clip: Clip, _ grid: SourceGrid, step: Int = Clip.beatsPerBar) -> Int {
        let lead = clip.looping ? clip.loopLead : 0
        let lowest = grid.preRollBeats - clip.trimStart + lead
        return Int(((lowest - 1e-9) / Double(step)).rounded(.up)) * step
    }

    /// What lands on the bar line when a clip is placed or dragged.
    ///
    /// For a record that is its bar one, and this is 0. A loop cut out of
    /// the middle of a record (LoopRegion.swift) has its bar one somewhere
    /// outside the piece being looped, often several beats before it: what
    /// a listener hears land on the bar is the loop's first sample, so that
    /// is what snaps, and the anchor keeps its distance from it. Without
    /// this, one drag of a loop would put its start half a bar off the grid
    /// it was cut on.
    static func snapLead(_ clip: Clip, _ grid: SourceGrid) -> Int {
        guard clip.looping, clip.trimStart > grid.preRollBeats + 1e-9 else { return 0 }
        return Int((clip.trimStart - grid.preRollBeats).rounded())
    }

    static func snappedAnchor(_ anchor: Double, _ clip: Clip, _ grid: SourceGrid,
                              step: Int = Clip.beatsPerBar) -> Int {
        let lead = snapLead(clip, grid)
        let snapped = Int(((anchor + Double(lead)) / Double(step)).rounded()) * step - lead
        return max(snapped, minimumAnchor(clip, grid, step: step))
    }

    /// Refuses a move that would take a locked clip with it.
    private func checkUnlocked(_ moving: [Clip]) throws {
        if moving.contains(where: \.locked) {
            throw EditError(moving.count == 1 ? "The clip is locked." : "A locked clip is part of the selection.")
        }
    }

    // MARK: - Add and remove

    /// Places a track on the timeline and returns the new clip's id.
    ///
    /// With no position given, the clip goes on the lane after the one used
    /// last, overlapping the end of the mix by `defaultOverlapBeats`, so
    /// three tracks added in a row already form a chain.
    ///
    /// - Parameters:
    ///   - startBeat: where the clip's left edge should go, before snapping.
    ///   - lane: the lane to use; nil lets the rule above choose.
    ///   - draft: what to place - the whole record, or a loop cut out of it
    ///     (see LoopRegion.swift). A record is placed by its bar one, which
    ///     lands on a bar line with the intro hanging to the left; a loop by
    ///     its first sample, which lands on the bar line instead, because a
    ///     loop's own bar one is somewhere outside the piece being looped.
    @discardableResult
    mutating func addClip(trackID: UUID, grid: SourceGrid, lane: Int? = nil,
                          startBeat: Double? = nil, grids: GridLookup,
                          draft: ClipDraft = .record) throws -> UUID {
        // The new clip's track may not be in `grids` yet - it is being added.
        func lookup(_ id: UUID) -> SourceGrid? { id == trackID ? grid : grids(id) }
        if clips.isEmpty { projectBPM = min(max(grid.bpm, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound) }

        let lanes: [Int]
        if let lane {
            lanes = [lane]
        } else {
            let last = clips.last?.lane ?? -1
            lanes = (1...Clip.laneCount).map { (last + $0) % Clip.laneCount }
        }
        let start = startBeat ?? max(0, endBeat(lookup) - Self.defaultOverlapBeats)

        var clip = draft.applied(to: Clip(trackID: trackID, lane: 0, anchorBeat: 0))
        for candidate in lanes {
            clip.lane = candidate
            clip.anchorBeat = Self.snappedAnchor(start - draft.startOffset(grid), clip, grid)
            // Where the clip begins to sound, which for a record is its bar
            // one and for a loop is the bar line its first sample landed on.
            // A tempo point behind the start of the mix is no point at all.
            clip.tempoAnchorBeat = clip.anchorBeat + draft.leadBeats
            if fits(clip, lookup) {
                clips.append(clip)
                return clip.id
            }
        }
        // Nowhere near the end has room: after everything, on the first
        // candidate lane, always fits.
        if startBeat == nil {
            clip.lane = lanes[0]
            let bar = Double(Clip.beatsPerBar)
            let after = Int(((endBeat(lookup) - draft.startOffset(grid)) / bar).rounded(.up)) * Clip.beatsPerBar
            clip.anchorBeat = max(after - draft.leadBeats, Self.minimumAnchor(clip, grid))
            clip.tempoAnchorBeat = clip.anchorBeat + draft.leadBeats
            if fits(clip, lookup) {
                clips.append(clip)
                return clip.id
            }
        }
        throw EditError("There is no room for the track there.")
    }

    /// Removes clips, and with each the automation drawn on it - which is
    /// part of the clip, the part a trim hid included.
    mutating func removeClips(_ ids: Set<UUID>, grids: GridLookup) {
        clips.removeAll { ids.contains($0.id) }
    }

    /// Removes the automation drawn on clips and leaves the clips: what ⌥⌫
    /// does. Exactly what `removeClips` takes with them - everything the
    /// clip holds, including what lies over its trimmed-away part, so
    /// nothing is left behind unseen.
    /// Locked clips keep theirs; if every one of them is locked, that is
    /// said rather than passed over in silence.
    mutating func removeAutomation(onClips ids: Set<UUID>) throws {
        let targets = clips.indices.filter { ids.contains(clips[$0].id) }
        if !targets.isEmpty, targets.allSatisfy({ clips[$0].locked }) {
            throw EditError(targets.count == 1 ? "The clip is locked." : "The selected clips are locked.")
        }
        for i in targets where !clips[i].locked {
            clips[i].automation = ClipAutomation()
        }
    }

    // MARK: - Move

    /// Moves a clip to a new anchor and lane. The automation drawn on it goes
    /// with it, being stored on it.
    mutating func moveClip(_ id: UUID, anchorBeat: Double, lane: Int, grids: GridLookup) throws {
        guard let i = index(of: id), let grid = grids(clips[i].trackID) else { return }
        try checkUnlocked([clips[i]])
        var target = clips[i]
        target.lane = min(max(lane, 0), Clip.laneCount - 1)
        try place(id, anchor: Self.snappedAnchor(anchorBeat, target, grid), lane: target.lane, grids: grids)
    }

    /// Moves a whole selection at once: `id` is the clip under the pointer,
    /// which lands on the multiple of `step` beats nearest `anchorBeat` on
    /// `lane` (a bar line unless asked otherwise), and every
    /// other clip in `ids` keeps its distance from it - in beats and in
    /// lanes. Dragging one clip of a selection therefore moves the shape of
    /// the selection, not just the clip that was grabbed.
    ///
    /// All or nothing, like `nudgeClips`: if one of them cannot go where the
    /// move would put it, none of them moves and the drag simply stops
    /// there. The move across lanes is clamped to what the selection allows,
    /// rather than refused: a selection that already touches the bottom lane
    /// keeps following the pointer sideways instead of freezing. A locked
    /// clip in the selection stops the whole move.
    mutating func moveClips(_ ids: Set<UUID>, dragging id: UUID, anchorBeat: Double,
                            lane: Int, step: Int = Clip.beatsPerBar, grids: GridLookup) throws {
        guard let i = index(of: id), let grid = grids(clips[i].trackID) else { return }
        let dragged = clips[i]
        let moving = clips.filter { ids.contains($0.id) || $0.id == id }
        try checkUnlocked(moving)
        let beats = Self.snappedAnchor(anchorBeat, dragged, grid, step: step) - dragged.anchorBeat
        let lowest = moving.map(\.lane).min() ?? dragged.lane
        let highest = moving.map(\.lane).max() ?? dragged.lane
        let wanted = min(max(lane, 0), Clip.laneCount - 1) - dragged.lane
        let lanes = min(max(wanted, -lowest), Clip.laneCount - 1 - highest)
        guard beats != 0 || lanes != 0 else { return }

        // In the direction of travel, so that selected clips standing end to
        // end - or on neighbouring lanes - do not block each other.
        let order = moving.sorted { a, b in
            if lanes != 0 && a.lane != b.lane { return lanes > 0 ? a.lane > b.lane : a.lane < b.lane }
            return beats >= 0 ? a.anchorBeat > b.anchorBeat : a.anchorBeat < b.anchorBeat
        }
        var result = self
        for clip in order {
            guard let grid = grids(clip.trackID) else { continue }
            let anchor = clip.anchorBeat + beats
            guard anchor >= Self.minimumAnchor(clip, grid, step: step) else {
                throw EditError("The clip is already at the start of the mix.")
            }
            try result.place(clip.id, anchor: anchor, lane: clip.lane + lanes, grids: grids)
        }
        self = result
    }

    /// Moves clips by whole beats, off the bar grid - the arrow keys' fine
    /// adjustment, where dragging snaps to bars.
    ///
    /// All or nothing: if any of the clips cannot move (the start of the
    /// mix, a neighbour on its lane), none of them does. Clips are moved in
    /// the direction of travel's order - the rightmost first when moving
    /// right - so selected clips standing end to end do not block each other.
    /// A locked clip among them stops the nudge.
    mutating func nudgeClips(_ ids: Set<UUID>, byBeats beats: Int, grids: GridLookup) throws {
        guard beats != 0 else { return }
        let moving = clips.filter { ids.contains($0.id) }
            .sorted { beats > 0 ? $0.anchorBeat > $1.anchorBeat : $0.anchorBeat < $1.anchorBeat }
        guard !moving.isEmpty else { return }
        try checkUnlocked(moving)
        var result = self
        for clip in moving {
            guard let grid = grids(clip.trackID) else { continue }
            let anchor = clip.anchorBeat + beats
            guard anchor >= Self.minimumAnchor(clip, grid) else {
                throw EditError("The clip is already at the start of the mix.")
            }
            try result.place(clip.id, anchor: anchor, lane: clip.lane, grids: grids)
        }
        self = result
    }

    /// Puts a clip at `anchor` on `lane`, exactly - no snapping - with its
    /// tempo point. Its automation is in clip-local beats and needs nothing.
    private mutating func place(_ id: UUID, anchor: Int, lane: Int, grids: GridLookup) throws {
        guard let i = index(of: id) else { return }
        let old = clips[i]
        var clip = old
        clip.lane = lane
        clip.anchorBeat = anchor
        let delta = anchor - old.anchorBeat
        if delta == 0 && lane == old.lane { return }
        guard fits(clip, grids) else {
            throw EditError("Lane \(["A", "B", "C"][lane]) is taken at that position.")
        }
        clip.tempoAnchorBeat += delta
        clip.rampStartBeat = clip.rampStartBeat.map { $0 + delta }
        clips[i] = clip
    }

    // MARK: - Trim and loop

    /// Trims a clip's edge to `beat`. The anchor does not move - bar one
    /// stays on its bar line however much of the head is cut away.
    mutating func trimClip(_ id: UUID, edge: ClipEdge, to beat: Double, grids: GridLookup) throws {
        guard let i = index(of: id), let grid = grids(clips[i].trackID) else { return }
        var clip = clips[i]
        if clip.looping {
            return try setLoopExtent(id, edge: edge, to: beat, grids: grids)
        }
        let shape = ClipGeometry(clip: clip, grid: grid)
        let target = Self.quarterBeat(beat)
        switch edge {
        case .start:
            let longest = grid.lengthBeats - clip.trimEnd - Clip.minimumBeats
            clip.trimStart = min(max(0, -shape.fileStart, target - shape.fileStart), longest)
        case .end:
            let longest = grid.lengthBeats - clip.trimStart - Clip.minimumBeats
            clip.trimEnd = min(max(0, shape.fileStart + grid.lengthBeats - target), longest)
        }
        guard fits(clip, grids) else { throw EditError("The clip would overlap its neighbour.") }
        clips[i] = clip
    }

    mutating func setLooping(_ id: UUID, _ looping: Bool) {
        guard let i = index(of: id) else { return }
        clips[i].looping = looping
        if !looping {
            // A length nobody can see any more would be a hidden memory that
            // resurfaces the next time looping is switched on.
            clips[i].loopLead = 0
            clips[i].loopTail = 0
        }
    }

    /// Drags a looping clip's edge: the body repeats out to `beat`.
    mutating func setLoopExtent(_ id: UUID, edge: ClipEdge, to beat: Double, grids: GridLookup) throws {
        guard let i = index(of: id), let grid = grids(clips[i].trackID), clips[i].looping else { return }
        var clip = clips[i]
        let shape = ClipGeometry(clip: clip, grid: grid)
        let target = Self.quarterBeat(beat)
        switch edge {
        case .start: clip.loopLead = max(0, shape.bodyStart - max(target, 0))
        case .end: clip.loopTail = max(0, target - shape.bodyEnd)
        }
        guard fits(clip, grids) else { throw EditError("The loop would overlap its neighbour.") }
        clips[i] = clip
    }

    // MARK: - Split and duplicate

    /// Splits a clip at the whole beat nearest `beat` and returns the id of
    /// the right half, which is inserted directly after the left.
    ///
    /// Both halves keep the anchor, so both stay on the same bar lines. The
    /// half that does not inherit the tempo target gets one of its own, at
    /// the split and at the tempo the map already plays there, so a split
    /// never alters what the mix sounds like.
    ///
    /// Both halves get the clip's whole automation. Sharing the anchor means
    /// its clip-local beats mean the same on either, so each half is a
    /// trimmed copy and extending one brings its hidden part back as any
    /// trim does. Cutting the curve at the split would lose the shape past
    /// it for good.
    @discardableResult
    mutating func splitClip(_ id: UUID, at beat: Double, grids: GridLookup) throws -> UUID {
        guard let i = index(of: id), let grid = grids(clips[i].trackID) else {
            throw EditError("That clip cannot be split.")
        }
        let clip = clips[i]
        guard !clip.looping else { throw EditError("Turn looping off before splitting the clip.") }
        let shape = ClipGeometry(clip: clip, grid: grid)
        let split = beat.rounded()
        guard split - shape.bodyStart >= Clip.minimumBeats, shape.bodyEnd - split >= Clip.minimumBeats else {
            throw EditError("Split inside the clip, away from its edges.")
        }
        let onLine = tempoMap(grids).bpm(atBeat: split)
        var left = clip
        var right = Clip(trackID: clip.trackID, lane: clip.lane, anchorBeat: clip.anchorBeat,
                         tempoAnchorBeat: clip.tempoAnchorBeat, targetBPM: clip.targetBPM,
                         rampStartBeat: clip.rampStartBeat,
                         trimStart: clip.trimStart + (split - shape.bodyStart), trimEnd: clip.trimEnd,
                         muted: clip.muted, locked: clip.locked, gainDB: clip.gainDB, keyShift: clip.keyShift,
                         automation: clip.automation)
        left.trimEnd += shape.bodyEnd - split
        // Both halves keep every point, but a transition's bar goes to the
        // half it begins on - on both it would be drawn twice.
        let splitLocal = split - Double(clip.anchorBeat)
        left.automation.transitions.removeAll { $0.start >= splitLocal }
        right.automation.transitions.removeAll { $0.start < splitLocal }
        // The ramp start goes with whichever point now comes first after it.
        // A split after the original point puts the new point behind it, on
        // flat line: no ramp start needed there. A split before the point
        // puts the new point on the left half; if that lands past the ramp
        // start, the hold now ends at the new point's ramp, and the line
        // from there to the original point is straight - measured, when the
        // ramp start stayed on the right half, the new point cut the hold
        // short and the mix drifted by a quarter of a second.
        if Double(clip.tempoAnchorBeat) < split {
            right.tempoAnchorBeat = Int(split)
            right.targetBPM = onLine
            right.rampStartBeat = nil
        } else {
            left.tempoAnchorBeat = Int(split)
            left.targetBPM = onLine
            if let start = clip.rampStartBeat, Double(start) < split {
                left.rampStartBeat = start
                right.rampStartBeat = nil
            } else {
                left.rampStartBeat = nil
            }
        }
        clips[i] = left
        clips.insert(right, at: i + 1)
        return right.id
    }

    /// Copies a clip, exactly as trimmed, to the first free place of four:
    /// the lane below at the same beats, the lane above, then immediately
    /// after it on its own lane, then immediately before. Neighbouring lanes
    /// come first because a copy there costs no time on the timeline;
    /// nothing is ever moved out of the way. The automation is copied with
    /// the clip: it is part of it, and a copy should sound like the original.
    @discardableResult
    mutating func duplicateClip(_ id: UUID, grids: GridLookup) throws -> UUID {
        guard let i = index(of: id), let grid = grids(clips[i].trackID) else {
            throw EditError("That clip cannot be duplicated.")
        }
        let clip = clips[i]
        let length = ClipGeometry(clip: clip, grid: grid).length
        let bar = Double(Clip.beatsPerBar)
        let step = max(Clip.beatsPerBar, Int((length / bar - 1e-9).rounded(.up)) * Clip.beatsPerBar)
        let places = [(clip.lane + 1, 0), (clip.lane - 1, 0), (clip.lane, step), (clip.lane, -step)]
        for (lane, shift) in places where (0..<Clip.laneCount).contains(lane) {
            var copy = Clip(trackID: clip.trackID, lane: lane, anchorBeat: clip.anchorBeat + shift,
                            tempoAnchorBeat: clip.tempoAnchorBeat + shift, targetBPM: clip.targetBPM,
                            rampStartBeat: clip.rampStartBeat.map { $0 + shift },
                            trimStart: clip.trimStart, trimEnd: clip.trimEnd, looping: clip.looping,
                            loopLead: clip.loopLead, loopTail: clip.loopTail, muted: clip.muted,
                            locked: clip.locked, gainDB: clip.gainDB, keyShift: clip.keyShift,
                            automation: clip.automation)
            copy.lane = lane
            if fits(copy, grids) {
                clips.append(copy)
                return copy.id
            }
        }
        throw EditError("No room for a copy: the lanes beside it and the bars next to it are taken.")
    }

    // MARK: - Tempo

    /// Sets the tempo the mix reaches at this clip's tempo point. Nil returns
    /// to the track's own tempo.
    mutating func setTargetBPM(_ id: UUID, _ bpm: Double?) {
        guard let i = index(of: id) else { return }
        clips[i].targetBPM = bpm.map { min(max($0, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound) }
    }

    /// Moves a clip's tempo point to the bar nearest `beat`, kept inside the
    /// clip. A tempo point outside its clip would be a ramp nobody can find.
    mutating func moveTempoAnchor(_ id: UUID, to beat: Double, grids: GridLookup) {
        guard let i = index(of: id), let grid = grids(clips[i].trackID) else { return }
        let shape = ClipGeometry(clip: clips[i], grid: grid)
        let bar = Double(Clip.beatsPerBar)
        var snapped = (beat / bar).rounded() * bar
        snapped = min(max(snapped, shape.start.rounded(.up)), shape.end.rounded(.down))
        clips[i].tempoAnchorBeat = Int(snapped)
        // A point dragged back over its ramp start would have the ramp begin
        // after it ends. The ramp start goes rather than being pushed along:
        // where it stood was a choice about the old point, not the new one.
        if let start = clips[i].rampStartBeat, start >= clips[i].tempoAnchorBeat {
            clips[i].rampStartBeat = nil
        }
    }

    /// Sets where the ramp into this clip's tempo point begins: the bar
    /// nearest `beat`, and never later than a beat before the point. Until
    /// there the mix holds the tempo it had, then ramps to the target.
    mutating func setRampStart(_ id: UUID, to beat: Double) {
        guard let i = index(of: id) else { return }
        let latest = clips[i].tempoAnchorBeat - 1
        guard latest >= 0 else {
            clips[i].rampStartBeat = nil
            return
        }
        let bar = Double(Clip.beatsPerBar)
        let snapped = Int((beat / bar).rounded()) * Clip.beatsPerBar
        clips[i].rampStartBeat = min(max(snapped, 0), latest)
    }

    /// The ramp into this clip's tempo point runs from the previous point
    /// again.
    mutating func removeRampStart(_ id: UUID) {
        guard let i = index(of: id) else { return }
        clips[i].rampStartBeat = nil
    }

    // MARK: - Automation

    //
    // Automation exists only inside clips. Every edit below takes timeline
    // beats, as the pointer gives them, and stores clip-local ones; a beat is
    // held to the clip's visible span, so a point dragged past the edge stops
    // on it rather than disappearing into the hidden part. These used to be
    // written inline in the timeline view; here the harness can check the
    // clamps.

    /// The clip on `lane` whose visible span holds `beat`.
    func clip(atBeat beat: Double, lane: Int, grids: GridLookup) -> Clip? {
        clips.last { clip in
            clip.lane == lane && (geometry(clip, grids).map { beat >= $0.start && beat <= $0.end } ?? false)
        }
    }

    /// Where the timeline's `beat` falls in a track's own file, in seconds -
    /// for the beatgrid editor's jump to the playhead. Nil when no clip of
    /// that track sounds there: the song is not playing at the playhead, and
    /// there is no spot to jump to.
    ///
    /// A looping clip is asked which copy of its body the beat falls in, so
    /// the answer is a spot in the song and not in the loop's third round.
    func sourceSeconds(ofTrack trackID: UUID, atBeat beat: Double, grids: GridLookup) -> Double? {
        guard let grid = grids(trackID) else { return nil }
        for clip in clips where clip.trackID == trackID {
            guard let shape = geometry(clip, grids), beat >= shape.start, beat <= shape.end else { continue }
            let fileStart = shape.segments().last { beat >= $0.start && beat <= $0.end }?.fileStart ?? shape.fileStart
            return max(0, min((beat - fileStart) * 60 / max(grid.bpm, 1), grid.durationSeconds))
        }
        return nil
    }

    /// The clip's visible span in its own beats, and its index.
    private func localSpan(_ id: UUID, _ grids: GridLookup) -> (index: Int, span: ClosedRange<Double>)? {
        guard let i = index(of: id), let shape = geometry(clips[i], grids) else { return nil }
        let anchor = Double(clips[i].anchorBeat)
        return (i, (shape.start - anchor)...(shape.end - anchor))
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The index of a clip whose automation may be changed: nil for a
    /// clip that is gone or locked. Every automation edit goes through it.
    func editable(_ id: UUID) -> Int? {
        index(of: id).flatMap { clips[$0].locked ? nil : $0 }
    }

    /// Places a node on a clip, at timeline `beat`. Returns the node as
    /// stored, or nil when there is no such clip or it is locked.
    @discardableResult
    mutating func addAutomationNode(clip id: UUID, kind: AutomationKind, beat: Double, value: Double,
                                    tension: Double = 0, grids: GridLookup) -> AutomationNode? {
        guard editable(id) != nil, let (i, span) = localSpan(id, grids) else { return nil }
        let node = AutomationNode(beat: Self.clamp(beat - Double(clips[i].anchorBeat), span),
                                  value: Self.clamp(value, kind.range), tension: tension)
        clips[i].automation.setNodes(kind, clips[i].automation.nodes(kind) + [node])
        return node
    }

    /// Moves a stored node to timeline `beat` and `value`, keeping its bend.
    /// Returns the node as now stored, so a drag can find it again on its
    /// next step; a node that is gone (an undo mid-drag) is placed anew.
    @discardableResult
    mutating func moveAutomationNode(clip id: UUID, kind: AutomationKind, from node: AutomationNode,
                                     toBeat beat: Double, value: Double, grids: GridLookup) -> AutomationNode? {
        guard editable(id) != nil, let (i, span) = localSpan(id, grids) else { return nil }
        let target = AutomationNode(beat: Self.clamp(beat - Double(clips[i].anchorBeat), span),
                                    value: Self.clamp(value, kind.range), tension: node.tension)
        var nodes = clips[i].automation.nodes(kind)
        if let n = nodes.firstIndex(of: node) { nodes[n] = target } else { nodes.append(target) }
        clips[i].automation.setNodes(kind, nodes)
        return target
    }

    mutating func removeAutomationNode(clip id: UUID, kind: AutomationKind, node: AutomationNode) {
        guard let i = editable(id) else { return }
        clips[i].automation.setNodes(kind, clips[i].automation.nodes(kind).filter { $0 != node })
    }

    /// A gesture given in timeline beats, turned into the clip's own beats
    /// and cut to its visible span - what `addGesture` stores, and what the
    /// timeline draws while it is being dragged out. Nil when less than a
    /// quarter beat of it lies on the clip.
    func clippedGesture(_ gesture: AutomationGesture, clip id: UUID, grids: GridLookup) -> AutomationGesture? {
        guard let (i, span) = localSpan(id, grids) else { return nil }
        let anchor = Double(clips[i].anchorBeat)
        var local = gesture
        local.start = Self.clamp(gesture.start - anchor, span)
        local.end = Self.clamp(gesture.end - anchor, span)
        return local.end - local.start >= 0.25 ? local : nil
    }

    /// Adds a gesture drawn in timeline beats to a clip; see
    /// `clippedGesture`. Returns whether anything was added.
    @discardableResult
    mutating func addGesture(_ gesture: AutomationGesture, clip id: UUID, grids: GridLookup) -> Bool {
        guard let i = editable(id), let local = clippedGesture(gesture, clip: id, grids: grids) else { return false }
        clips[i].automation.gestures.append(local)
        return true
    }

    mutating func removeGesture(_ gestureID: UUID, clip id: UUID) {
        guard let i = editable(id) else { return }
        clips[i].automation.gestures.removeAll { $0.id == gestureID }
    }

    /// Deletes exactly the selected nodes and gestures, on every clip the
    /// selection reaches that is not locked.
    mutating func deleteAutomation(_ selection: AutomationSelection) {
        for (id, picked) in selection.nodes {
            guard let i = editable(id) else { continue }
            let kept = clips[i].automation.nodes(selection.kind).filter { !picked.contains($0) }
            clips[i].automation.setNodes(selection.kind, kept)
        }
        for (id, gestures) in selection.gestures {
            guard let i = editable(id) else { continue }
            clips[i].automation.gestures.removeAll { gestures.contains($0.id) }
        }
    }

    /// Puts one automation node back at its kind's resting value - where a
    /// lane with nothing drawn sits: −4 dB for volume, centre for pan, the
    /// filter out - keeping its position and its bend.
    mutating func resetAutomationNode(_ node: AutomationNode, kind: AutomationKind, clip id: UUID) {
        guard let i = editable(id) else { return }
        var nodes = clips[i].automation.nodes(kind)
        guard let n = nodes.firstIndex(of: node) else { return }
        nodes[n].value = kind.restValue
        clips[i].automation.setNodes(kind, nodes)
    }

    // MARK: - Gain

    /// Sets a clip's gain in dB, held to `Clip.gainRange` and rounded to
    /// whole dB - the only steps the − / + buttons make, so a gain that
    /// shows as "-1 dB" is exactly −1.
    mutating func setGain(_ id: UUID, _ dB: Double) {
        guard let i = index(of: id), dB.isFinite else { return }
        clips[i].gainDB = min(max(dB, Clip.gainRange.lowerBound), Clip.gainRange.upperBound).rounded()
    }

    /// One click of the − / + buttons. Steps from the rounded gain, so a
    /// value between whole dB lands on the grid rather than beside it; at
    /// either end of the range nothing changes, and no undo step is left.
    mutating func stepGain(_ id: UUID, by steps: Int) {
        guard let i = index(of: id) else { return }
        setGain(id, clips[i].gainDB.rounded() + Double(steps))
    }

    // MARK: - Key

    /// Sets how many semitones a clip is shifted, held to
    /// `Clip.keyShiftRange`.
    mutating func setKeyShift(_ id: UUID, _ semitones: Int) {
        guard let i = index(of: id) else { return }
        clips[i].keyShift = min(max(semitones, Clip.keyShiftRange.lowerBound), Clip.keyShiftRange.upperBound)
    }

    /// One click of the key − / + buttons; at either end nothing changes.
    mutating func stepKeyShift(_ id: UUID, by steps: Int) {
        guard let i = index(of: id) else { return }
        setKeyShift(id, clips[i].keyShift + steps)
    }

    // MARK: - Lane colour

    /// Sets a lane's colour. The lane's own default is stored as nil, like
    /// no colour at all, so choosing it again and "Use Default" save the same
    /// file; so is anything that is not a colour.
    mutating func setLaneColor(_ lane: Int, _ hex: String?) {
        guard lanes.indices.contains(lane) else { return }
        let chosen = hex.flatMap(HexColor.normalized)
        lanes[lane].color = chosen == LaneSettings.defaultColors[lane] ? nil : chosen
    }

    // MARK: - Mute

    mutating func setMuted(_ id: UUID, _ muted: Bool) {
        guard let i = index(of: id) else { return }
        clips[i].muted = muted
    }

    mutating func setLocked(_ id: UUID, _ locked: Bool) {
        guard let i = index(of: id) else { return }
        clips[i].locked = locked
    }
}
