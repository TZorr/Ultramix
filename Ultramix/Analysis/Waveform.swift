//
//  Waveform.swift
//  Ultramix
//
//  The overview a clip draws: a track summarised once into 16 384 buckets of
//  per-channel min, max and RMS, then a pyramid halving down to 128. The view
//  picks the coarsest level with a bucket per pixel for the clip's *whole*
//  width - choosing from the visible slice makes the waveform step visibly
//  while scrolling. Normalised by the track's largest peak, RMS included.
//

import Foundation
import Accelerate

nonisolated struct WaveformLevel: Sendable, Equatable {
    var minL: [Float], maxL: [Float], rmsL: [Float]
    var minR: [Float], maxR: [Float], rmsR: [Float]

    var count: Int { maxL.count }

    /// Half the resolution: extremes of extremes, and the quadratic mean of
    /// the two RMS values (the RMS of the combined bucket, since both halves
    /// hold the same number of frames).
    func halved() -> WaveformLevel {
        let n = count / 2
        func pairs(_ values: [Float], _ combine: (Float, Float) -> Float) -> [Float] {
            (0..<n).map { combine(values[2 * $0], values[2 * $0 + 1]) }
        }
        let rms: (Float, Float) -> Float = { (($0 * $0 + $1 * $1) / 2).squareRoot() }
        return WaveformLevel(minL: pairs(minL, min), maxL: pairs(maxL, max), rmsL: pairs(rmsL, rms),
                             minR: pairs(minR, min), maxR: pairs(maxR, max), rmsR: pairs(rmsR, rms))
    }
}

