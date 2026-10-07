//
//  StemSeparator.swift
//  Ultramix
//
//  A whole song into drums, bass and vocals, the way Demucs's own
//  `separate` does it with `--shifts 0` (demucs/separate.py and
//  demucs/apply.py, 4.0.1):
//
//  - The song is normalised by the mean and standard deviation of its mono
//    mix, and the stems are scaled back at the end.
//  - It is cut into 7.8 s segments, one every three quarters of a segment.
//    The last one is shorter; it is taken with the song's own audio around
//    it, centred, and zeros past the end, and only its own part is kept.
//  - Each segment's stems are weighted by a triangle, highest in the middle,
//    summed where segments overlap and divided by the sum of the weights.
//    That also fades out the first and last few thousand samples of each
//    segment, which the network's spectrum does not get right
//    (DemucsSTFT).
//  - Demucs by default also shifts the song by a random amount up to half a
//    second, which makes two runs differ; that is left out, so a song always
//    separates the same way.
//
//  Streamed: with a quarter of overlap no sample is in more than two
//  segments, so once a segment is done, everything before the next one is
//  final and goes out through `output`. About 70 MB of buffers, whatever the
//  length of the song.
//

import Foundation
import Accelerate

nonisolated enum StemSeparator {
    /// The model and the way it is run, as it goes into file names
    /// (StemFiles) and the library: a change here separates again.
    static let tag = "ht1"
    static let segment = DemucsSTFT.segment
    static let stride = 257_985
    static let half = segment / 2

    nonisolated struct Chunk: Equatable {
        /// Where its result goes in the song, and how much of it.
        let offset: Int
        let length: Int
        /// Where its segment starts in the song: before `offset` for a short
        /// last chunk, so it sits in the middle of a full segment.
        var start: Int { offset - (StemSeparator.segment - length) / 2 }
        /// Where its result starts in the segment.
        var trim: Int { (StemSeparator.segment - length) / 2 }
    }

    static func chunks(frames: Int) -> [Chunk] {
        Swift.stride(from: 0, to: frames, by: stride).map { Chunk(offset: $0, length: min(segment, frames - $0)) }
    }

    /// The triangle a chunk's result is weighted by, at `i` from its start:
    /// 1/171990 at both ends, 1 in the middle.
    static func weight(_ i: Int) -> Float {
        Float(i < half ? i + 1 : segment - i) / Float(half)
    }

    /// Separates `mix` and hands the stems out in order, in blocks:
    /// `output(stem, left, right, frames)`, stems in the order of
    /// `Stem.stored`, at their true level, `mix.frameCount` frames in all.
    /// `progress` gets the fraction done after each segment. Throws
    /// CancellationError between segments when its task is cancelled.
    static func separate(_ mix: AudioFrames, model: DemucsModel,
                         progress: (Double) -> Void = { _ in },
                         output: (Int, UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) throws {
        let n = mix.frameCount, l = segment, x = mix.samples
        let stems = DemucsModel.stems, plane = DemucsSTFT.planeCount
        guard n > 0 else { return }

        // separate.py: the mono mix's mean and (unbiased) deviation.
        var sum = 0.0
        for i in 0..<n { sum += (Double(x[2 * i]) + Double(x[2 * i + 1])) / 2 }
        let mean = sum / Double(n)
        var squares = 0.0
        for i in 0..<n {
            let d = (Double(x[2 * i]) + Double(x[2 * i + 1])) / 2 - mean
            squares += d * d
        }
        let deviation = n > 1 ? (squares / Double(n - 1)).squareRoot() : 0
        // Digital silence separates into silence.
        let scale = deviation > 0 ? 1 / deviation : 0

        let stft = DemucsSTFT()
        let audio = UnsafeMutablePointer<Float>.allocate(capacity: DemucsModel.audioCount)
        let spec = UnsafeMutablePointer<Float>.allocate(capacity: DemucsModel.specCount)
        let time = UnsafeMutablePointer<Float>.allocate(capacity: DemucsModel.timeCount)
        let freq = UnsafeMutablePointer<Float>.allocate(capacity: DemucsModel.freqCount)
        let back = UnsafeMutablePointer<Float>.allocate(capacity: DemucsModel.audioCount)
        // The stems from the current chunk's offset on, weighted, and the
        // sum of the weights; then a block of them, finished.
        let sums = UnsafeMutablePointer<Float>.allocate(capacity: stems * 2 * l)
        let weights = UnsafeMutablePointer<Float>.allocate(capacity: l)
        let block = UnsafeMutablePointer<Float>.allocate(capacity: 2 * l)
        defer {
            for buffer in [audio, spec, time, freq, back, sums, weights, block] { buffer.deallocate() }
        }
        sums.initialize(repeating: 0, count: stems * 2 * l)
        weights.initialize(repeating: 0, count: l)

        let chunks = chunks(frames: n)
        for (k, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            for c in 0..<2 {
                for i in 0..<l {
                    let frame = chunk.start + i
                    audio[c * l + i] = frame >= 0 && frame < n ? Float((Double(x[2 * frame + c]) - mean) * scale) : 0
                }
            }
            stft.forward(audio, into: spec)
            let specNorm = DemucsModel.normalise(spec, count: DemucsModel.specCount)
            let audioNorm = DemucsModel.normalise(audio, count: DemucsModel.audioCount)
            try model.predict(audio: audio, spec: spec, time: time, freq: freq)

            for s in 0..<stems {
                var std = Float(specNorm.std), offset = Float(specNorm.mean)
                let stemFreq = freq + s * 4 * plane
                vDSP_vsmsa(stemFreq, 1, &std, &offset, stemFreq, 1, vDSP_Length(4 * plane))
                stft.inverse(stemFreq, into: back)
                for c in 0..<2 {
                    let t = time + (s * 2 + c) * l + chunk.trim, b = back + c * l + chunk.trim
                    let into = sums + (s * 2 + c) * l
                    for i in 0..<chunk.length {
                        let value = Double(t[i]) * audioNorm.std + audioNorm.mean + Double(b[i])
                        into[i] += weight(i) * Float(value)
                    }
                }
            }
            for i in 0..<chunk.length { weights[i] += weight(i) }

            // Everything before the next chunk is final.
            let done = k + 1 < chunks.count ? chunks[k + 1].offset - chunk.offset : chunk.length
            for s in 0..<stems {
                for c in 0..<2 {
                    let from = sums + (s * 2 + c) * l
                    for i in 0..<done { block[c * l + i] = Float(Double(from[i] / weights[i]) * deviation + mean) }
                }
                try output(s, block, block + l, done)
            }
            // What overlaps the next chunk moves to the front (the regions
            // overlap, so memmove).
            let kept = l - done, size = MemoryLayout<Float>.size
            for row in 0..<(stems * 2) {
                let from = sums + row * l
                memmove(from, from + done, kept * size)
                (from + kept).update(repeating: 0, count: done)
            }
            memmove(weights, weights + done, kept * size)
            (weights + kept).update(repeating: 0, count: done)
            progress(Double(k + 1) / Double(chunks.count))
        }
    }
}
