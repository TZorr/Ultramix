//
//  Clip.swift
//  Ultramix
//
//  A track placed on the timeline, and the arithmetic of where it sounds.
//
//  A clip is pinned by its first downbeat, not by the start of its file:
//  `anchorBeat` is the timeline beat the track's bar one lands on, and any
//  intro before it hangs to the left as pre-roll. Two clips anchored on bar
//  lines have their bar lines on top of each other, whatever their files hold
//  before the music starts.
//
//  All geometry is in timeline beats: one source beat plays as one timeline
//  beat. How long a beat lasts is the tempo map's business, and the stretch
//  ratio falls out of that rather than being stored.
//

import Foundation

nonisolated struct Clip: Identifiable, Codable, Sendable, Equatable {
    static let laneCount = 3
    static let beatsPerBar = 4
    /// Shortest a trim may leave a clip. Shorter than this and the clip is
    /// too narrow to grab to make it longer again.
    static let minimumBeats = 0.5
    /// What a clip's gain may be. The ceiling is the volume lane's, so a
    /// clip cannot be pushed further than a drawn curve could push it; the
    /// floor is quiet enough to tuck a clip under another without muting it.
    static let gainRange = -24.0...Automation.maxVolumeDB
    /// How far a clip's key may be moved, in semitones. Half an octave
    /// either way reaches every key; further, voices start to sound wrong.
    static let keyShiftRange = -6...6
    /// The fine tune, in cents: up to a quarter tone either way, in steps of
    /// 5 - finer than anyone hears, coarse enough that a few clicks get there
    /// and every step is a render of its own.
    static let fineTuneRange = -50...50
    static let fineTuneStep = 5

    let id: UUID
    var trackID: UUID
    var lane: Int
    /// Timeline beat of the track's first downbeat.
    var anchorBeat: Int
    /// Timeline beat of this clip's tempo target. Independent of the anchor,
    /// so the ramp into a clip can finish anywhere inside it.
    var tempoAnchorBeat: Int
    /// The tempo the mix reaches at `tempoAnchorBeat`. Nil plays the track
    /// at its own tempo there.
    var targetBPM: Double?
    /// Timeline beat where the ramp into `tempoAnchorBeat` begins. Before it
    /// the mix holds the tempo it had; nil ramps all the way from the
    /// previous tempo point. Part of the clip rather than a free point on the
    /// tempo strip, so it travels with the clip - a free point would stay
    /// behind when the clip moved, and the ramp would quietly change length.
    var rampStartBeat: Int?
    /// Beats hidden at the head and the tail, in the clip's own beats.
    var trimStart: Double
    var trimEnd: Double
    /// While looping, the edge handles extend the clip by repeating its
    /// trimmed body instead of trimming it. Turning looping off restores the
    /// clip exactly as it was: lead and tail are dropped, the trim is kept.
    var looping: Bool
    var loopLead: Double
    var loopTail: Double
    var muted: Bool
    /// A locked clip keeps its place: it cannot be dragged, nudged or moved
    /// to another lane, and its automation cannot be changed - by hand, by
    /// a transition or by a beatmix. Trim, gain, tempo, loop, mute, split
    /// and delete still work.
    var locked: Bool
    /// A level change for the whole clip, in whole dB; 0 plays the file as
    /// it is.
    /// Applied to the clip's own samples, before its lane's volume, pan and
    /// filter - so a fade drawn on the lane still fades from wherever the
    /// gain put the clip, and a transition works on it unchanged.
    var gainDB: Double
    /// Semitones the clip plays higher (or lower); 0 plays the file as it
    /// is. The length stays: a shifted clip is the same file at another
    /// pitch, rendered once into the audio cache (KeyShifter), so the grid,
    /// the stretcher and every curve on the clip are unchanged.
    var keyShift: Int
    /// Cents on top of `keyShift`, a multiple of `fineTuneStep` - for a
    /// record that is a little off concert pitch. Rendered together with the
    /// key shift (PitchShift).
    var fineTune: Int
    /// Volume, pan and filter drawn on the clip, in clip-local beats
    /// (timeline beat − `anchorBeat`). Moves, copies and deletes with the
    /// clip; what a trim hides stays here, silent, until the clip is
    /// extended again. See Automation.swift.
    var automation: ClipAutomation

    init(id: UUID = UUID(), trackID: UUID, lane: Int, anchorBeat: Int, tempoAnchorBeat: Int? = nil,
         targetBPM: Double? = nil, rampStartBeat: Int? = nil, trimStart: Double = 0, trimEnd: Double = 0,
         looping: Bool = false, loopLead: Double = 0, loopTail: Double = 0, muted: Bool = false,
         locked: Bool = false, gainDB: Double = 0, keyShift: Int = 0, fineTune: Int = 0,
         automation: ClipAutomation = ClipAutomation()) {
        self.id = id
        self.trackID = trackID
        self.lane = lane
        self.anchorBeat = anchorBeat
        self.tempoAnchorBeat = tempoAnchorBeat ?? anchorBeat
        self.targetBPM = targetBPM
        self.rampStartBeat = rampStartBeat
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.looping = looping
        self.loopLead = loopLead
        self.loopTail = loopTail
        self.muted = muted
        self.locked = locked
        self.gainDB = gainDB
        self.keyShift = keyShift
        self.fineTune = fineTune
        self.automation = automation
    }

    enum CodingKeys: String, CodingKey {
        case id, trackID, lane, anchorBeat, tempoAnchorBeat, targetBPM, rampStartBeat
        case trimStart, trimEnd, looping, loopLead, loopTail, muted, locked, gainDB, keyShift, fineTune, automation
    }

    /// Written by hand so that a gain of 0, no pitch shift and an empty
    /// automation leave no key: a clip that never used them saves exactly as
    /// it did before.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(trackID, forKey: .trackID)
        try c.encode(lane, forKey: .lane)
        try c.encode(anchorBeat, forKey: .anchorBeat)
        try c.encode(tempoAnchorBeat, forKey: .tempoAnchorBeat)
        try c.encodeIfPresent(targetBPM, forKey: .targetBPM)
        try c.encodeIfPresent(rampStartBeat, forKey: .rampStartBeat)
        try c.encode(trimStart, forKey: .trimStart)
        try c.encode(trimEnd, forKey: .trimEnd)
        try c.encode(looping, forKey: .looping)
        try c.encode(loopLead, forKey: .loopLead)
        try c.encode(loopTail, forKey: .loopTail)
        try c.encode(muted, forKey: .muted)
        if locked { try c.encode(locked, forKey: .locked) }
        if gainDB != 0 { try c.encode(gainDB, forKey: .gainDB) }
        if keyShift != 0 { try c.encode(keyShift, forKey: .keyShift) }
        if fineTune != 0 { try c.encode(fineTune, forKey: .fineTune) }
        if !automation.isEmpty { try c.encode(automation, forKey: .automation) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        trackID = try c.decode(UUID.self, forKey: .trackID)
        lane = try c.decodeIfPresent(Int.self, forKey: .lane) ?? 0
        anchorBeat = try c.decodeIfPresent(Int.self, forKey: .anchorBeat) ?? 0
        tempoAnchorBeat = try c.decodeIfPresent(Int.self, forKey: .tempoAnchorBeat) ?? anchorBeat
        targetBPM = try c.decodeIfPresent(Double.self, forKey: .targetBPM)
        rampStartBeat = try c.decodeIfPresent(Int.self, forKey: .rampStartBeat)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? 0
        looping = try c.decodeIfPresent(Bool.self, forKey: .looping) ?? false
        loopLead = try c.decodeIfPresent(Double.self, forKey: .loopLead) ?? 0
        loopTail = try c.decodeIfPresent(Double.self, forKey: .loopTail) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        let gain = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        // Whole dB, like everything the buttons can set: a −1.5 from the
        // short time the gain was typed loads as −2.
        gainDB = gain.isFinite ? min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound).rounded() : 0
        let shift = try c.decodeIfPresent(Int.self, forKey: .keyShift) ?? 0
        keyShift = min(max(shift, Self.keyShiftRange.lowerBound), Self.keyShiftRange.upperBound)
        fineTune = Self.heldFineTune(try c.decodeIfPresent(Int.self, forKey: .fineTune) ?? 0)
        automation = try c.decodeIfPresent(ClipAutomation.self, forKey: .automation) ?? ClipAutomation()
    }

    /// Cents on the nearest step, within the range.
    static func heldFineTune(_ cents: Int) -> Int {
        let step = Double(fineTuneStep)
        let stepped = Int((Double(cents) / step).rounded()) * fineTuneStep
        return min(max(stepped, fineTuneRange.lowerBound), fineTuneRange.upperBound)
    }
}

