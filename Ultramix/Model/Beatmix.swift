//
//  Beatmix.swift
//  Ultramix
//
//  "Beatmix 16" puts the next record on the end of the mix, sixteen beats over
//  the last one, and writes the handover as it goes. Where a transition
//  (Crossfade.swift) covers an overlap the user already made, a beatmix makes
//  the overlap itself: it ends on the last bar line the outgoing clip reaches
//  and starts N beats before, with the incoming clip's bar one on that start.
//  Both edges are bar lines, so the two records' bars sit on top of each other.
//
//  The handover is three volume points per clip, all on whole beats - few
//  enough to reshape by hand, and a straight line needs no more. Both records
//  stay loud: the outgoing one sinks by `dipDB` while the incoming one rises
//  from `dipDB`, then the outgoing one is cut. A fade to silence along a
//  straight line in dB would have it gone by the middle, which is not a
//  beatmix. So each curve has a step: the outgoing clip's last two points
//  share the end beat, the incoming clip's first two the start beat.
//  `ClipAutomation.setNodes` sorts stably so the pair keeps its order.
//
//  The result is an ordinary transition in the sense of `transitions()`, so
//  ⇧⌘X can still replace it with any style.
//
//  No Transition sits in the same list: the track goes after the end of the
//  mix, on the first bar line its intro allows, with nothing written.
//
//  "The end of the mix" is where the music ends, not the file: many files
//  carry seconds of silence after the last note
//  (`LoudnessProfile.soundEndSeconds`), and a beatmix measured from the file's
//  end would overlap that silence instead of the record.
//
//  The same handover goes in at the playhead (`insertClip`): it starts on the
//  playing record's next four-bar line, that record is cut where it ends, and
//  the rest of the mix moves to follow.
//

import Foundation

