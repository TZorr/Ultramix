//
//  Stretcher.swift
//  Ultramix
//
//  Pitch-preserving time-stretch by waveform-similarity overlap-add (WSOLA),
//  locked to the track's beatgrid.
//
//  Output is cut into grains of up to `hop` frames, each playing a run of the
//  source at its natural speed from where the tempo map says the source should
//  be. Faster skips a little source between grains, slower repeats a little;
//  the tempo comes from those jumps, not from resampling.
//
//  A jump is a splice, so a grain may start up to `searchRadius` frames off,
//  where its waveform best continues the previous grain, with a cross-fade.
//  That search is WSOLA's weakness for DJ use: whatever sits inside a grain
//  moves with it, and a kick moved 10 ms is a flam against the other record.
//  Free-running on the 124.5 -> 128 BPM fixture: 5.7 ms rms, 13.2 ms worst.
//
//  So the chain restarts on the source's own eighth-note grid. A restart grain
//  begins exactly where the map puts that eighth note, with no search and a
//  1.5 ms splice, short enough to leave the attack intact; between restarts
//  the grains search as usual. Same fixture: 1.5 ms rms, 3.0 ms worst.
//
//  Source and output are both 44.1 kHz and a grain starts on a whole source
//  frame, so a grain is a straight copy. At a ratio of exactly 1 the grains
//  are contiguous, search and cross-fade are skipped, and the output is the
//  source bit for bit.
//
//  The restarts double as determinism anchors: a grain depends on the previous
//  one only back to the last restart, so any grain is a pure function of its
//  position. `StretchMemo` is an accelerator only - the harness renders with
//  and without it and compares bit for bit.
//

import Foundation

/// One run of the timeline that plays one run of one source file.
nonisolated struct RenderSegment: Sendable {
    let clipID: UUID
    let lane: Int
    let audio: AudioFrames
    /// Timeline frames, half-open.
    let startFrame: Int
    let endFrame: Int
    /// Timeline beat at which the source's frame 0 would play.
    let fileStartBeat: Double
    let sourceBPM: Double
    /// Where the source's beatgrid falls on the timeline, as a fraction of a
    /// beat: its beats land on timeline beats `gridPhase + k`.
    let gridPhase: Double
    /// The clip's gain as a linear factor.
    var gain: Float = 1
    /// The clip's stems at its levels, when they are not all the same:
    /// what is played instead of `audio`. `audio` is still what the splice
    /// search compares, so where the grains start does not depend on the
    /// levels.
    var stems: StemMix? = nil
    /// The stem bus it plays into, when it is a stem with automation of
    /// its own; nil for the lane.
    var part: Stem? = nil

    /// The fractional source frame the tempo map puts at timeline frame `n`.
    func nominalSourceFrame(atTimelineFrame n: Int, tempo: TempoMap) -> Double {
        let beat = tempo.beat(atSeconds: Double(n) / AudioFrames.sampleRate)
        return (beat - fileStartBeat) * 60 / sourceBPM * AudioFrames.sampleRate
    }
}

/// A track's three stored stems, decoded, at the pitch its clip plays.
nonisolated struct StemAudio: Sendable {
    let drums: AudioFrames
    let bass: AudioFrames
    let vocals: AudioFrames

    var all: [AudioFrames] { [drums, bass, vocals] }
}

/// What a clip plays when its stems are at different levels: per sample,
/// `full · k0 + drums · k1 + bass · k2 + vocals · k3`, where `full` is the
/// song at the clip's pitch. "Other" is the song less the three, so
/// k0 = g(other) and k(i) = (g(i) − g(other)) / Stem.storedScale: the song
/// at its own level carries "other", and each stored stem adds the
/// difference its own level makes.
///
/// Unchecked: the pointers are into the AudioFrames it holds, which are
/// immutable and live as long as it does.
nonisolated struct StemMix: @unchecked Sendable {
    let audio: StemAudio
    let k0, k1, k2, k3: Float
    private let drums, bass, vocals: UnsafePointer<Float>

    /// `gains` per stem, in the order of `Stem.allCases`.
    init(_ audio: StemAudio, gains: [Float]) {
        self.audio = audio
        let other = gains[Stem.other.rawValue], scale = Stem.storedScale
        k0 = other
        k1 = (gains[Stem.drums.rawValue] - other) / scale
        k2 = (gains[Stem.bass.rawValue] - other) / scale
        k3 = (gains[Stem.vocals.rawValue] - other) / scale
        drums = audio.drums.samples
        bass = audio.bass.samples
        vocals = audio.vocals.samples
    }

    /// Sample `i` (interleaved) of the mix, `full` being the song's.
    @inline(__always)
    func sample(_ full: UnsafePointer<Float>, _ i: Int) -> Float {
        full[i] * k0 + drums[i] * k1 + bass[i] * k2 + vocals[i] * k3
    }
}