// MARK: - Geometry

/// Where a clip sits, in timeline beats, given its track's grid.
nonisolated struct ClipGeometry: Sendable, Equatable {
    /// Timeline beat at which the source file's first sample would play.
    let fileStart: Double
    /// The trimmed body - what the clip is when it does not loop.
    let bodyStart: Double
    let bodyEnd: Double
    /// The visible extent, loop lead and tail included.
    let start: Double
    let end: Double

    var bodyLength: Double { bodyEnd - bodyStart }
    var length: Double { end - start }

    init(clip: Clip, grid: SourceGrid) {
        fileStart = Double(clip.anchorBeat) - grid.preRollBeats
        // Trims are stored in the track's own beats, so a tempo corrected
        // downwards after trimming - fewer beats in the same file - can leave
        // a trim longer than the whole track. A tempo typed as 40 where the
        // track was trimmed at 124 made a clip that ended 50 beats before it
        // started, and the first range built from it, in the render plan,
        // crashed the app every time the mix was opened. The trims are held
        // to what the file allows instead, the tail giving way before the
        // head, so the clip keeps its minimum length inside the file. The
        // stored trims are left as they are: putting the tempo back restores
        // the clip exactly.
        let length = max(grid.lengthBeats, 0)
        let keep = min(Clip.minimumBeats, length)
        let head = min(max(clip.trimStart, 0), length - keep)
        let tail = min(max(clip.trimEnd, 0), length - keep - head)
        bodyStart = fileStart + head
        bodyEnd = fileStart + length - tail
        start = bodyStart - (clip.looping ? clip.loopLead : 0)
        end = bodyEnd + (clip.looping ? clip.loopTail : 0)
    }

    func contains(_ beat: Double) -> Bool { beat >= start && beat < end }

    /// Same-lane overlap test. The tolerance lets two clips meet end to end
    /// even when floating point leaves them a hair apart.
    func overlaps(_ other: ClipGeometry, tolerance: Double = 0.05) -> Bool {
        start < other.end - tolerance && other.start < end - tolerance
    }
}

