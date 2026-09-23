//
//  TempoMap.swift
//  Ultramix
//
//  The one tempo map of a mix, and the only place beats become seconds.
//
//  Everything musical is kept in beats, because a position in seconds stops
//  meaning anything the moment the tempo changes. Every consumer - renderer,
//  playhead, ruler, bounce - goes through the same instance; two maps built in
//  two places are how a playhead drifts away from what is playing.
//
//  The map is target points, one per clip plus the project tempo at beat 0,
//  linearly interpolated. The tempo does not glide along that line: it is
//  sampled at the start of each whole beat and held. A change mid-beat is
//  exposed; at the boundary it hides under the transient. A continuous ramp
//  would also stretch two overlapping clips by two constantly moving ratios,
//  sliding their transients against each other - the one thing a beatmatched
//  transition must not do.
//
//  The cost is that elapsed time has no closed form, so it is accumulated once
//  into `beatStartSeconds` and read back by index or binary search.
//

import Foundation

/// A tempo the map must reach at a given beat.
nonisolated struct TempoPoint: Equatable, Sendable, Codable {
    var beat: Double
    var bpm: Double
    /// Where the ramp into this point begins; before it the previous point's
    /// tempo holds. Nil ramps all the way from the previous point.
    var rampStart: Double? = nil
}

