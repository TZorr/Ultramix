//
//  KeyAnalyzer.swift
//  Ultramix
//
//  Musical key from samples: magnitude spectra of 16384 samples (hop 4096),
//  their peaks from 30 Hz to 4.1 kHz named by pitch, overtones folded back onto
//  the fundamental (without which the common error is the key a fifth away),
//  summed into twelve pitch classes and correlated with the Krumhansl-Kessler
//  profiles (1982) rotated to each of the 24 keys.
//
//  Weak spot: minor against its relative or parallel major - the notes of
//  Am-F-C-G are the notes of C. Those come out with a small margin and are
//  flagged uncertain (`KeyAnalysis.uncertainBelow`).
//

import Foundation
import Accelerate

nonisolated enum KeyAnalyzer {
    /// Bump when a change would name a different key for the same track.
    static let version = 1

    private static let frameSize = 16384
    private static let hop = 4096
    private static let lowestHz = 30.0
    private static let highestHz = 4100.0
    private static let lowestMidi = 24.0
    private static let highestMidi = 108.0
    /// Semitones above a fundamental of its 2nd to 6th harmonics.
    private static let harmonics = [12.0, 19.02, 24.0, 27.86, 31.02]

    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func analyze(_ audio: AudioFrames) -> KeyAnalysis? {
        let chroma = pitchClasses(audio.monoMix())
        guard chroma.contains(where: { $0 > 0 }) else { return nil }
        return estimate(chroma)
    }

    /// The best key for twelve pitch-class weights (C first), and its lead
    /// over the second best.
    static func estimate(_ chroma: [Double]) -> KeyAnalysis {
        var scored: [(r: Double, key: MusicalKey)] = []
        for tonic in 0..<12 {
            for minor in [false, true] {
                let profile = minor ? minorProfile : majorProfile
                let turned = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                scored.append((correlation(chroma, turned), MusicalKey(tonic: tonic, minor: minor)))
            }
        }
        scored.sort { $0.r > $1.r }
        return KeyAnalysis(key: scored[0].key, margin: scored[0].r - scored[1].r, version: version)
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    static func pitchClasses(_ mono: [Float]) -> [Double] {
        let fft = RealFFT(size: frameSize)
        let binHz = AudioFrames.sampleRate / Double(frameSize)
        let lowBin = max(1, Int(lowestHz / binHz))
        let highBin = min(fft.binCount - 2, Int(highestHz / binHz))
        var magnitude = [Float](repeating: 0, count: fft.binCount)
        var chroma = [Double](repeating: 0, count: 12)
        var peaks: [(midi: Double, value: Double)] = []
        mono.withUnsafeBufferPointer { input in
            var start = 0
            while start + frameSize <= input.count {
                magnitude.withUnsafeMutableBufferPointer { fft.magnitudes(of: input.baseAddress! + start, into: $0.baseAddress!) }
                peaks.removeAll(keepingCapacity: true)
                for bin in lowBin...highBin {
                    let v = magnitude[bin]
                    guard v > magnitude[bin - 1], v >= magnitude[bin + 1], v > 1e-5 else { continue }
                    let a = Double(magnitude[bin - 1]), b = Double(v), c = Double(magnitude[bin + 1])
                    let denominator = a - 2 * b + c
                    let shift = denominator < 0 ? 0.5 * (a - c) / denominator : 0
                    let midi = 69 + 12 * log2((Double(bin) + shift) * binHz / 440)
                    guard midi.rounded() >= lowestMidi, midi.rounded() < highestMidi else { continue }
                    peaks.append((midi, b))
                }
                fold(peaks, into: &chroma)
                start += hop
            }
        }
        return chroma
    }

    /// Adds one frame's peaks to `chroma`, each overtone of a stronger,
    /// lower peak under that peak's pitch class.
    private static func fold(_ peaks: [(midi: Double, value: Double)], into chroma: inout [Double]) {
        let strongest = peaks.indices.sorted { peaks[$0].value > peaks[$1].value }.prefix(12)
        for peak in peaks {
            var pitch = peak.midi
            for i in strongest {
                let fundamental = peaks[i]
                guard fundamental.value > peak.value, fundamental.midi < peak.midi else { continue }
                let interval = peak.midi - fundamental.midi
                if harmonics.contains(where: { abs(interval - $0) < 0.34 }) {
                    pitch = fundamental.midi
                    break
                }
            }
            chroma[(Int(pitch.rounded()) % 12 + 12) % 12] += peak.value
        }
    }
}