/// A grain: the `index`-th after restart point `restart`.
nonisolated struct GrainKey: Equatable, Sendable {
    var restart: Int
    var index: Int
}

/// The last two grain starts of one segment. Owned by whoever renders the
/// segment - the playback thread or a bounce, never both.
nonisolated struct StretchMemo {
    var lastKey = GrainKey(restart: Int.min, index: 0)
    var lastStart = 0
    var earlierKey = GrainKey(restart: Int.min, index: 0)
    var earlierStart = 0

    func lookup(_ key: GrainKey) -> Int? {
        if key == lastKey { return lastStart }
        if key == earlierKey { return earlierStart }
        return nil
    }

    mutating func remember(_ key: GrainKey, _ start: Int) {
        guard key != lastKey else { return }
        earlierKey = lastKey
        earlierStart = lastStart
        lastKey = key
        lastStart = start
    }
}

nonisolated final class Stretcher {
    static let hop = 2048
    /// Cross-fade between searched grains.
    static let fade = 256
    /// Cross-fade into a restart grain: short, because a transient sits
    /// right there and a long fade would soften it.
    static let restartFade = 64
    /// Restart grid, in source beats: eighth notes.
    static let restartBeats = 0.5
    static let searchRadius = 512
    /// Length of waveform compared when looking for a splice point.
    static let windowLength = 1024
    /// A small pull towards the nominal position, so that among nearly equal
    /// matches the one that keeps the timing wins.
    static let offsetPenalty = 0.025
    /// Fade at every segment edge: a clip cut mid-waveform, or a loop turning
    /// round, would otherwise click.
    static let edgeFrames = 88

    private let reference: UnsafeMutablePointer<Float>
    private let fadeCurve: UnsafeMutablePointer<Float>
    private let restartCurve: UnsafeMutablePointer<Float>
    /// Set to false by the harness to prove the memo changes nothing.
    var usesMemo = true

    init() {
        reference = .allocate(capacity: Self.windowLength)
        fadeCurve = .allocate(capacity: Self.fade)
        restartCurve = .allocate(capacity: Self.restartFade)
        for p in 0..<Self.fade {
            fadeCurve[p] = Float(0.5 - 0.5 * cos(Double.pi * (Double(p) + 0.5) / Double(Self.fade)))
        }
        for p in 0..<Self.restartFade {
            restartCurve[p] = Float(0.5 - 0.5 * cos(Double.pi * (Double(p) + 0.5) / Double(Self.restartFade)))
        }
    }

    deinit {
        reference.deallocate()
        fadeCurve.deallocate()
        restartCurve.deallocate()
    }

    // MARK: - Rendering

    /// Adds the segment's output for timeline frames `from ..< from + count`
    /// into `left`/`right` (index 0 = frame `from`), with edge fades.
    func render(_ segment: RenderSegment, tempo: TempoMap, from: Int, count: Int,
                left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                memo: inout StretchMemo) {
        let first = max(from, segment.startFrame)
        let end = min(from + count, segment.endFrame)
        guard first < end else { return }
        if !usesMemo { memo = StretchMemo() }

        let samples = segment.audio.samples
        let frames = segment.audio.frameCount
        let stems = segment.stems
        let edge = Float(Self.edgeFrames)
        var n = first
        while n < end {
            let restart = restartIndex(containing: n, segment, tempo)
            let restartFrame = frame(ofRestart: restart, segment, tempo)
            let nextRestart = frame(ofRestart: restart + 1, segment, tempo)
            let index = (n - restartFrame) / Self.hop
            let grainFrame = restartFrame + index * Self.hop
            let grainEnd = min(grainFrame + Self.hop, nextRestart)
            let chunkEnd = min(end, grainEnd)

            // The grain before this one, and where it would have carried on.
            let previousKey: GrainKey
            let previousLength: Int
            if index > 0 {
                previousKey = GrainKey(restart: restart, index: index - 1)
                previousLength = Self.hop
            } else {
                let previousFrame = frame(ofRestart: restart - 1, segment, tempo)
                let last = max(0, (restartFrame - previousFrame - 1) / Self.hop)
                previousKey = GrainKey(restart: restart - 1, index: last)
                previousLength = restartFrame - (previousFrame + last * Self.hop)
            }
            let continuation = start(of: previousKey, segment, tempo, &memo) + previousLength
            let current = start(of: GrainKey(restart: restart, index: index), segment, tempo, &memo)
            // Contiguous grains need no splice, and skipping the cross-fade
            // is what keeps a ratio of 1 bit-exact.
            let splice = continuation != current
            let fadeLength = index == 0 ? Self.restartFade : Self.fade
            let curve = index == 0 ? restartCurve : fadeCurve

            for m in n..<chunkEnd {
                let p = m - grainFrame
                let source = current + p
                var l: Float = 0, r: Float = 0
                if source >= 0 && source < frames {
                    if let stems {
                        l = stems.sample(samples, 2 * source)
                        r = stems.sample(samples, 2 * source + 1)
                    } else {
                        l = samples[2 * source]
                        r = samples[2 * source + 1]
                    }
                }
                if splice && p < fadeLength {
                    let old = continuation + p
                    var ol: Float = 0, or: Float = 0
                    if old >= 0 && old < frames {
                        if let stems {
                            ol = stems.sample(samples, 2 * old)
                            or = stems.sample(samples, 2 * old + 1)
                        } else {
                            ol = samples[2 * old]
                            or = samples[2 * old + 1]
                        }
                    }
                    let w = curve[p]
                    l = ol + (l - ol) * w
                    r = or + (r - or) * w
                }
                let fromStart = Float(m - segment.startFrame) + 0.5
                let fromEnd = Float(segment.endFrame - m) - 0.5
                if fromStart < edge || fromEnd < edge {
                    let g = min(1, fromStart / edge, fromEnd / edge)
                    l *= g
                    r *= g
                }
                // The clip's gain. A gain of 1 multiplies exactly, so a clip
                // at 0 dB stays bit-exact.
                left[m - from] += l * segment.gain
                right[m - from] += r * segment.gain
            }
            n = chunkEnd
        }
    }

    // MARK: - The restart grid

    /// Timeline frame of restart point `k`: the k-th eighth note of the
    /// source's grid, counted from its first downbeat's phase.
    func frame(ofRestart k: Int, _ segment: RenderSegment, _ tempo: TempoMap) -> Int {
        Self.frame(ofRestart: k, segment, tempo)
    }

    static func frame(ofRestart k: Int, _ segment: RenderSegment, _ tempo: TempoMap) -> Int {
        let beat = segment.gridPhase + Double(k) * restartBeats
        return Int((tempo.seconds(atBeat: beat) * AudioFrames.sampleRate).rounded(.up))
    }

    private func restartIndex(containing n: Int, _ segment: RenderSegment, _ tempo: TempoMap) -> Int {
        let beat = tempo.beat(atSeconds: Double(n) / AudioFrames.sampleRate)
        var k = Int(((beat - segment.gridPhase) / Self.restartBeats).rounded(.down))
        // The frame rounding can put n a hair either side of the beat maths.
        while frame(ofRestart: k, segment, tempo) > n { k -= 1 }
        while frame(ofRestart: k + 1, segment, tempo) <= n { k += 1 }
        return k
    }

    // MARK: - The grain chain

    /// Source frame at which a grain starts.
    func start(of key: GrainKey, _ segment: RenderSegment, _ tempo: TempoMap, _ memo: inout StretchMemo) -> Int {
        if let known = memo.lookup(key) { return known }
        let restartFrame = frame(ofRestart: key.restart, segment, tempo)
        if key.index == 0 {
            let s = nominal(restartFrame, segment, tempo)
            memo.remember(key, s)
            return s
        }
        if let previous = memo.lookup(GrainKey(restart: key.restart, index: key.index - 1)) {
            let s = next(after: previous, grainFrame: restartFrame + key.index * Self.hop, segment, tempo)
            memo.remember(key, s)
            return s
        }
        // Cold: walk from the restart.
        var s = nominal(restartFrame, segment, tempo)
        for i in 1...key.index {
            let following = next(after: s, grainFrame: restartFrame + i * Self.hop, segment, tempo)
            if i == key.index { memo.remember(GrainKey(restart: key.restart, index: i - 1), s) }
            s = following
        }
        memo.remember(key, s)
        return s
    }

    private func nominal(_ timelineFrame: Int, _ segment: RenderSegment, _ tempo: TempoMap) -> Int {
        Int(segment.nominalSourceFrame(atTimelineFrame: timelineFrame, tempo: tempo).rounded())
    }

    private func next(after previous: Int, grainFrame: Int, _ segment: RenderSegment, _ tempo: TempoMap) -> Int {
        let continuation = previous + Self.hop
        let exact = segment.nominalSourceFrame(atTimelineFrame: grainFrame, tempo: tempo)
        // Within three quarters of a frame of simply carrying on: carry on.
        // (Not half a frame - rounding the map's position at the restart can
        // leave exactly half a frame, and that must not count as a jump.)
        if abs(exact - Double(continuation)) < 0.75 { return continuation }
        return align(continuation: continuation, nominal: Int(exact.rounded()), segment.audio)
    }

    // MARK: - Finding the splice

    /// The start near `nominal` whose waveform best continues what the
    /// previous grain would have played next.
    private func align(continuation: Int, nominal: Int, _ audio: AudioFrames) -> Int {
        let length = Self.windowLength
        for i in 0..<length { reference[i] = mono(audio, continuation + i) }

        func score(_ offset: Int, stride step: Int) -> Double {
            var dot: Float = 0, energy: Float = 0, referenceEnergy: Float = 0
            var i = 0
            while i < length {
                let x = mono(audio, nominal + offset + i)
                let y = reference[i]
                dot += x * y
                energy += x * x
                referenceEnergy += y * y
                i += step
            }
            guard referenceEnergy > 1e-9, energy > 1e-9 else { return -Double.infinity }
            let correlation = Double(dot) / Double(energy * referenceEnergy).squareRoot()
            let pull = Double(offset) / Double(Self.searchRadius)
            return correlation - Self.offsetPenalty * pull * pull
        }

        // Silence has no waveform to match; keep the map's position.
        var silent = true
        for i in Swift.stride(from: 0, to: length, by: 8) where abs(reference[i]) > 1e-5 { silent = false; break }
        if silent { return nominal }

        var best = 0
        var bestScore = -Double.infinity
        for offset in Swift.stride(from: -Self.searchRadius, through: Self.searchRadius, by: 16) {
            let s = score(offset, stride: 8)
            if s > bestScore { bestScore = s; best = offset }
        }
        // Each stage re-scores its starting point at its own stride: a score
        // from a sparser comparison is not on the same footing.
        let coarse = best
        bestScore = score(coarse, stride: 4)
        for offset in Swift.stride(from: coarse - 12, through: coarse + 12, by: 4)
            where offset != coarse && abs(offset) <= Self.searchRadius {
            let s = score(offset, stride: 4)
            if s > bestScore { bestScore = s; best = offset }
        }
        let fine = best
        bestScore = score(fine, stride: 2)
        for offset in (fine - 3)...(fine + 3) where offset != fine && abs(offset) <= Self.searchRadius {
            let s = score(offset, stride: 2)
            if s > bestScore { bestScore = s; best = offset }
        }
        return nominal + best
    }

    @inline(__always)
    private func mono(_ audio: AudioFrames, _ frame: Int) -> Float {
        guard frame >= 0 && frame < audio.frameCount else { return 0 }
        return (audio.samples[2 * frame] + audio.samples[2 * frame + 1]) * 0.5
    }
}
