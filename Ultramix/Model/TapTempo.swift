//
//  TapTempo.swift
//  Ultramix
//
//  Tempo from the user tapping along. On every beat, which is what anybody
//  does untold - quick, and enough to settle which octave a track is in. Or on
//  bar ones, four beats apart, which leaves time to listen, makes a tap 20 ms
//  out a 1 % error rather than 4 %, and also says where bar one is.
//
//  Either way the taps are fitted by least squares rather than averaging the
//  intervals, which would weight the first and last tap alone. A tap in the
//  wrong place - a missed beat, a double tap - is recognised by its interval
//  and dropped rather than allowed to drag the line.
//

import Foundation

nonisolated enum TapTempo {
    struct Result: Equatable, Sendable {
        var bpm: Double
        /// Time of the first kept tap: a bar one for bar taps, merely a beat
        /// for beat taps.
        var firstDownbeat: Double
        /// Scatter of the kept taps around the fitted grid, in seconds.
        var rmsError: Double
        var tapsUsed: Int
        /// Standard error of the tempo, in BPM.
        var bpmSpread: Double
    }

    static let minimumTaps = 4
    static let maximumTaps = 16
    /// A pause this long after a beat tap starts a new series.
    static let beatSeriesTimeout = 2.0

    /// - Parameter taps: times of taps on successive bar ones, in seconds,
    ///   oldest first.
    static func fit(barTaps taps: [Double]) -> Result? {
        fit(taps: taps, beatsPerTap: 4)
    }

    /// - Parameter taps: times of taps on successive beats, in seconds,
    ///   oldest first.
    static func fit(beatTaps taps: [Double]) -> Result? {
        fit(taps: taps, beatsPerTap: 1)
    }

    static func fit(taps: [Double], beatsPerTap: Int) -> Result? {
        let recent = Array(taps.suffix(maximumTaps))
        guard recent.count >= minimumTaps else { return nil }
        let intervals = zip(recent.dropFirst(), recent).map { $0 - $1 }.sorted()
        let median = intervals[intervals.count / 2]
        // 30…400 BPM worth of taps.
        let beats = Double(beatsPerTap)
        guard median > 60 / 400 * beats, median < 60 / 30 * beats else { return nil }

        // Number each tap by the one it is nearest to, counted in medians
        // from the first; keep those that sit within 0.6–1.6 intervals of
        // the previous kept tap.
        var kept: [(index: Double, time: Double)] = [(0, recent[0])]
        for time in recent.dropFirst() {
            let gap = time - kept.last!.time
            guard gap >= 0.6 * median, gap <= 1.6 * median else { continue }
            kept.append((kept.last!.index + 1, time))
        }
        guard kept.count >= minimumTaps else { return nil }

        let n = Double(kept.count)
        let meanIndex = kept.map(\.index).reduce(0, +) / n
        let meanTime = kept.map(\.time).reduce(0, +) / n
        var covariance = 0.0, variance = 0.0
        for tap in kept {
            covariance += (tap.index - meanIndex) * (tap.time - meanTime)
            variance += (tap.index - meanIndex) * (tap.index - meanIndex)
        }
        guard variance > 0 else { return nil }
        let period = covariance / variance
        let origin = meanTime - period * meanIndex
        let squared = kept.map { pow($0.time - (origin + period * $0.index), 2) }.reduce(0, +)
        let bpm = 60 * beats / period
        // Standard error of the slope, carried through bpm = k / period.
        let periodError = (squared / max(n - 2, 1) / variance).squareRoot()
        return Result(bpm: bpm, firstDownbeat: origin, rmsError: (squared / n).squareRoot(),
                      tapsUsed: kept.count, bpmSpread: bpm * periodError / period)
    }
}