nonisolated struct Waveform: Sendable {
    static let bucketCount = 16_384
    static let coarsestCount = 128

    /// Finest first.
    let levels: [WaveformLevel]
    /// How many source frames one finest bucket covers.
    let framesPerBucket: Int

    init(finest: WaveformLevel, framesPerBucket: Int) {
        var levels = [finest]
        while levels.last!.count > Self.coarsestCount {
            levels.append(levels.last!.halved())
        }
        self.levels = levels
        self.framesPerBucket = framesPerBucket
    }

    /// The coarsest level with at least `columns` buckets across the whole
    /// track - one bucket per pixel or better.
    func level(forColumns columns: Int) -> WaveformLevel {
        levels.last { $0.count >= columns } ?? levels[0]
    }

    // MARK: - Building

    init(audio: AudioFrames) {
        let frames = audio.frameCount
        let perBucket = max(1, Int((Double(frames) / Double(Self.bucketCount)).rounded(.up)))
        let buckets = max(1, Int((Double(frames) / Double(perBucket)).rounded(.up)))
        var level = WaveformLevel(minL: [], maxL: [], rmsL: [], minR: [], maxR: [], rmsR: [])
        for array in [\WaveformLevel.minL, \.maxL, \.rmsL, \.minR, \.maxR, \.rmsR] {
            level[keyPath: array] = [Float](repeating: 0, count: buckets)
        }
        var peak: Float = 0
        for bucket in 0..<buckets {
            let first = bucket * perBucket
            let count = min(perBucket, frames - first)
            guard count > 0 else { break }
            for channel in 0..<2 {
                let base = audio.samples + first * 2 + channel
                var low: Float = 0, high: Float = 0, meanSquare: Float = 0
                vDSP_minv(base, 2, &low, vDSP_Length(count))
                vDSP_maxv(base, 2, &high, vDSP_Length(count))
                vDSP_measqv(base, 2, &meanSquare, vDSP_Length(count))
                if channel == 0 {
                    level.minL[bucket] = low; level.maxL[bucket] = high; level.rmsL[bucket] = meanSquare.squareRoot()
                } else {
                    level.minR[bucket] = low; level.maxR[bucket] = high; level.rmsR[bucket] = meanSquare.squareRoot()
                }
                peak = max(peak, abs(low), abs(high))
            }
        }
        if peak > 0 {
            let scale = 1 / peak
            for array in [\WaveformLevel.minL, \.maxL, \.rmsL, \.minR, \.maxR, \.rmsR] {
                level[keyPath: array] = level[keyPath: array].map { $0 * scale }
            }
        }
        self.init(finest: level, framesPerBucket: perBucket)
    }

    // MARK: - Stems

    /// The four stems' waveforms, in the order of `Stem.allCases`, drawn to
    /// the song's scale - its largest peak - so a quiet stem looks quiet
    /// beside the song rather than blown up to full height. Drums, bass and
    /// vocals from their decoded audio, back at their true level; "other"
    /// worked out as the song less the three, a bucket at a time, so no
    /// whole copy of it is ever made.
    static func stems(song: AudioFrames, _ stems: StemAudio) -> [Waveform] {
        let frames = song.frameCount
        var peak: Float = 0
        vDSP_maxmgv(song.samples, 1, &peak, vDSP_Length(2 * frames))
        let scale = peak > 0 ? 1 / peak : 1
        let unstored = 1 / Stem.storedScale
        return Stem.allCases.map { stem in
            level(frames: frames, scale: scale) { first, count, into in
                let n = vDSP_Length(2 * count), at = 2 * first
                var factor = unstored
                switch stem {
                case .drums: vDSP_vsmul(stems.drums.samples + at, 1, &factor, into, 1, n)
                case .bass: vDSP_vsmul(stems.bass.samples + at, 1, &factor, into, 1, n)
                case .vocals: vDSP_vsmul(stems.vocals.samples + at, 1, &factor, into, 1, n)
                case .other:
                    vDSP_vadd(stems.drums.samples + at, 1, stems.bass.samples + at, 1, into, 1, n)
                    vDSP_vadd(into, 1, stems.vocals.samples + at, 1, into, 1, n)
                    var minus = -unstored
                    vDSP_vsma(into, 1, &minus, song.samples + at, 1, into, 1, n)
                }
            }
        }
    }

    /// A waveform of `frames` frames whose interleaved samples `fill` writes
    /// a bucket at a time, scaled by `scale`.
    private static func level(frames: Int, scale: Float,
                              fill: (_ first: Int, _ count: Int, _ into: UnsafeMutablePointer<Float>) -> Void) -> Waveform {
        let perBucket = max(1, Int((Double(frames) / Double(bucketCount)).rounded(.up)))
        let buckets = max(1, Int((Double(frames) / Double(perBucket)).rounded(.up)))
        var level = WaveformLevel(minL: [], maxL: [], rmsL: [], minR: [], maxR: [], rmsR: [])
        for array in [\WaveformLevel.minL, \.maxL, \.rmsL, \.minR, \.maxR, \.rmsR] {
            level[keyPath: array] = [Float](repeating: 0, count: buckets)
        }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 2 * perBucket)
        defer { scratch.deallocate() }
        for bucket in 0..<buckets {
            let first = bucket * perBucket
            let count = min(perBucket, frames - first)
            guard count > 0 else { break }
            fill(first, count, scratch)
            for channel in 0..<2 {
                var low: Float = 0, high: Float = 0, meanSquare: Float = 0
                vDSP_minv(scratch + channel, 2, &low, vDSP_Length(count))
                vDSP_maxv(scratch + channel, 2, &high, vDSP_Length(count))
                vDSP_measqv(scratch + channel, 2, &meanSquare, vDSP_Length(count))
                let rms = meanSquare.squareRoot()
                if channel == 0 {
                    level.minL[bucket] = low * scale; level.maxL[bucket] = high * scale; level.rmsL[bucket] = rms * scale
                } else {
                    level.minR[bucket] = low * scale; level.maxR[bucket] = high * scale; level.rmsR[bucket] = rms * scale
                }
            }
        }
        return Waveform(finest: level, framesPerBucket: perBucket)
    }

    // MARK: - Storage
    //
    // Raw little-endian floats: a header of two Int32s (bucket count, frames
    // per bucket), then the six arrays of the finest level. The pyramid is
    // rebuilt on load, which takes less time than reading it would.

    func data() -> Data {
        var data = Data()
        let finest = levels[0]
        var header = [Int32(finest.count), Int32(framesPerBucket)]
        data.append(Data(bytes: &header, count: 8))
        for array in [finest.minL, finest.maxL, finest.rmsL, finest.minR, finest.maxR, finest.rmsR] {
            array.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    init?(data: Data) {
        guard data.count >= 8 else { return nil }
        let header = data.prefix(8).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        let count = Int(header[0])
        guard count > 0, data.count == 8 + count * 6 * 4 else { return nil }
        let floats = data.dropFirst(8).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        func slice(_ index: Int) -> [Float] { Array(floats[(index * count)..<((index + 1) * count)]) }
        self.init(finest: WaveformLevel(minL: slice(0), maxL: slice(1), rmsL: slice(2),
                                        minR: slice(3), maxR: slice(4), rmsR: slice(5)),
                  framesPerBucket: Int(header[1]))
    }
}
