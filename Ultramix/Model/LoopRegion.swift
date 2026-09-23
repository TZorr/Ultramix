//
//  LoopRegion.swift
//  Ultramix
//
//  A stretch of a song marked in the beatgrid editor, and the clip it becomes.
//  The region is two times in the song's file; what goes into the mix is an
//  ordinary clip, trimmed to the region and looping, so
//  `ClipGeometry.segments()` unrolls it and the renderer never learns what a
//  loop is.
//
//  The region is rounded to whole beats of the track's grid first. A loop is a
//  musical length, and one 3.98 beats long slides further off the beat with
//  every repeat. Rounding also makes the arithmetic exact, so the clip's
//  anchor can put the loop's first sample precisely on the bar line the
//  beatmix asks for.
//
//  `ClipDraft` tells the beatmix which of the two it is placing: a record,
//  whose bar one lands on the beatmix, or a loop, whose first sample does.
//

import Foundation

nonisolated struct LoopRegion: Sendable, Equatable {
    var startSeconds: Double
    var endSeconds: Double

    var lengthSeconds: Double { endSeconds - startSeconds }

    /// Takes the two ends in either order, which is what a drag gives.
    init(from: Double, to: Double) {
        startSeconds = max(0, min(from, to))
        endSeconds = max(0, max(from, to))
    }

    func clamped(to duration: Double) -> LoopRegion {
        LoopRegion(from: min(startSeconds, duration), to: min(endSeconds, duration))
    }

    /// The region on the nearest gridlines - what the editor shows while it
    /// is being drawn, so the mouse and the clip agree about where it is.
    func snapped(to grid: SourceGrid) -> LoopRegion {
        let beat = 60 / max(grid.bpm, 1)
        func line(_ seconds: Double) -> Double {
            grid.firstBeatSeconds + ((seconds - grid.firstBeatSeconds) / beat).rounded() * beat
        }
        return LoopRegion(from: line(startSeconds), to: line(endSeconds))
    }

    /// Its length in beats of the track's own tempo, rounded as a clip would
    /// round it; 0 where the region is empty.
    func beats(in grid: SourceGrid) -> Int {
        let beat = 60 / max(grid.bpm, 1)
        return max(0, Int((lengthSeconds / beat).rounded()))
    }
}

/// What a beatmix places: a whole record, or a loop cut out of one.
///
/// A whole record is placed by its bar one - the beatmix starts where the
/// downbeat lands, and the intro before it hangs to the left. A loop has no
/// downbeat of its own to place; what has to land on the beatmix is its
/// first sample. `leadBeats` is the difference: how far the sound begins
/// after the clip's bar one, which is zero for a record and the region's
/// distance from bar one for a loop (negative for a loop out of the intro).
nonisolated struct ClipDraft: Sendable, Equatable {
    var trimStart = 0.0
    var trimEnd = 0.0
    var looping = false
    var loopTail = 0.0
    var leadBeats = 0

    static let record = ClipDraft()
    var isRecord: Bool { self == .record }

    /// Beats from the clip's anchor to its first sound. For a record that is
    /// the intro, hanging to the left of bar one; for a loop it is
    /// `leadBeats` again, as a Double.
    func startOffset(_ grid: SourceGrid) -> Double { trimStart - grid.preRollBeats }

    func applied(to clip: Clip) -> Clip {
        var result = clip
        result.trimStart = trimStart
        result.trimEnd = trimEnd
        result.looping = looping
        result.loopTail = loopTail
        return result
    }

    /// The loop `region` of a track with `grid`, played `repeats` times.
    ///
    /// - Returns: nil when the rounded region is shorter than a clip may be,
    ///   or does not lie inside the file - there is nothing to loop then,
    ///   and the caller says so in its own words.
    static func loop(region: LoopRegion, grid: SourceGrid, repeats: Int) -> ClipDraft? {
        let beat = 60 / max(grid.bpm, 1)
        let first = ((region.startSeconds - grid.firstBeatSeconds) / beat).rounded()
        let last = ((region.endSeconds - grid.firstBeatSeconds) / beat).rounded()
        let body = last - first
        guard body >= Clip.minimumBeats else { return nil }
        let trimStart = grid.preRollBeats + first
        let trimEnd = grid.lengthBeats - grid.preRollBeats - last
        guard trimStart >= -1e-9, trimEnd >= -1e-9 else { return nil }
        return ClipDraft(trimStart: max(0, trimStart), trimEnd: max(0, trimEnd), looping: true,
                         loopTail: Double(max(1, repeats) - 1) * body, leadBeats: Int(first))
    }

    /// How many times a loop may repeat. One is the region itself; the
    /// ceiling is four minutes of a two-beat loop, far past what anybody
    /// draws by hand.
    static let repeatRange = 1...128
}