/// How a track added at the end goes into the mix: no transition, or a
/// beatmix of so many beats.
nonisolated enum BeatmixLength: Int, CaseIterable, Identifiable, Sendable {
    case noTransition = 0
    case beats4 = 4, beats8 = 8, beats16 = 16, beats32 = 32, beats64 = 64

    var id: Int { rawValue }
    var beats: Int { rawValue }
    var title: String { self == .noTransition ? "No Transition" : "Beatmix \(rawValue)" }

    var summary: String {
        if self == .noTransition {
            return "Adds the track after the end of the mix, on the next bar line, with no overlap and no points."
        }
        let bars = rawValue / Clip.beatsPerBar
        return "Adds the track at the end of the mix, \(rawValue) beats (\(bars) \(bars == 1 ? "bar" : "bars")) over the last clip, with a three-point handover that cuts at the end."
    }

    /// How far each record sits below its level while the other is in: the
    /// outgoing one at the end, the incoming one at the start.
    static let dipDB = -6.0

    static let storageKey = "beatmixLength"

    /// The length chosen last on this Mac; 16 until one has been chosen.
    static var current: BeatmixLength {
        // `integer(forKey:)` reads 0 for a missing key, which is No
        // Transition - not what an untouched Mac should start with.
        get {
            (UserDefaults.standard.object(forKey: storageKey) as? Int).flatMap(BeatmixLength.init) ?? .beats16
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

/// What Return and a double-click in the library do with the selected
/// tracks: the plain add, a beatmix at the end, or a beatmix at the
/// playhead. Chosen in the library's bottom bar and
/// kept per Mac. Dragging onto a lane stays the plain add where it lands.
nonisolated enum LibraryAddMode: Hashable, CaseIterable, Sendable {
    case plain
    case end(BeatmixLength)
    /// Never with No Transition - a hard cut is not what goes in there.
    case playhead(BeatmixLength)
    /// At the next cue point of the record playing; No Transition for the
    /// same reason.
    case cue(BeatmixLength)

    static let allCases: [LibraryAddMode] = [.plain]
        + BeatmixLength.allCases.map { .end($0) }
        + BeatmixLength.allCases.filter { $0 != .noTransition }.map { .playhead($0) }
        + BeatmixLength.allCases.filter { $0 != .noTransition }.map { .cue($0) }

    var title: String {
        switch self {
        case .plain: "Add"
        case .end(let length): length.title
        case .playhead(let length): "At Playhead: \(length.title)"
        case .cue(let length): "At Cue: \(length.title)"
        }
    }

    /// For the narrow bar the menu sits in; `title` goes in its help.
    var shortTitle: String {
        switch self {
        case .plain: "Add"
        case .end(.noTransition): "No Trans."
        case .end(let length): "Mix \(length.beats)"
        case .playhead(let length): "Here \(length.beats)"
        case .cue(let length): "Cue \(length.beats)"
        }
    }

    var rawValue: String {
        switch self {
        case .plain: "plain"
        case .end(let length): "end-\(length.beats)"
        case .playhead(let length): "playhead-\(length.beats)"
        case .cue(let length): "cue-\(length.beats)"
        }
    }

    init?(rawValue: String) {
        guard let mode = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = mode
    }

    static let storageKey = "libraryAddMode"

    /// The mode chosen last on this Mac; the plain add until one has been
    /// chosen, which is what Return did before there was a choice.
    static var current: LibraryAddMode {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(LibraryAddMode.init) ?? .plain }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

nonisolated extension MixDocument {
    /// Places a track at the end of the mix with a beatmix of `beatmix` into
    /// it - or, with No Transition, right after the end - and returns the new
    /// clip's id. The first clip of a mix has nothing to mix into and is
    /// placed as `addClip` places it.
    @discardableResult
    ///
    /// - Parameter stepTempo: only in a live set: the tempo changes where
    ///   the new track begins - with No Transition at its first beat, with
    ///   a beatmix where the beatmix starts - as a step, instead of ramping
    ///   across the record still playing. Each song plays at its own tempo;
    ///   the one before does not drift toward the next. Auto adds this way,
    ///   as soon as the previous track plays, so a ramp would span a whole
    ///   song.
    /// - Parameter draft: what to place - the whole record, or a loop cut
    ///   out of it (`ClipDraft.loop`). A loop is placed by its first sample
    ///   instead of by the record's bar one; everything else about the
    ///   beatmix is the same.
    mutating func addClip(trackID: UUID, grid: SourceGrid, beatmix: BeatmixLength, grids: GridLookup,
                          stepTempo: Bool = false, draft: ClipDraft = .record) throws -> UUID {
        func lookup(_ id: UUID) -> SourceGrid? { id == trackID ? grid : grids(id) }
        let placed = clips.enumerated().compactMap { index, clip -> (index: Int, shape: ClipGeometry, end: Double)? in
            guard let clipGrid = lookup(clip.trackID) else { return nil }
            let shape = ClipGeometry(clip: clip, grid: clipGrid)
            return (index, shape, Self.soundEnd(clip, shape, clipGrid))
        }
        // The clip the mix ends on; of two ending together, the one added later.
        guard let last = placed.max(by: { $0.end < $1.end || ($0.end == $1.end && $0.index < $1.index) })
        else {
            return try addClip(trackID: trackID, grid: grid, grids: grids, draft: draft)
        }
        let outgoing = clips[last.index]
        let bar = Clip.beatsPerBar
        let lanes = (1...Clip.laneCount).map { (outgoing.lane + $0) % Clip.laneCount }

        if beatmix == .noTransition {
            var clip = draft.applied(to: Clip(trackID: trackID, lane: lanes[0], anchorBeat: 0))
            // The first sound of the new clip goes after the last one of the
            // mix: its anchor, plus whatever lies between anchor and sound -
            // an intro to the left of bar one, or a loop starting after it.
            let after = Int(((last.end - draft.startOffset(grid) - 1e-9) / Double(bar)).rounded(.up)) * bar
            clip.anchorBeat = max(after, Self.minimumAnchor(clip, grid))
            clip.tempoAnchorBeat = clip.anchorBeat
            // Nothing sounds after the end, but a clip's silent tail may
            // still lie there, so the lanes are tried in turn.
            guard lanes.contains(where: { candidate in
                clip.lane = candidate
                return fits(clip, lookup)
            }) else { throw EditError("There is no room for the track after the end of the mix.") }
            if stepTempo {
                // On the first whole beat of the new clip that lies past the
                // old record's sound, and never after its bar one.
                let start = ClipGeometry(clip: clip, grid: grid).start
                let point = min(clip.anchorBeat, max(Int((last.end - 1e-9).rounded(.up)), Int(start.rounded(.down))))
                clip.tempoAnchorBeat = point
                clip.rampStartBeat = point - 1
            }
            clips.append(clip)
            return clip.id
        }

        let end = Int(((last.end + 1e-9) / Double(bar)).rounded(.down)) * bar
        let start = end - beatmix.beats
        guard Double(start) > last.shape.start + 1e-6 else {
            throw EditError("The last clip is shorter than \(beatmix.beats) beats, so there is no room for a \(beatmix.title).")
        }

        // A record's bar one lands on the beatmix; a loop's first sample
        // does, which puts its bar one `leadBeats` earlier.
        var clip = draft.applied(to: Clip(trackID: trackID, lane: 0, anchorBeat: start - draft.leadBeats))
        clip.tempoAnchorBeat = start
        guard clip.anchorBeat >= Self.minimumAnchor(clip, grid) else {
            throw EditError("The track's intro reaches back past the start of the mix.")
        }
        let shape = ClipGeometry(clip: clip, grid: grid)
        guard shape.start > last.shape.start + 1e-6, Self.soundEnd(clip, shape, grid) > last.end + 1e-6 else {
            throw EditError(draft.looping
                ? "The loop ends before the last clip does - let it repeat more often."
                : "The track is too short for a \(beatmix.title) - it would end before the last clip does.")
        }
        guard let lane = lanes.dropLast().first(where: { candidate in
            clip.lane = candidate
            return fits(clip, lookup)
        }) else {
            throw EditError("No other lane has room for the track at beat \(start).")
        }
        clip.lane = lane

        // A locked clip keeps its automation; the track still comes in over it.
        if !outgoing.locked {
            writeFadeOut(index: last.index, start: start, end: end)
        }
        clip.automation.setNodes(.volume, Self.fadeIn(from: Double(draft.leadBeats), beats: beatmix.beats))
        clip.automation.transitions = [Self.handoverMark(lead: draft.leadBeats, beats: beatmix.beats)]
        if stepTempo { clip.rampStartBeat = clip.tempoAnchorBeat - 1 }
        clips.append(clip)
        return clip.id
    }

    /// How far apart the points are where a beatmix at the playhead may
    /// start: four bars of the outgoing record, counted from its bar one.
    static let insertPhraseBeats = 16

    /// The lanes on which a clip is heard at `beat`: not muted, on a lane
    /// the mask lets through, and not in its silent tail. During a beatmix
    /// that is two. For the play mark in the lane headers.
    func soundingLanes(atBeat beat: Double, grids: GridLookup, laneMask: Int) -> Set<Int> {
        Set(clips.compactMap { clip -> Int? in
            guard !clip.muted, laneMask & (1 << clip.lane) != 0, let grid = grids(clip.trackID) else { return nil }
            let shape = ClipGeometry(clip: clip, grid: grid)
            return shape.start <= beat && beat < Self.soundEnd(clip, shape, grid) ? clip.lane : nil
        })
    }

    /// The record playing at `beat`; of two, the one that came in last,
    /// which is the one the mix is on. Muted clips and silent tails do not
    /// count.
    func playing(atBeat beat: Double, grids: GridLookup) -> (index: Int, shape: ClipGeometry, end: Double)? {
        let sounding = clips.enumerated().compactMap { index, clip -> (index: Int, shape: ClipGeometry, end: Double)? in
            guard !clip.muted, let clipGrid = grids(clip.trackID) else { return nil }
            let shape = ClipGeometry(clip: clip, grid: clipGrid)
            let end = Self.soundEnd(clip, shape, clipGrid)
            return shape.start <= beat && beat < end ? (index, shape, end) : nil
        }
        return sounding.max(by: { $0.shape.start < $1.shape.start })
    }

    /// The record a new one is mixed out of: the one playing at `beat`, or -
    /// stopped before the mix, or standing in a gap - the one the mix ends
    /// on, which is the record a beatmix at the end would use. Of two ending
    /// together, the one added later.
    func outgoing(atBeat beat: Double, grids: GridLookup) -> (index: Int, shape: ClipGeometry, end: Double)? {
        if let playing = playing(atBeat: beat, grids: grids) { return playing }
        return clips.enumerated().compactMap { index, clip -> (index: Int, shape: ClipGeometry, end: Double)? in
            guard let clipGrid = grids(clip.trackID) else { return nil }
            let shape = ClipGeometry(clip: clip, grid: clipGrid)
            return (index, shape, Self.soundEnd(clip, shape, clipGrid))
        }
        .max(by: { $0.end < $1.end || ($0.end == $1.end && $0.index < $1.index) })
    }

    /// Puts a track into the mix at the playhead `playhead` with a beatmix
    /// of `beatmix` from the record playing there, and returns the new
    /// clip's id.
    ///
    /// The beatmix starts on the outgoing record's next four-bar line at
    /// least a bar ahead. The new clip's bar one lands there, the outgoing
    /// clip is trimmed where the beatmix ends, and the clips after it move
    /// by whole bars so they stand to the new record's end as they stood to
    /// the old one's. The new record then fades out into the next clip as
    /// the old one did, with the same three points; that clip keeps its own
    /// fade-in.
    @discardableResult
    mutating func insertClip(trackID: UUID, grid: SourceGrid, beatmix: BeatmixLength,
                             atBeat playhead: Double, grids: GridLookup,
                             draft: ClipDraft = .record) throws -> UUID {
        guard beatmix != .noTransition else {
            throw EditError("A track goes in at the playhead with a beatmix only.")
        }
        // The first track of a mix has nothing to be mixed out of: it goes
        // in the way the first track always does, as the beatmix at the end
        // does too. Without this, a live set - which always starts empty -
        // refused its first track when Return was set to At Playhead.
        if clips.isEmpty { return try addClip(trackID: trackID, grid: grid, grids: grids, draft: draft) }
        func lookup(_ id: UUID) -> SourceGrid? { id == trackID ? grid : grids(id) }
        guard let out = playing(atBeat: playhead, grids: lookup) else {
            throw EditError("Nothing plays at the playhead.")
        }
        let outgoing = clips[out.index]

        let phrase = Self.insertPhraseBeats
        let earliest = playhead + Double(Clip.beatsPerBar)
        let phrases = Int(((earliest - Double(outgoing.anchorBeat) - 1e-9) / Double(phrase)).rounded(.up))
        let start = outgoing.anchorBeat + phrases * phrase
        return try insert(trackID: trackID, grid: grid, beatmix: beatmix, startingAt: start,
                          outgoing: out, draft: draft, lookup: lookup)
    }

    /// The part every insert shares: the outgoing record is cut where the
    /// beatmix ends, the rest of the mix moves with it, and the new clip
    /// goes in the gap that leaves. Only the beat the beatmix starts on
    /// differs - the next four-bar line at the playhead, a cue's bar line
    /// at a cue.
    @discardableResult
    mutating func insert(trackID: UUID, grid: SourceGrid, beatmix: BeatmixLength, startingAt start: Int,
                         outgoing out: (index: Int, shape: ClipGeometry, end: Double),
                         draft: ClipDraft, lookup: GridLookup) throws -> UUID {
        let bar = Clip.beatsPerBar
        func lastBar(_ beat: Double) -> Int { Int(((beat + 1e-9) / Double(bar)).rounded(.down)) * bar }
        let outgoing = clips[out.index]
        let end = start + beatmix.beats
        guard Double(end) <= out.end + 1e-9 else {
            throw EditError("Not enough of the record playing is left for a \(beatmix.title).")
        }

        var clip = draft.applied(to: Clip(trackID: trackID, lane: 0, anchorBeat: start - draft.leadBeats))
        clip.tempoAnchorBeat = start
        guard clip.anchorBeat >= Self.minimumAnchor(clip, grid) else {
            throw EditError("The track's intro reaches back past the start of the mix.")
        }
        let shape = ClipGeometry(clip: clip, grid: grid)
        let newEnd = Self.soundEnd(clip, shape, grid)
        guard newEnd > Double(end) + 1e-6 else {
            throw EditError(draft.looping
                ? "The loop is over before the \(beatmix.title) ends - let it repeat more often."
                : "The track is too short for a \(beatmix.title).")
        }
        let shift = lastBar(newEnd) - lastBar(out.end)
        let followers = Set(clips.compactMap { other -> UUID? in
            guard other.id != outgoing.id, let otherShape = geometry(other, lookup),
                  otherShape.start >= Double(start) - 1e-9 else { return nil }
            return other.id
        })

        // Trim first, so a follower moving left has room; then the rest of
        // the mix; then the new clip into the space that leaves. On a copy,
        // so a refusal at any step leaves the mix as it was.
        var result = self
        try result.trimClip(outgoing.id, edge: .end, to: Double(end), grids: lookup)
        try result.nudgeClips(followers, byBeats: shift, grids: lookup)
        let lanes = (1..<Clip.laneCount).map { (outgoing.lane + $0) % Clip.laneCount }
        guard let lane = lanes.first(where: { candidate in
            clip.lane = candidate
            return result.fits(clip, lookup)
        }) else {
            throw EditError("No other lane has room for the track at beat \(start).")
        }
        clip.lane = lane

        // A locked clip is trimmed but keeps its automation.
        if !outgoing.locked, let index = result.index(of: outgoing.id) {
            result.writeFadeOut(index: index, start: start, end: end)
        }
        clip.automation.setNodes(.volume, Self.fadeIn(from: Double(draft.leadBeats), beats: beatmix.beats))
        clip.automation.transitions = [Self.handoverMark(lead: draft.leadBeats, beats: beatmix.beats)]
        result.clips.append(clip)

        // The handover into the rest of the mix: the moved clip that comes
        // in first while the new record still plays.
        let newLastBar = lastBar(newEnd)
        let next = result.clips.filter { followers.contains($0.id) && !$0.muted }
            .filter { $0.anchorBeat > start && $0.anchorBeat < newLastBar }
            .min { $0.anchorBeat < $1.anchorBeat }
        if let next, let index = result.index(of: clip.id) {
            result.writeFadeOut(index: index, start: next.anchorBeat, end: newLastBar)
        }
        self = result
        return clip.id
    }

    /// The timeline beat where `clip` stops sounding: the end of the music
    /// in its file, unless the clip ends before that or loops.
    static func soundEnd(_ clip: Clip, _ shape: ClipGeometry, _ grid: SourceGrid) -> Double {
        guard !clip.looping else { return shape.end }
        return max(shape.bodyStart, min(shape.end, shape.fileStart + grid.soundLengthBeats))
    }

    /// The outgoing clip's side of a beatmix from timeline beat `start` to
    /// `end`: its level where the beatmix starts - unless that is silence,
    /// since sinking from silence would be no handover - then down by the
    /// dip, and cut. Points after `start` are replaced.
    private mutating func writeFadeOut(index: Int, start: Int, end: Int) {
        let anchor = clips[index].anchorBeat
        let (localStart, localEnd) = (Double(start - anchor), Double(end - anchor))
        let existing = clips[index].automation.volume
        let reference = AutomationCurve(kind: .volume, automation: clips[index].automation).value(at: localStart)
        let full = reference <= Automation.silenceDB + 0.5 ? Automation.defaultVolumeDB : reference
        clips[index].automation.setNodes(.volume, existing.filter { $0.beat < localStart - 1e-9 } + [
            AutomationNode(beat: localStart, value: full),
            AutomationNode(beat: localEnd, value: Self.dipped(full)),
            AutomationNode(beat: localEnd, value: Automation.silenceDB),
        ])
    }

    /// The incoming clip's side, in its own beats: in at the dip, up to the
    /// lane's resting level. `from` is where its sound begins - bar one,
    /// beat 0, for a record; the start of the loop for a loop.
    static func fadeIn(from: Double = 0, beats: Int) -> [AutomationNode] {
        let level = Automation.defaultVolumeDB
        return [
            AutomationNode(beat: from, value: Automation.silenceDB),
            AutomationNode(beat: from, value: dipped(level)),
            AutomationNode(beat: from + Double(beats), value: level),
        ]
    }

    /// The bar over the handover, on the incoming clip: no style, since a
    /// beatmix's three points are none of them.
    static func handoverMark(lead: Int, beats: Int) -> TransitionMark {
        TransitionMark(start: Double(lead), end: Double(lead + beats), style: nil)
    }

    private static func dipped(_ dB: Double) -> Double {
        max(Automation.silenceDB, dB + BeatmixLength.dipDB)
    }
}
