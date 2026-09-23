//
//  LiveSet.swift
//  Ultramix
//
//  The rules of live mode: the timeline with two differences - it never holds
//  more than three clips, and what has played is let go of.
//
//  Letting go is the hard part. The tempo map sums seconds from beat 0 and the
//  engine plays by a frame counter, so deleting played clips would take their
//  tempo points with them and every later beat would land at another second.
//  The set is rebased instead: everything left moves back by P beats, the
//  tempo playing at P becomes the tempo at the new beat 0, and the clock time
//  of P becomes the map's origin. The map holds its tempo per whole beat and
//  interpolates linearly, so from P on it is the same map beat for beat, and
//  the frame counter runs on without knowing anything happened.
//
//  Pure: the session calls it on a timer, and the harness checks it.
//

import Foundation

nonisolated enum LiveSet {
    /// The clip playing and the ones waiting. During a beatmix two of them
    /// play at once, which leaves one waiting.
    static let clipLimit = 3
    /// How long a clip stays after it ended: a bar, so it does not vanish
    /// the moment the playhead leaves it.
    static let keepBeats = Double(Clip.beatsPerBar)

    enum Outcome: Equatable {
        /// Nothing to let go of yet.
        case unchanged
        /// Played clips removed, the rest moved back by `shift` beats.
        case rebased(MixDocument, shift: Int)
        /// Everything has played: the set is as it was when live mode began.
        case emptied(MixDocument)
    }

    /// Why an edit that took the set from `before` to `after` clips is
    /// refused, or nil when it is not. Fewer clips, or no more than before,
    /// is always allowed - deleting must work when the set is full.
    static func refusal(before: Int, after: Int) -> String? {
        guard after > before, after > clipLimit else { return nil }
        return "Live holds three clips: the one playing and two waiting. Add the next one once the oldest has played."
    }

    /// The lanes top to bottom after the set changed from `before` to
    /// `after`, given the order the rows had: the lanes with a clip on them
    /// in the order they had, then the lanes that were already empty, and
    /// at the very bottom the ones that have just become empty - let go
    /// of, deleted, or their clip dragged away. The others move up, which
    /// is the clearest reading of the set. The lane itself never changes;
    /// its name, colour, mute and solo go with it.
    ///
    /// The just-emptied lane goes below the older empty ones on purpose:
    /// in their old order the lane that played sat above the one the next
    /// beatmix goes to, and that lane then moved up the moment the track
    /// landed. This way adding moves nothing.
    static func compacted(_ order: [Int], before: MixDocument, after: MixDocument) -> [Int] {
        func taken(_ lane: Int, _ document: MixDocument) -> Bool { document.clips.contains { $0.lane == lane } }
        let full = order.filter { taken($0, after) }
        let emptyBefore = order.filter { !taken($0, after) && !taken($0, before) }
        let justEmptied = order.filter { !taken($0, after) && taken($0, before) }
        return full + emptyBefore + justEmptied
    }

    // MARK: - Adding while the set plays

    /// Keeps an edit from changing the tempo of what has already played.
    ///
    /// A new tempo point ramps from the point before it, and in a playing
    /// set that point lies behind the playhead - so every beat since then
    /// got a new tempo, the clock moved under the playhead, and the set
    /// jumped: 1.6 to 3.1 beats for a 128 BPM track added halfway through
    /// a 124 one. A mix is being edited and takes that; a set is heard.
    ///
    /// So every clip whose tempo is new or changed, and whose point lies
    /// ahead, has its ramp begin no earlier than the next bar line after
    /// the playhead. A point closer than that becomes a step one beat before
    /// it. Nothing else changes; the result is refused by the caller if the
    /// time at the playhead still moved (see `clockMoved`).
    static func protectPast(_ new: MixDocument, old: MixDocument, playhead: Double) -> MixDocument {
        let bar = Clip.beatsPerBar
        let nextBar = (Int((playhead / Double(bar)).rounded(.down)) + 1) * bar
        let before = Dictionary(old.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = new
        for index in result.clips.indices {
            let clip = result.clips[index]
            if let was = before[clip.id], was.tempoAnchorBeat == clip.tempoAnchorBeat,
               was.targetBPM == clip.targetBPM, was.rampStartBeat == clip.rampStartBeat { continue }
            guard Double(clip.tempoAnchorBeat) > playhead else { continue }
            if let start = clip.rampStartBeat, start >= nextBar { continue }
            result.clips[index].rampStartBeat = nextBar < clip.tempoAnchorBeat ? nextBar : clip.tempoAnchorBeat - 1
        }
        return result
    }

    /// Whether going from `old` to `new` moves the time at which `playhead`
    /// plays - the one thing an edit to a playing set must not do.
    static func clockMoved(_ new: MixDocument, old: MixDocument, playhead: Double, grids: GridLookup) -> Bool {
        abs(new.tempoMap(grids).seconds(atBeat: playhead) - old.tempoMap(grids).seconds(atBeat: playhead)) > 1e-9
    }

    // MARK: - Auto

    /// How Auto brings the next track in: a one-bar beatmix, so there is
    /// no gap. No Transition left a pause of up to a bar plus the new
    /// track's intro.
    static let autoBeatmix = BeatmixLength.beats4

    /// Whether Auto should add a track: the set has one, and nothing waits -
    /// no clip starts after the playhead. Auto never starts a set by itself.
    static func needsAuto(_ document: MixDocument, playhead: Double, grids: GridLookup) -> Bool {
        let starts = document.clips.compactMap { document.geometry($0, grids)?.start }
        return !starts.isEmpty && !starts.contains { $0 > playhead }
    }

    /// The track Auto takes: the one after `lastAdded` in the library's
    /// visible order - its sort, its search and its BPM range - skipping
    /// tracks in the set and tracks with no beatgrid yet. When `lastAdded`
    /// is not in the list (filtered away, or nothing added yet), the first
    /// one that qualifies. Nil at the end of the list: Auto does not start
    /// over, so nothing repeats without anyone noticing.
    static func autoNext(order: [UUID], lastAdded: UUID?, inSet: Set<UUID>, hasGrid: (UUID) -> Bool) -> UUID? {
        let candidates: ArraySlice<UUID>
        if let lastAdded, let index = order.firstIndex(of: lastAdded) {
            candidates = order[(index + 1)...]
        } else {
            candidates = order[...]
        }
        return candidates.first { !inSet.contains($0) && hasGrid($0) }
    }

    static func pruned(_ document: MixDocument, playhead: Double, playing: Bool, grids: GridLookup) -> Outcome {
        let shapes = document.clips.compactMap { clip -> (clip: Clip, shape: ClipGeometry)? in
            guard let grid = grids(clip.trackID) else { return nil }
            return (clip, ClipGeometry(clip: clip, grid: grid))
        }
        guard !shapes.isEmpty else { return .unchanged }

        // Stopped at or after the end: the engine stops a second after the
        // last clip, before the bar of grace is over, and would otherwise
        // leave the set waiting behind a finished track.
        let finished = !playing && playhead >= document.endBeat(grids)
        let gone = Set(shapes.filter { finished || $0.shape.end <= playhead - keepBeats }.map(\.clip.id))
        guard !gone.isEmpty else { return .unchanged }
        guard gone.count < document.clips.count else {
            var empty = MixDocument(projectBPM: document.projectBPM)
            empty.lanes = document.lanes
            return .emptied(empty)
        }

        let bar = Clip.beatsPerBar
        func barBelow(_ beat: Double) -> Int { Int((beat / Double(bar)).rounded(.down)) * bar }
        // The earliest thing the remaining clips need: their left edge and
        // their tempo point. Rebasing past either would put it below 0.
        let staying = shapes.filter { !gone.contains($0.clip.id) }
        let earliest = staying.map { min($0.shape.start, Double($0.clip.tempoAnchorBeat)) }.min()!
        let shift = max(0, min(barBelow(earliest), barBelow(playhead)))
        // A played clip whose tempo point or ramp lies after P still shapes
        // the tempo there; letting it go would change what is playing. Wait.
        for clip in document.clips where gone.contains(clip.id) {
            if clip.tempoAnchorBeat > shift { return .unchanged }
            if let ramp = clip.rampStartBeat, ramp > shift { return .unchanged }
        }

        let map = document.tempoMap(grids)
        var result = document
        result.clips = document.clips.filter { !gone.contains($0.id) }
        // Also at a shift of 0: a played clip's tempo point on beat 0 was
        // the opening tempo, and the project tempo has to take it over.
        result.projectBPM = map.bpm(atBeat: Double(shift))
        result.timeOrigin = map.seconds(atBeat: Double(shift))
        for index in result.clips.indices {
            result.clips[index].anchorBeat -= shift
            result.clips[index].tempoAnchorBeat -= shift
            // A ramp that began before the new beat 0 is the same straight
            // line from there as a ramp from the start - which nil means.
            result.clips[index].rampStartBeat = result.clips[index].rampStartBeat
                .map { $0 - shift }.flatMap { $0 > 0 ? $0 : nil }
        }
        return .rebased(result, shift: shift)
    }
}
