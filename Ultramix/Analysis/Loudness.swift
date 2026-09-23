//
//  Loudness.swift
//  Ultramix
//
//  LUFS after ITU-R BS.1770-4 and EBU R128. A track is measured once and what
//  is kept is the K-weighted power of every 100 ms; the standard's 400 ms
//  gating blocks are four consecutive hops, so the loudness of any stretch is
//  worked out in microseconds without touching the audio.
//
//  K-weighting is two biquads per channel. BS.1770 prints coefficients for
//  48 kHz only, which are wrong at 44.1 kHz, so they are derived from the
//  analog parameters instead.
//

import Foundation

/// One biquad in Double, transposed direct form II.
nonisolated struct LoudnessBiquad: Sendable {
    var b0, b1, b2, a1, a2: Double
    private var z1 = 0.0, z2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func clear() {
        z1 = 0
        z2 = 0
    }
}

/// The K-weighting filter for a stereo signal.
nonisolated struct KWeighting: Sendable {
    private var shelfL, shelfR, highPassL, highPassR: LoudnessBiquad

    init(sampleRate: Double) {
        let (shelf, highPass) = Self.coefficients(sampleRate: sampleRate)
        shelfL = shelf; shelfR = shelf
        highPassL = highPass; highPassR = highPass
    }

    static func coefficients(sampleRate: Double) -> (shelf: LoudnessBiquad, highPass: LoudnessBiquad) {
        // Stage 1: a high shelf, +4 dB above about 1.7 kHz.
        let gain = 3.999843853973347, q1 = 0.7071752369554196, f1 = 1681.974450955533
        let k1 = tan(Double.pi * f1 / sampleRate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let d1 = 1 + k1 / q1 + k1 * k1
        let shelf = LoudnessBiquad(b0: (vh + vb * k1 / q1 + k1 * k1) / d1,
                                   b1: 2 * (k1 * k1 - vh) / d1,
                                   b2: (vh - vb * k1 / q1 + k1 * k1) / d1,
                                   a1: 2 * (k1 * k1 - 1) / d1,
                                   a2: (1 - k1 / q1 + k1 * k1) / d1)
        // Stage 2: the RLB high-pass at about 38 Hz. Its numerator stays
        // 1, −2, 1, as the standard prints it: the −0.691 in the loudness
        // formula is calibrated with exactly that.
        let q2 = 0.5003270373238773, f2 = 38.13547087602444
        let k2 = tan(Double.pi * f2 / sampleRate)
        let d2 = 1 + k2 / q2 + k2 * k2
        let highPass = LoudnessBiquad(b0: 1, b1: -2, b2: 1,
                                      a1: 2 * (k2 * k2 - 1) / d2,
                                      a2: (1 - k2 / q2 + k2 * k2) / d2)
        return (shelf, highPass)
    }

    /// The K-weighted power of one stereo frame: both channels squared and
    /// summed, each with the weight 1.0 BS.1770 gives left and right.
    @inline(__always)
    mutating func power(_ left: Double, _ right: Double) -> Double {
        let l = highPassL.process(shelfL.process(left))
        let r = highPassR.process(shelfR.process(right))
        return l * l + r * r
    }

    mutating func clear() {
        shelfL.clear(); shelfR.clear()
        highPassL.clear(); highPassR.clear()
    }
}

/// A track's loudness, 100 ms at a time.
nonisolated struct LoudnessProfile: Sendable, Equatable {
    /// 100 ms at 44.1 kHz.
    static let hopFrames = 4410
    static let hopSeconds = 0.1
    /// 400 ms gating blocks, overlapping by 75 %.
    static let blockHops = 4
    static let formatVersion: Int32 = 1
    /// The absolute gate, −70 LUFS, as a power.
    static let silentPower = pow(10, (-70 + 0.691) / 10)

    /// Mean K-weighted power of each 100 ms of the file, the channels
    /// summed. A tail shorter than a hop is left out.
    let hops: [Float]
    /// The whole song's integrated loudness, for the library's column:
    /// worked out once here, not for every row on every redraw.
    let songLUFS: Double?
    /// Where the last 100 ms above −70 LUFS - the standard's own line for
    /// silence - ends; nil when there is none. What follows is the file's
    /// silent tail, which a beatmix does not count as part of the record.
    ///
    /// A level rule on raw samples (last sample above −60 dBFS) agrees to a
    /// median 0.07 s but counts a lone click after the music as sound, once
    /// by 8.5 s. The tail is a bar or more on about a third of tracks.
    let soundEndSeconds: Double?

    init(hops: [Float]) {
        self.hops = hops
        songLUFS = Self.integrated(hops, first: 0, last: hops.count)
        soundEndSeconds = Self.soundEnd(hops)
    }

    private static func soundEnd(_ hops: [Float]) -> Double? {
        let silent = Float(silentPower)
        return hops.lastIndex { $0 >= silent }.map { Double($0 + 1) * hopSeconds }
    }

    init(audio: AudioFrames) {
        var filter = KWeighting(sampleRate: AudioFrames.sampleRate)
        let count = audio.frameCount / Self.hopFrames
        var hops = [Float](repeating: 0, count: count)
        let samples = audio.samples
        for hop in 0..<count {
            var sum = 0.0
            let first = hop * Self.hopFrames
            for frame in first..<(first + Self.hopFrames) {
                sum += filter.power(Double(samples[2 * frame]), Double(samples[2 * frame + 1]))
            }
            hops[hop] = Float(sum / Double(Self.hopFrames))
        }
        self.hops = hops
        songLUFS = Self.integrated(hops, first: 0, last: hops.count)
        soundEndSeconds = Self.soundEnd(hops)
    }

    static func lufs(power: Double) -> Double {
        -0.691 + 10 * log10(power)
    }

    /// Integrated loudness of the file between two times, gated as BS.1770
    /// gates it. Only whole hops inside the range count. Nil when the range
    /// holds less than one 400 ms block, or nothing above −70 LUFS.
    func integrated(fromSeconds start: Double, toSeconds end: Double) -> Double? {
        // Held to the file before converting: Int(_:) traps on an infinite
        // or enormous value.
        let length = Double(hops.count)
        let first = Int(min(max(start / Self.hopSeconds - 1e-6, 0), length).rounded(.up))
        let last = Int(min(max(end / Self.hopSeconds + 1e-6, 0), length).rounded(.down))
        return Self.integrated(hops, first: first, last: last)
    }

    /// The gated loudness of `hops[first..<last]`.
    static func integrated(_ hops: [Float], first: Int, last: Int) -> Double? {
        guard last - first >= Self.blockHops else { return nil }
        var blocks: [Double] = []
        blocks.reserveCapacity(last - first - Self.blockHops + 1)
        for j in first...(last - Self.blockHops) {
            blocks.append((Double(hops[j]) + Double(hops[j + 1]) + Double(hops[j + 2]) + Double(hops[j + 3])) / 4)
        }
        return Self.gated(blocks)
    }

    /// The absolute gate at −70 LUFS, then the relative gate 10 LU under
    /// what passed the first.
    static func gated(_ blocks: [Double]) -> Double? {
        let audible = blocks.filter { $0 > silentPower }
        guard !audible.isEmpty else { return nil }
        let relative = audible.reduce(0, +) / Double(audible.count) * 0.1
        let kept = audible.filter { $0 > relative }
        guard !kept.isEmpty else { return nil }
        return lufs(power: kept.reduce(0, +) / Double(kept.count))
    }

    // MARK: - Storage
    //
    // Raw little-endian: two Int32s (format version, hop count), then the
    // hops as Float32. A file cut short fails the size check and is measured
    // again, like a waveform.

    func data() -> Data {
        var data = Data()
        let header = [Self.formatVersion, Int32(hops.count)]
        header.withUnsafeBytes { data.append(contentsOf: $0) }
        hops.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    init?(data: Data) {
        guard data.count >= 8 else { return nil }
        let header = data.prefix(8).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        guard header[0] == Self.formatVersion, header[1] >= 0, data.count == 8 + Int(header[1]) * 4 else { return nil }
        let stored = data.dropFirst(8).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        self.init(hops: stored)
    }
}

/// Short-term loudness - the last 3 s - measured sample by sample as the
/// output plays. It never allocates after init: it runs on the audio thread.
nonisolated final class ShortTermLoudness {
    static let windowHops = 30

    private var filter = KWeighting(sampleRate: AudioFrames.sampleRate)
    private let ring = UnsafeMutablePointer<Double>.allocate(capacity: windowHops)
    private var next = 0
    private var filled = 0
    private var hopSum = 0.0
    private var hopFrames = 0
    /// Mean power of the hops in the window; 0 until the first hop is complete.
    private(set) var power = 0.0

    init() {
        ring.initialize(repeating: 0, count: Self.windowHops)
    }

    deinit {
        ring.deallocate()
    }

    /// Until 3 s have played, the mean is over what has: a meter that
    /// started at a third of the level would read as a fade-in.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            hopSum += filter.power(Double(left[i]), Double(right[i]))
            hopFrames += 1
            guard hopFrames == LoudnessProfile.hopFrames else { continue }
            ring[next] = hopSum / Double(hopFrames)
            next = (next + 1) % Self.windowHops
            filled = min(filled + 1, Self.windowHops)
            hopSum = 0
            hopFrames = 0
            var total = 0.0
            for j in 0..<filled { total += ring[j] }
            power = total / Double(filled)
        }
    }

    /// Nil at or under −70 LUFS.
    var lufs: Double? {
        power > LoudnessProfile.silentPower ? LoudnessProfile.lufs(power: power) : nil
    }

    func reset() {
        filter.clear()
        ring.update(repeating: 0, count: Self.windowHops)
        next = 0
        filled = 0
        hopSum = 0
        hopFrames = 0
        power = 0
    }
}
