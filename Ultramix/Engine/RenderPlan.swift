//
//  RenderPlan.swift
//  Ultramix
//
//  Everything the audio thread needs to render a mix, frozen: the tempo map,
//  the clips unrolled into segments with frame ranges, the lane curves ready
//  to evaluate. Every edit builds a fresh plan and hands it over with one
//  atomic pointer swap, so the audio thread never sees a half-edited document,
//  waits for one, or allocates because of one. Nothing in a plan changes after
//  it is built except the stretch memos, which only the rendering thread
//  touches.
//
//  Rebuilding is microseconds for dozens of clips, and swapping loses nothing:
//  the stretcher's output is a function of the plan alone.
//

import Foundation

/// One parameter across a whole lane, pieced together from its clips: inside
/// a clip the clip's own curve, outside every clip the kind's resting value.
///
/// Clips on a lane never overlap (`MixDocument.fits`), so the regions are
/// disjoint and one binary search finds the one that holds a beat. Muted
/// clips are regions too - they are silent anyway, and a curve that changed
/// when a mute was toggled would redraw under the user's hand for nothing.
/// The renderer reads this exactly as it read a lane's curve before, so its
/// control grid - and the bounce's block-size independence - is unchanged.
nonisolated struct LaneCurve: Sendable {
    struct Region: Sendable {
        /// The clip's visible span, in timeline beats.
        let start: Double
        let end: Double
        /// Timeline beat of the clip's local beat 0.
        let anchor: Double
        let curve: AutomationCurve
    }

    let kind: AutomationKind
    let regions: [Region]

    init(kind: AutomationKind, regions: [Region]) {
        self.kind = kind
        self.regions = regions.sorted { $0.start < $1.start }
    }

    /// The region holding `beat`, if any.
    func region(at beat: Double) -> Region? {
        var low = 0
        var high = regions.count
        while low < high {
            let mid = (low + high) / 2
            if regions[mid].start <= beat { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = regions[low - 1]
        return beat < candidate.end ? candidate : nil
    }

    func value(at beat: Double) -> Double {
        guard let region = region(at: beat) else { return kind.restValue }
        return region.curve.value(at: beat - region.anchor)
    }
}

/// A lane's curves, ready to be read at any beat.
nonisolated struct LanePlan: Sendable {
    let volume: LaneCurve
    let pan: LaneCurve
    let lowPass: LaneCurve
    let highPass: LaneCurve

    /// - Parameter automation: what a clip plays. Its own, except where the
    ///   timeline shows a gesture that is still being dragged out.
    init(document: MixDocument, lane: Int, grids: GridLookup,
         automation: (Clip) -> ClipAutomation = { $0.automation }) {
        var regions: [AutomationKind: [LaneCurve.Region]] = [:]
        for clip in document.clips where clip.lane == lane {
            guard let grid = grids(clip.trackID) else { continue }
            let shape = ClipGeometry(clip: clip, grid: grid)
            let drawn = automation(clip)
            for kind in AutomationKind.allCases {
                regions[kind, default: []].append(LaneCurve.Region(
                    start: shape.start, end: shape.end, anchor: Double(clip.anchorBeat),
                    curve: AutomationCurve(kind: kind, automation: drawn)))
            }
        }
        volume = LaneCurve(kind: .volume, regions: regions[.volume] ?? [])
        pan = LaneCurve(kind: .pan, regions: regions[.pan] ?? [])
        lowPass = LaneCurve(kind: .lowPass, regions: regions[.lowPass] ?? [])
        highPass = LaneCurve(kind: .highPass, regions: regions[.highPass] ?? [])
    }

    func curve(_ kind: AutomationKind) -> LaneCurve {
        switch kind {
        case .volume: volume
        case .pan: pan
        case .lowPass: lowPass
        case .highPass: highPass
        }
    }
}

nonisolated final class RenderPlan: @unchecked Sendable {
    /// The stretcher's safe range, as playback tempo over source tempo.
    static let ratioRange: ClosedRange<Double> = 0.5...2.0

    let generation: Int
    let tempo: TempoMap
    /// In document order - the renderer sums in this order, and float
    /// addition is not associative.
    let segments: [RenderSegment]
    let lanes: [LanePlan]
    /// Last frame of the mix, muted clips included.
    let endFrame: Int
    /// Clips whose tempo leaves the stretcher's range somewhere.
    let outOfRange: Set<UUID>
    /// One per segment. Mutated by the thread that renders this plan only.
    let memos: UnsafeMutablePointer<StretchMemo>

    /// - Parameter gainDB: the gain each clip plays with - its own, unless a
    ///   loudness target decides it (see ClipLoudness.effectiveGainDB).
    /// - Parameter shiftedAudio: a track's audio at a pitch shift, for clips
    ///   with a key shift or fine tune. While a shift is still being rendered
    ///   the clip plays unshifted rather than not at all; the plan is rebuilt
    ///   when the shift arrives, and a bounce waits for every shift first.
    init(document: MixDocument, grids: GridLookup, audio: (UUID) -> AudioFrames?, generation: Int,
         gainDB: (Clip) -> Double = { $0.gainDB },
         shiftedAudio: (UUID, PitchShift) -> AudioFrames? = { _, _ in nil }) {
        self.generation = generation
        let tempo = document.tempoMap(grids)
        self.tempo = tempo
        let rate = AudioFrames.sampleRate
        func frame(_ beat: Double) -> Int { Int((tempo.seconds(atBeat: beat) * rate).rounded(.up)) }

        var segments: [RenderSegment] = []
        var outOfRange = Set<UUID>()
        for clip in document.clips where !clip.muted {
            guard let grid = grids(clip.trackID), let original = audio(clip.trackID) else { continue }
            let frames = clip.pitch.isNone ? original : shiftedAudio(clip.trackID, clip.pitch) ?? original
            let geometry = ClipGeometry(clip: clip, grid: grid)
            let extremes = tempo.bpmExtremes(in: max(0, geometry.start)...max(0, geometry.end))
            if !Self.ratioRange.contains(extremes.min / grid.bpm) || !Self.ratioRange.contains(extremes.max / grid.bpm) {
                outOfRange.insert(clip.id)
            }
            let gain = Float(Automation.gain(dB: gainDB(clip)))
            for piece in geometry.segments() {
                let start = max(0, frame(piece.start))
                let end = frame(piece.end)
                guard end > start else { continue }
                // The source's downbeat sits `preRollBeats` after its first
                // sample; for a loop copy, shifted by however many bodies.
                let downbeat = piece.fileStart + grid.preRollBeats
                let phase = downbeat - downbeat.rounded(.down)
                segments.append(RenderSegment(clipID: clip.id, lane: clip.lane, audio: frames,
                                              startFrame: start, endFrame: end,
                                              fileStartBeat: piece.fileStart, sourceBPM: grid.bpm,
                                              gridPhase: phase,
                                              gain: gain))
            }
        }
        self.segments = segments
        self.outOfRange = outOfRange
        lanes = (0..<Clip.laneCount).map { LanePlan(document: document, lane: $0, grids: grids) }
        endFrame = frame(document.endBeat(grids))
        memos = .allocate(capacity: max(1, segments.count))
        memos.initialize(repeating: StretchMemo(), count: max(1, segments.count))
    }

    deinit {
        memos.deinitialize(count: max(1, segments.count))
        memos.deallocate()
    }
}
