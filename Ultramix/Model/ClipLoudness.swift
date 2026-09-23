//
//  ClipLoudness.swift
//  Ultramix
//
//  How loud a clip plays, and the gain that makes it as loud as the clip it
//  follows: the clip bar's LUFS readout and its Match button.
//
//  Only the clip itself counts - the part of its song it plays, trims
//  included, and its gain. Lane volume, pan and filter are left out: they are
//  drawn per transition, while the gain evens out one song's level against
//  another's before any of that. Tempo is left out too - stretching changes
//  when a sound plays, not how loud it is.
//

import Foundation

nonisolated enum ClipLoudness {
    /// Integrated loudness of the part of the song the clip plays, before
    /// any gain. Nil while that part is shorter than one 400 ms block, or
    /// silent. A looping clip repeats its body, and a repeat is as loud as
    /// the body.
    static func rawLUFS(_ clip: Clip, grid: SourceGrid, profile: LoudnessProfile) -> Double? {
        let shape = ClipGeometry(clip: clip, grid: grid)
        let secondsPerBeat = 60 / max(grid.bpm, 1)
        return profile.integrated(fromSeconds: (shape.bodyStart - shape.fileStart) * secondsPerBeat,
                                  toSeconds: (shape.bodyEnd - shape.fileStart) * secondsPerBeat)
    }

    /// Loudness of the clip as it plays: with the gain it actually gets (see
    /// `effectiveGainDB`).
    static func lufs(_ clip: Clip, grid: SourceGrid, profile: LoudnessProfile, target: Double? = nil) -> Double? {
        guard let raw = rawLUFS(clip, grid: grid, profile: profile) else { return nil }
        return raw + gain(raw: raw, gainDB: clip.gainDB, target: target)
    }

    /// The same, looked up: nil while the track's grid or profile is missing.
    static func lufs(_ clip: Clip, _ grids: GridLookup, _ loudness: (UUID) -> LoudnessProfile?,
                     target: Double? = nil) -> Double? {
        guard let grid = grids(clip.trackID), let profile = loudness(clip.trackID) else { return nil }
        return lufs(clip, grid: grid, profile: profile, target: target)
    }

    /// The gain a clip plays with. Without a target, its own gain. With one,
    /// whatever brings the part it plays to the target, with its own gain as
    /// an offset from it - to 0.1 dB, and within the gain range. A clip whose
    /// song is not measured yet keeps its own gain until it is.
    static func effectiveGainDB(_ clip: Clip, grid: SourceGrid, profile: LoudnessProfile?, target: Double?) -> Double {
        gain(raw: profile.flatMap { rawLUFS(clip, grid: grid, profile: $0) }, gainDB: clip.gainDB, target: target)
    }

    private static func gain(raw: Double?, gainDB: Double, target: Double?) -> Double {
        guard let target, let raw else { return gainDB }
        let wanted = min(max(target - raw + gainDB, Clip.gainRange.lowerBound), Clip.gainRange.upperBound)
        return (wanted * 10).rounded() / 10
    }
}

nonisolated extension MixDocument {
    /// The clip that `id` is matched against: the one it mixes out of - on
    /// another lane, playing where this clip starts, the latest to start if
    /// several are. Failing that, the clip that ended last before it starts,
    /// on any lane. A muted clip is not heard, so it is never the reference.
    func matchReference(for id: UUID, grids: GridLookup) -> Clip? {
        guard let clip = clips.first(where: { $0.id == id }), let own = geometry(clip, grids) else { return nil }
        let others = clips.filter { $0.id != id && !$0.muted }
            .compactMap { other in geometry(other, grids).map { (clip: other, shape: $0) } }
        let into = others.filter { $0.clip.lane != clip.lane && $0.shape.start <= own.start && $0.shape.end > own.start }
        if let latest = into.max(by: { $0.shape.start < $1.shape.start }) { return latest.clip }
        // The tolerance lets a clip standing end to end count as before.
        return others.filter { $0.shape.end <= own.start + 0.05 }.max(by: { $0.shape.end < $1.shape.end })?.clip
    }

    /// Sets the clip's gain so it plays as loud as its reference (see
    /// `matchReference`) - to the whole dB and within the gain range, as
    /// `setGain` holds every gain. Nothing changes when there is no
    /// reference, or when either loudness is not known yet.
    mutating func matchGain(_ id: UUID, grids: GridLookup, loudness: (UUID) -> LoudnessProfile?) {
        guard let reference = matchReference(for: id, grids: grids),
              let target = ClipLoudness.lufs(reference, grids, loudness),
              let clip = clips.first(where: { $0.id == id }),
              let own = ClipLoudness.lufs(clip, grids, loudness) else { return }
        setGain(id, target - (own - clip.gainDB))
    }
}