/// A stretch of the timeline that plays a stretch of one source file.
///
/// Non-looping clips are one segment. A looping clip is unrolled into
/// consecutive segments, each a copy of the body; the renderer never needs to
/// know what a loop is, and the timeline draws the same segments it hears.
nonisolated struct ClipSegment: Sendable, Equatable {
    let start: Double
    let end: Double
    /// Timeline beat at which the source's first sample would play *for this
    /// segment*. Source beat = timeline beat − fileStart.
    let fileStart: Double
}

nonisolated extension ClipGeometry {
    /// The segments that make up the clip, left to right.
    ///
    /// Copies are laid out from the body in both directions, so one copy sits
    /// exactly on the original body: dragging the loop out on one side can
    /// never shift what plays on the other. The outermost copies are cut at
    /// the clip's edges, which is only a trim.
    func segments() -> [ClipSegment] {
        let body = bodyLength
        guard body > 1e-6 else { return [] }
        guard start < bodyStart - 1e-9 || end > bodyEnd + 1e-9 else {
            return [ClipSegment(start: bodyStart, end: bodyEnd, fileStart: fileStart)]
        }
        let before = Int(((bodyStart - start) / body).rounded(.up))
        let after = Int(((end - bodyEnd) / body).rounded(.up))
        var result: [ClipSegment] = []
        for copy in -before...after {
            let shift = Double(copy) * body
            let segmentStart = max(start, bodyStart + shift)
            let segmentEnd = min(end, bodyEnd + shift)
            // A sliver a thousandth of a beat long is floating-point residue,
            // not a copy anybody asked for.
            if segmentEnd - segmentStart > 1e-3 {
                result.append(ClipSegment(start: segmentStart, end: segmentEnd, fileStart: fileStart + shift))
            }
        }
        return result
    }
}