nonisolated struct TempoMap: Sendable {

    /// Wide enough for any real track played at half or double speed; narrow
    /// enough that a corrupt value cannot build a table of millions of beats
    /// per minute.
    static let bpmRange: ClosedRange<Double> = 40...300

    /// Upper bound on the table: a four-hour mix at 300 BPM is 72 000 beats.
    /// Past this the last tempo is extrapolated, which is exact anyway -
    /// the map is constant after its last point.
    static let maxTableBeats = 100_000

    /// Sorted by beat, strictly increasing, first point at beat 0.
    let points: [TempoPoint]
    /// The clock time at which beat 0 plays. Zero for every mix; the live
    /// set moves it forward each time it lets go of what has played (see
    /// LiveSet), so the engine's frame counter can run on untouched while
    /// the beats start again from a small number.
    let originSeconds: Double

    /// `beatStartSeconds[n]` is the time at which whole beat `n` begins.
    /// Covers beats 0...tableBeats; beyond that the last tempo holds.
    private let beatStartSeconds: [Double]

    /// Builds the map from the project tempo and the clips' targets.
    ///
    /// When two targets land on the same beat, the later one in `targets`
    /// wins. Callers pass clips in insertion order, so the newest clip decides
    /// - the same answer a user gets by looking at what they placed last.
    init(projectBPM: Double, targets: [TempoPoint], originSeconds: Double = 0) {
        self.originSeconds = originSeconds
        var merged: [TempoPoint] = [TempoPoint(beat: 0, bpm: Self.clamp(projectBPM))]
        for target in targets where target.beat.isFinite && target.bpm.isFinite {
            let point = TempoPoint(beat: max(0, target.beat), bpm: Self.clamp(target.bpm), rampStart: target.rampStart)
            if let index = merged.firstIndex(where: { abs($0.beat - point.beat) < 1e-9 }) {
                merged[index] = point
            } else {
                merged.append(point)
            }
        }
        // Stable on purpose: equal beats were already merged above, so the
        // sort only ever reorders distinct beats.
        merged.sort { $0.beat < $1.beat }

        // A ramp start becomes a hold point: a point at the ramp start that
        // carries the previous point's tempo, so the line stays flat up to it
        // and only then climbs. The holds are found from the targets alone,
        // before any is added, so one ramp start never moves where another
        // ramp begins. A ramp start that is not strictly between its point
        // and the previous one says nothing and is ignored.
        var holds: [TempoPoint] = []
        for index in merged.indices.dropFirst() {
            guard let start = merged[index].rampStart else { continue }
            let previous = merged[index - 1]
            guard start > previous.beat + 1e-9, start < merged[index].beat - 1e-9 else { continue }
            holds.append(TempoPoint(beat: start, bpm: previous.bpm))
        }
        merged = (merged + holds).sorted { $0.beat < $1.beat }
        points = merged

        let lastBeat = merged.last!.beat
        let tableBeats = min(Int(lastBeat.rounded(.up)) + 1, Self.maxTableBeats)
        var table = [Double](repeating: 0, count: tableBeats + 1)
        for n in 0..<tableBeats {
            table[n + 1] = table[n] + 60 / Self.ramp(merged, at: Double(n))
        }
        beatStartSeconds = table
    }

    // MARK: - Queries

    /// The tempo that actually plays during the beat containing `beat`.
    func bpm(atBeat beat: Double) -> Double {
        Self.ramp(points, at: beat < 0 ? 0 : beat.rounded(.down))
    }

    /// Clock seconds at `beat`: from the start of the mix, plus the origin.
    /// Negative beats (a clip's pre-roll hanging before the start)
    /// extrapolate at the opening tempo.
    func seconds(atBeat beat: Double) -> Double {
        originSeconds + secondsFromOrigin(atBeat: beat)
    }

    private func secondsFromOrigin(atBeat beat: Double) -> Double {
        if beat <= 0 {
            return beat * 60 / points[0].bpm
        }
        let last = beatStartSeconds.count - 1
        let whole = min(Int(beat.rounded(.down)), last)
        let into = beat - Double(whole)
        return beatStartSeconds[whole] + into * 60 / Self.ramp(points, at: Double(whole))
    }

    /// The inverse of `seconds(atBeat:)`, exact to rounding.
    func beat(atSeconds clock: Double) -> Double {
        let seconds = clock - originSeconds
        if seconds <= 0 {
            return seconds * points[0].bpm / 60
        }
        // Largest n with beatStartSeconds[n] <= seconds.
        var low = 0
        var high = beatStartSeconds.count - 1
        if seconds >= beatStartSeconds[high] {
            low = high
        } else {
            while high - low > 1 {
                let mid = (low + high) / 2
                if beatStartSeconds[mid] <= seconds { low = mid } else { high = mid }
            }
        }
        let bpm = Self.ramp(points, at: Double(low))
        return Double(low) + (seconds - beatStartSeconds[low]) * bpm / 60
    }

    /// The slowest and fastest tempo that plays anywhere in `beats`, for
    /// checking that a clip's stretch stays inside what the stretcher allows.
    func bpmExtremes(in beats: ClosedRange<Double>) -> (min: Double, max: Double) {
        let first = max(0, beats.lowerBound.rounded(.down))
        let last = max(first, beats.upperBound.rounded(.down))
        var low = bpm(atBeat: first)
        var high = low
        // Only the beats at which a point sits can hold an extreme: between
        // two points the ramp is monotonic, so its ends bound it.
        for point in points where point.beat > first && point.beat <= last {
            let value = bpm(atBeat: point.beat)
            low = min(low, value)
            high = max(high, value)
        }
        let end = bpm(atBeat: last)
        return (min(low, end), max(high, end))
    }

    // MARK: - Private

    private static func clamp(_ bpm: Double) -> Double {
        min(max(bpm, bpmRange.lowerBound), bpmRange.upperBound)
    }

    /// The straight line through the points, held flat after the last one.
    private static func ramp(_ points: [TempoPoint], at beat: Double) -> Double {
        guard let nextIndex = points.firstIndex(where: { $0.beat > beat }) else {
            return points[points.count - 1].bpm
        }
        if nextIndex == 0 { return points[0].bpm }
        let a = points[nextIndex - 1]
        let b = points[nextIndex]
        let t = (beat - a.beat) / (b.beat - a.beat)
        return a.bpm + (b.bpm - a.bpm) * t
    }
}
