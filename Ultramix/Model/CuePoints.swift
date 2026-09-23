//
//  CuePoints.swift
//  Ultramix
//
//  Where the next record comes in: up to eight marks a DJ sets in a song by
//  hand.
//
//  A cue point is a spot in the *song*, so it is kept in seconds of the file.
//  Correcting a tempo or nudging bar one moves the grid over the music, not
//  the music, and a cue set on the drop stays on the drop. Where the beatmix
//  needs a beat, the current grid turns the seconds into one.
//
//  A cue is approximate on purpose - it says which part of the record hands
//  over, not which sample - so `insertStart` rounds it to the outgoing
//  record's own bar lines.
//
//  They live on the Track, beside the grid correction and for the same reason:
//  a re-analysis has nowhere to write them.
//

import Foundation

nonisolated struct CuePoint: Codable, Sendable, Equatable, Identifiable {
    /// 1…8 - the number of the key that sets and recalls it. Also the
    /// identity: setting number 3 again moves the one cue 3, it does not
    /// make a second.
    var number: Int
    /// Where it sits in the song's file, in seconds.
    var seconds: Double

    var id: Int { number }

    init(number: Int, seconds: Double) {
        self.number = number
        self.seconds = max(0, seconds)
    }
}

/// How the model reaches a track's cue points without depending on the
/// library, as `GridLookup` reaches its grid.
typealias CueLookup = (UUID) -> [CuePoint]

nonisolated enum CueRules {
    /// Eight, the numbers a hand reaches without looking.
    static let count = 8
    static let numbers = 1...count

    /// Cue `number`, or nil where none is set.
    static func cue(_ cues: [CuePoint], number: Int) -> CuePoint? {
        cues.first { $0.number == number }
    }

    /// Sets or moves one cue and leaves the rest as they are. Out-of-range
    /// numbers are refused rather than stored, so nothing can arrive that a
    /// key cannot reach again.
    static func setting(_ cues: [CuePoint], number: Int, seconds: Double) -> [CuePoint] {
        guard numbers.contains(number) else { return cues }
        var result = cues.filter { $0.number != number }
        result.append(CuePoint(number: number, seconds: seconds))
        return result.sorted { $0.number < $1.number }
    }

    static func removing(_ cues: [CuePoint], number: Int) -> [CuePoint] {
        cues.filter { $0.number != number }
    }

    /// In the order they are heard, which is the order a mix uses them.
    static func inTimeOrder(_ cues: [CuePoint]) -> [CuePoint] {
        cues.sorted { $0.seconds < $1.seconds || ($0.seconds == $1.seconds && $0.number < $1.number) }
    }

    /// The lowest free number, for a cue dropped with the mouse rather than
    /// set with a key; nil once all eight are taken.
    static func freeNumber(_ cues: [CuePoint]) -> Int? {
        numbers.first { number in !cues.contains { $0.number == number } }
    }

    /// The timeline beat a cue of a clip's track falls on, given where that
    /// clip is anchored. Bar one of the song sits on `anchorBeat`, so a cue
    /// `s` seconds into the file lies `(s − firstBeat)` seconds of the
    /// song's own tempo past it.
    static func beat(ofCue seconds: Double, grid: SourceGrid, anchorBeat: Int) -> Double {
        Double(anchorBeat) + (seconds - grid.firstBeatSeconds) * grid.bpm / 60
    }

    /// The beat on which a beatmix at a cue starts: the cue rounded to the
    /// outgoing record's nearest bar line, of those at or after `notBefore`
    /// the earliest.
    ///
    /// Rounding to the record's own bars rather than the timeline's is what
    /// keeps the two records' bars on top of each other - the whole point of
    /// anchoring a clip by its downbeat. (Anchors snap to bar lines, so in
    /// practice the two grids are the same lines.)
    ///
    /// - Returns: nil when no cue is set, or all of them lie behind the
    ///   playhead - the caller says so rather than guessing at a spot.
    static func insertStart(cues: [CuePoint], grid: SourceGrid, anchorBeat: Int, notBefore: Double) -> Int? {
        let bar = Double(Clip.beatsPerBar)
        return cues.map { cue -> Int in
            let offset = beat(ofCue: cue.seconds, grid: grid, anchorBeat: anchorBeat) - Double(anchorBeat)
            return anchorBeat + Int((offset / bar).rounded()) * Clip.beatsPerBar
        }
        .filter { Double($0) >= notBefore - 1e-9 }
        .min()
    }
}

nonisolated extension MixDocument {
    /// How far ahead of the playhead a beatmix at a cue may start: a bar,
    /// as at the playhead - near enough to be the cue that was meant, far
    /// enough to be heard coming while the mix plays.
    static let cueLeadBeats = Clip.beatsPerBar

    /// Puts a track into the mix at a cue point of the record it is mixed
    /// out of - the one playing at `playhead`, or the one the mix ends on
    /// while nothing plays - and returns the new clip's id.
    ///
    /// Everything past the start is the beatmix at the playhead: the
    /// outgoing record is cut where the beatmix ends, the rest of the mix
    /// moves with it, and the new record fades out into whatever followed.
    /// Only the beat it starts on is different - the cue's bar line instead
    /// of the next four-bar line.
    @discardableResult
    mutating func insertClip(trackID: UUID, grid: SourceGrid, beatmix: BeatmixLength, atCueAfter playhead: Double,
                             cues: CueLookup, grids: GridLookup, draft: ClipDraft = .record) throws -> UUID {
        guard beatmix != .noTransition else {
            throw EditError("A track goes in at a cue point with a beatmix only.")
        }
        if clips.isEmpty { return try addClip(trackID: trackID, grid: grid, grids: grids, draft: draft) }
        func lookup(_ id: UUID) -> SourceGrid? { id == trackID ? grid : grids(id) }
        guard let out = outgoing(atBeat: playhead, grids: lookup) else {
            throw EditError("There is no record to mix out of.")
        }
        let record = clips[out.index]
        guard let outGrid = lookup(record.trackID) else {
            throw EditError("The record that would be mixed out of has no beatgrid.")
        }
        let marks = cues(record.trackID)
        guard !marks.isEmpty else {
            throw EditError("That record has no cue points. Set one in its beatgrid editor first.")
        }
        // Never before the record itself has begun, whatever the playhead
        // says: a cue in the part that is already behind us is not an
        // insert point, it is a spot that has passed.
        let notBefore = max(playhead, out.shape.start) + Double(Self.cueLeadBeats)
        guard let start = CueRules.insertStart(cues: marks, grid: outGrid, anchorBeat: record.anchorBeat,
                                               notBefore: notBefore) else {
            throw EditError("Every cue point of that record lies behind the playhead.")
        }
        return try insert(trackID: trackID, grid: grid, beatmix: beatmix, startingAt: start,
                          outgoing: out, draft: draft, lookup: lookup)
    }
}
