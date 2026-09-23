//
//  GridFit.swift
//  Ultramix
//
//  How well a rigid grid holds over a whole track, window by window, judged by
//  the kicks the analyser hears (`TempoAnalyzer.kicks`). A grid can fit the
//  first minutes and then stop - two takes cut together, a drummer speeding
//  up, a tempo stepping from 119.8 to 120. One tempo per track cannot fix
//  that, but it can say where it happens.
//
//  Each window is eight bars. Its kicks are read as offsets from the nearest
//  line; where most fall together, that cluster is the kick and its centre
//  says how far it sits from the lines. Where they do not - a breakdown, a
//  fill - nothing is claimed.
//
//  The centre is the densest point of the offsets, not their mean: a
//  syncopated bass a quarter beat after the kick pulls the mean away from a
//  grid that is right, and "Align to Kicks" would then move it off.
//
//  Two findings: the track's *baseline*, where the kick sits on average over
//  all steady windows (within ±4 ms on 90 % of a 783-track set), and a
//  *drift*, a stretch where the kick has moved away from that baseline and
//  stays away. Thresholds are set to what is audible and long enough to
//  matter; there is no reference to tune against beyond that.
//

import Foundation

nonisolated enum GridFit {
    struct Window: Equatable {
        var start: Double
        var end: Double
        var kicks: Int
        /// Enough kicks to judge.
        var heard: Bool
        /// 0…1: the share of the kicks in the cluster around `offset`.
        var steadiness: Double
        /// Where the kicks sit, in seconds from the nearest line (+ = late).
        var offset: Double

        var isSteady: Bool { heard && steadiness >= GridFit.steadyAbove }
    }

    struct Drift: Equatable {
        /// Start of the first window of the run.
        var from: Double
        /// The offsets, from the lines, at the start and end of the run. The
        /// last is unwrapped along the run: a kick that drifts past half a
        /// beat is still said to be late (or early), not suddenly the other.
        var firstOffset: Double
        var lastOffset: Double
        /// Where the grid fits again: for an intro, the first fitting
        /// window; nil for a drift, which is reported where it starts.
        var to: Double? = nil
    }

    struct Summary: Equatable {
        var windows: [Window]
        /// Median offset of the steady windows; nil with fewer than
        /// `minimumSteadyWindows` of them.
        var baseline: Double?
        var drift: Drift?
        /// A run of misfit windows at the start, before the grid fits
        /// anywhere - an intro played differently, or in another tempo.
        var intro: Drift?
        /// How far to move bar one onto the kicks - the baseline, offered
        /// only when it is noticeable and moving the grid by it puts clearly
        /// more kicks on the lines than there are now.
        var alignment: Double?
    }

    static let barsPerWindow = 8
    /// Fewer kicks than this share of a window's beats: not judged.
    static let minimumKickShare = 0.375
    /// At least this share of a window's kicks in one cluster: steady.
    static let steadyAbove = 0.5
    /// How far from the cluster's centre a kick still belongs to it.
    static let clusterRadius = 0.015
    /// A steady window this far from the baseline has drifted.
    static let driftBeyond = 0.025
    /// This many drifted windows in a row, after one that was not, make a
    /// drift: 24 bars, about 45 s at 128 BPM.
    static let driftWindows = 3
    static let minimumSteadyWindows = 3
    /// A baseline further out than this is worth offering to fix.
    static let noticeableBaseline = 0.010
    /// Moving the grid must put at least this many times as many kicks
    /// within `clusterRadius` of the lines.
    static let alignmentGain = 1.2

    static func summary(kicks: [Double], bpm: Double, firstBeat: Double, duration: Double) -> Summary {
        let windows = windows(kicks: kicks, bpm: bpm, firstBeat: firstBeat, duration: duration)
        let steady = windows.filter(\.isSteady).map(\.offset).sorted()
        guard steady.count >= minimumSteadyWindows else { return Summary(windows: windows) }
        let baseline = steady.count % 2 == 1
            ? steady[steady.count / 2]
            : (steady[steady.count / 2 - 1] + steady[steady.count / 2]) / 2
        var summary = Summary(windows: windows, baseline: baseline,
                              drift: drift(windows, baseline: baseline, beat: 60 / bpm),
                              intro: intro(windows, baseline: baseline, beat: 60 / bpm))
        if abs(baseline) > noticeableBaseline {
            let beat = 60 / bpm
            func onLines(_ shift: Double) -> Int {
                kicks.filter { abs(offsetFromLine($0, firstBeat: firstBeat + shift, beat: beat)) <= clusterRadius }.count
            }
            if Double(onLines(baseline)) >= alignmentGain * Double(max(onLines(0), 1)) {
                summary.alignment = baseline
            }
        }
        return summary
    }

    static func windows(kicks: [Double], bpm: Double, firstBeat: Double, duration: Double) -> [Window] {
        guard bpm > 0, duration > 0 else { return [] }
        let beat = 60 / bpm
        let length = Double(barsPerWindow * 4) * beat
        // Windows on bar lines, from the last bar line before zero.
        var start = firstBeat - ((firstBeat / (4 * beat)).rounded(.down) + 1) * 4 * beat
        var result: [Window] = []
        var index = 0
        let sorted = kicks.sorted()
        while start < duration {
            let end = start + length
            var offsets: [Double] = []
            while index < sorted.count && sorted[index] < start { index += 1 }
            var i = index
            while i < sorted.count && sorted[i] < end {
                offsets.append(offsetFromLine(sorted[i], firstBeat: firstBeat, beat: beat))
                i += 1
            }
            let beats = (min(end, duration) - max(start, 0)) / beat
            let heard = beats >= 4 && !offsets.isEmpty && Double(offsets.count) >= minimumKickShare * beats
            let cluster = densestCluster(offsets, beat: beat)
            result.append(Window(start: max(start, 0), end: min(end, duration), kicks: offsets.count, heard: heard,
                                 steadiness: offsets.isEmpty ? 0 : Double(cluster.members) / Double(offsets.count),
                                 offset: cluster.centre))
            start = end
        }
        return result
    }

    /// Seconds from the nearest line, within half a beat either way.
    static func offsetFromLine(_ time: Double, firstBeat: Double, beat: Double) -> Double {
        (time - firstBeat) - ((time - firstBeat) / beat).rounded() * beat
    }

    /// The point, round the beat, where most offsets lie within
    /// `clusterRadius`; the mean of those offsets, and how many there are.
    static func densestCluster(_ offsets: [Double], beat: Double) -> (centre: Double, members: Int) {
        guard !offsets.isEmpty else { return (0, 0) }
        func wrapped(_ x: Double) -> Double {
            var y = x.truncatingRemainder(dividingBy: beat)
            if y > beat / 2 { y -= beat }
            if y < -beat / 2 { y += beat }
            return y
        }
        // Every offset is a candidate centre; a window holds a few dozen.
        var best = (centre: 0.0, members: 0, spread: Double.infinity)
        for candidate in offsets {
            let near = offsets.map { wrapped($0 - candidate) }.filter { abs($0) <= clusterRadius }
            let spread = near.reduce(0) { $0 + abs($1) }
            if near.count > best.members || (near.count == best.members && spread < best.spread) {
                best = (wrapped(candidate + near.reduce(0, +) / Double(near.count)), near.count, spread)
            }
        }
        return (best.centre, best.members)
    }

    /// The first run of `driftWindows` or more steady windows beyond
    /// `driftBeyond` from the baseline that follows a steady window within
    /// it. Windows that are not steady neither break nor extend a run.
    static func drift(_ windows: [Window], baseline: Double, beat: Double) -> Drift? {
        var seenFit = false
        var run: [Window] = []
        func finished() -> Drift? {
            guard seenFit, run.count >= driftWindows else { return nil }
            return summarise(run, beat: beat)
        }
        for window in windows where window.isSteady {
            if abs(window.offset - baseline) <= driftBeyond {
                if let drift = finished() { return drift }
                seenFit = true
                run = []
            } else {
                run.append(window)
            }
        }
        return finished()
    }

    /// The run of `driftWindows` or more steady windows beyond `driftBeyond`
    /// from the baseline - and from the lines themselves - before the first
    /// steady window within it. A run that never ends is not an intro: then
    /// the grid fits nowhere, or only its own drift, and the rest of the bar
    /// says so. Without the second condition, a track whose intro sat on the
    /// lines and whose body did not was told its intro was off by 1 ms.
    static func intro(_ windows: [Window], baseline: Double, beat: Double) -> Drift? {
        var run: [Window] = []
        for window in windows where window.isSteady {
            guard abs(window.offset - baseline) > driftBeyond else {
                guard run.count >= driftWindows else { return nil }
                var intro = summarise(run, beat: beat)
                intro.to = window.start
                return intro
            }
            guard abs(window.offset) > driftBeyond else { return nil }
            run.append(window)
        }
        return nil
    }

    /// A run's start and its offsets, the last unwrapped along the run.
    private static func summarise(_ run: [Window], beat: Double) -> Drift {
        let first = run[0]
        var offset = first.offset
        for window in run.dropFirst() {
            var step = (window.offset - offset).truncatingRemainder(dividingBy: beat)
            if step > beat / 2 { step -= beat }
            if step < -beat / 2 { step += beat }
            offset += step
        }
        return Drift(from: first.start, firstOffset: first.offset, lastOffset: offset)
    }
}
