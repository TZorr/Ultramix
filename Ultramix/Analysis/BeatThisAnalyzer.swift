//
//  BeatThisAnalyzer.swift
//  Ultramix
//
//  The optional second beat analyser: the Beat This! network decides tempo,
//  on-beat vs off-beat and bar one; the kick fit (`TempoAnalyzer`) then places
//  the lines. The network reads 20 ms frames, so a grid drawn through its beats
//  alone drifts (23 % of kicks within 20 ms, against 84 % for the kick fit) -
//  but the musical question is where the kick fit is weakest.
//
//  Input matches the network's training front end: mono at 22 050 Hz, a centred
//  STFT of 1024 with hop 441, periodic Hann, magnitudes / √1024, 128 Slaney mel
//  bands from 30 Hz to 11 kHz without area normalisation, log(1 + 1000·x).
//  Chunks of 1500 frames, 6 border frames dropped each side, the earlier chunk
//  kept on overlap, a beat where a logit is positive and largest within
//  ±3 frames.
//

import Foundation
import Accelerate

nonisolated enum BeatThisAnalyzer {
    /// Bump when a change would give a different grid for the same track.
    static let version = 1

    static let sampleRate = 22_050.0
    static let fftSize = 1024
    static let hop = 441
    static let frameRate = sampleRate / Double(hop)     // 50
    static let chunkBorder = 6

    typealias Failure = TempoAnalyzer.Failure

    /// - Parameter hintBPM: a tempo the user tapped; the tempo then stays
    ///   within ±8 % of it, as with the other analyser.
    static func analyze(_ audio: AudioFrames, hintBPM: Double? = nil, model: BeatThisModel) throws -> TrackAnalysis {
        let mono = audio.monoMix()
        guard Double(mono.count) > AudioFrames.sampleRate * 8 else {
            throw Failure(reason: "The track is too short to find a tempo in.")
        }
        let spectrum = melSpectrogram(downsample(mono))
        let logits = try activations(spectrum, model: model)
        let found = beats(logits)
        guard found.beats.count >= 16 else {
            throw Failure(reason: "Beat This! found no steady beat.")
        }
        return try fit(mono: mono, duration: audio.duration, beats: found.beats,
                       downbeats: found.downbeats, hintBPM: hintBPM)
    }

    // MARK: - 1. 44.1 kHz → 22.05 kHz

    /// Taps each side of the centre of the anti-alias filter.
    static let halfTaps = 128

    /// A Kaiser-windowed half-band low-pass, 257 taps, unity at DC.
    static let decimationFilter: [Float] = {
        let beta = 8.0
        func bessel0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<32 {
                term *= (x / 2) / Double(k)
                sum += term * term
            }
            return sum
        }
        let m = Double(halfTaps)
        var taps = (-halfTaps...halfTaps).map { i -> Double in
            let n = Double(i)
            let sinc = i == 0 ? 0.5 : sin(Double.pi * n / 2) / (Double.pi * n)
            let window = bessel0(beta * (1 - (n / m) * (n / m)).squareRoot()) / bessel0(beta)
            return sinc * window
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        return taps.map(Float.init)
    }()

    /// Every other sample after the low-pass; output sample n is input
    /// sample 2n, with no delay.
    static func downsample(_ mono: [Float]) -> [Float] {
        let count = (mono.count + 1) / 2
        guard count > 0 else { return [] }
        let filter = decimationFilter
        var padded = [Float](repeating: 0, count: halfTaps + mono.count + halfTaps + 2)
        padded.withUnsafeMutableBufferPointer { out in
            mono.withUnsafeBufferPointer { out.baseAddress!.advanced(by: halfTaps).update(from: $0.baseAddress!, count: mono.count) }
        }
        var output = [Float](repeating: 0, count: count)
        vDSP_desamp(padded, 2, filter, &output, vDSP_Length(count), vDSP_Length(filter.count))
        return output
    }

    // MARK: - 2. Log-mel spectrum

    static let bands = BeatThisModel.bands
    static let bins = fftSize / 2 + 1

    /// Slaney's mel scale: linear below 1 kHz, logarithmic above.
    static func melFromHz(_ hz: Double) -> Double {
        let logStep = log(6.4) / 27
        return hz < 1000 ? hz * 3 / 200 : 15 + log(hz / 1000) / logStep
    }

    static func hzFromMel(_ mel: Double) -> Double {
        let logStep = log(6.4) / 27
        return mel < 15 ? mel * 200 / 3 : 1000 * exp(logStep * (mel - 15))
    }

    /// `bins` × `bands` weights, bin-major: torchaudio's triangles, laid on
    /// the exact bin frequencies, not rounded to bins.
    static let melFilterbank: [Float] = {
        let low = melFromHz(30), high = melFromHz(11_000)
        let points = (0..<(bands + 2)).map { hzFromMel(low + (high - low) * Double($0) / Double(bands + 1)) }
        var weights = [Float](repeating: 0, count: bins * bands)
        for k in 0..<bins {
            // torchaudio spaces the bins over 0 … sample_rate // 2.
            let hz = Double(k) * 11_025 / Double(bins - 1)
            for m in 0..<bands {
                let rising = (hz - points[m]) / (points[m + 1] - points[m])
                let falling = (points[m + 2] - hz) / (points[m + 2] - points[m + 1])
                weights[k * bands + m] = Float(max(0, min(rising, falling)))
            }
        }
        return weights
    }()

    struct Spectrum {
        /// `frames` × `bands`, frame-major.
        var values: [Float]
        var frames: Int
    }

    static func melSpectrogram(_ samples: [Float]) -> Spectrum {
        let half = fftSize / 2
        guard samples.count > half else { return Spectrum(values: [], frames: 0) }
        // Centred frames: the signal is mirrored by half a window at each
        // end (the edge sample itself not repeated), so frame t is centred
        // on sample t·hop.
        var padded = [Float](repeating: 0, count: samples.count + fftSize)
        for i in 0..<half { padded[i] = samples[half - i] }
        for i in 0..<samples.count { padded[half + i] = samples[i] }
        for i in 0..<half { padded[half + samples.count + i] = samples[samples.count - 2 - i] }
        let frames = 1 + samples.count / hop

        let window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }
        let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!
        defer { vDSP_DFT_DestroySetup(setup) }
        let zeros = [Float](repeating: 0, count: fftSize)
        var frame = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: fftSize)
        var values = [Float](repeating: 0, count: frames * bands)
        let filterbank = melFilterbank
        let scale = Float(1 / Double(fftSize).squareRoot())

        padded.withUnsafeBufferPointer { input in
            for t in 0..<frames {
                vDSP_vmul(input.baseAddress! + t * hop, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
                vDSP_DFT_Execute(setup, frame, zeros, &outReal, &outImag)
                outReal.withUnsafeMutableBufferPointer { re in
                    outImag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(bins))
                    }
                }
                vDSP_vsmul(magnitudes, 1, [scale], &magnitudes, 1, vDSP_Length(bins))
                values.withUnsafeMutableBufferPointer { out in
                    // mel = magnitudesᵀ · filterbank (1 × bins times bins × bands)
                    vDSP_mmul(magnitudes, 1, filterbank, 1, out.baseAddress! + t * bands, 1,
                              1, vDSP_Length(bands), vDSP_Length(bins))
                }
            }
        }
        for i in values.indices { values[i] = log1p(1000 * values[i]) }
        return Spectrum(values: values, frames: frames)
    }

    // MARK: - 3. The network, chunk by chunk

    struct Logits {
        var beat: [Float]
        var downbeat: [Float]
    }

    /// Where the chunks start (beat_this's `split_piece`): every
    /// chunk-minus-borders frames from −border, the last one moved back to
    /// end exactly at the track's end.
    static func chunkStarts(frames: Int) -> [Int] {
        let chunk = BeatThisModel.frames, step = chunk - 2 * chunkBorder
        var starts = Array(stride(from: -chunkBorder, to: frames - chunkBorder, by: step))
        if frames > step, !starts.isEmpty { starts[starts.count - 1] = frames - (chunk - chunkBorder) }
        return starts
    }

    static func activations(_ spectrum: Spectrum, model: BeatThisModel) throws -> Logits {
        let n = spectrum.frames, chunk = BeatThisModel.frames
        var logits = Logits(beat: .init(repeating: -1000, count: n), downbeat: .init(repeating: -1000, count: n))
        // Later chunks first, so an earlier one overwrites where they overlap.
        for start in chunkStarts(frames: n).reversed() {
            var input = [Float](repeating: 0, count: chunk * bands)
            let from = max(start, 0), to = min(start + chunk, n)
            if to > from {
                let offset = (from - start) * bands
                input.withUnsafeMutableBufferPointer { out in
                    spectrum.values.withUnsafeBufferPointer { source in
                        (out.baseAddress! + offset).update(from: source.baseAddress! + from * bands,
                                                           count: (to - from) * bands)
                    }
                }
            }
            let output = try model.predict(input)
            for i in chunkBorder..<(chunk - chunkBorder) {
                let frame = start + i
                guard frame >= 0, frame < n, i < output.beat.count, i < output.downbeat.count else { continue }
                logits.beat[frame] = output.beat[i]
                logits.downbeat[frame] = output.downbeat[i]
            }
        }
        return logits
    }

    // MARK: - 4. Beats and downbeats

    /// Frames whose logit is positive and the largest within ±3 frames;
    /// neighbours one frame apart merge into their mean.
    static func peaks(_ logits: [Float]) -> [Double] {
        var frames: [Int] = []
        for i in logits.indices where logits[i] > 0 {
            let lo = max(0, i - 3), hi = min(logits.count - 1, i + 3)
            if logits[lo...hi].max()! == logits[i] { frames.append(i) }
        }
        var result: [Double] = []
        guard var mean = frames.first.map(Double.init) else { return result }
        var last = frames[0], count = 1.0
        for frame in frames.dropFirst() {
            if frame - last <= 1 {
                count += 1
                mean += (Double(frame) - mean) / count
            } else {
                result.append(mean)
                mean = Double(frame)
                count = 1
            }
            last = frame
        }
        result.append(mean)
        return result
    }

    /// Beat and downbeat times in seconds; each downbeat moved onto its
    /// nearest beat.
    static func beats(_ logits: Logits) -> (beats: [Double], downbeats: [Double]) {
        let beats = peaks(logits.beat).map { $0 / frameRate }
        guard !beats.isEmpty else { return ([], []) }
        var downbeats: [Double] = []
        for time in peaks(logits.downbeat).map({ $0 / frameRate }) {
            let nearest = beats.min { abs($0 - time) < abs($1 - time) }!
            if downbeats.last != nearest { downbeats.append(nearest) }
        }
        return (beats, downbeats)
    }

    // MARK: - 5. The grid

    /// The network's beat period: the mean of the beat-to-beat intervals
    /// within 10 % of their median. A single interval is only good to a
    /// frame (20 ms, 4 % of a beat); the mean of hundreds is far better, and
    /// the kick fit searches only ±1 % about it.
    static func beatPeriod(_ beats: [Double]) -> Double? {
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
        guard intervals.count >= 8 else { return nil }
        let median = intervals.sorted()[intervals.count / 2]
        let steady = intervals.filter { abs($0 - median) <= 0.1 * median }
        guard steady.count >= 8 else { return nil }
        return steady.reduce(0, +) / Double(steady.count)
    }

    /// The share of `times` within `tolerance` of a line of `grid`.
    static func share(_ times: [Double], on grid: TempoAnalyzer.Grid, tolerance: Double) -> Double {
        guard !times.isEmpty else { return 0 }
        let hits = times.filter { time in
            let k = ((time - grid.phase) / grid.period).rounded()
            return abs(time - grid.time(ofBeat: Int(k))) <= tolerance
        }
        return Double(hits.count) / Double(times.count)
    }

    static let beatTolerance = 0.035

    static func fit(mono: [Float], duration: Double, beats: [Double], downbeats: [Double],
                    hintBPM: Double?) throws -> TrackAnalysis {
        typealias T = TempoAnalyzer
        let flux = T.spectralFlux(mono)
        let kick = T.KickEnvelope(mono)

        // The tempo: the network's, moved by octaves into the range; with a
        // hint, into its ±8 %, and failing that the other analyser's search.
        var rough: Double
        if let period = beatPeriod(beats) {
            rough = period
            let range = hintBPM.map { ($0 * 0.92)...($0 * 1.08) } ?? T.detectionRange
            while 60 / rough > range.upperBound { rough *= 2 }
            while 60 / rough < range.lowerBound { rough /= 2 }
            if !range.contains(60 / rough) { rough = try T.roughPeriod(flux, hint: hintBPM) }
        } else if hintBPM != nil {
            rough = try T.roughPeriod(flux, hint: hintBPM)
        } else {
            throw Failure(reason: "Beat This! found no steady beat.")
        }

        let beatEvents = beats.map { T.Event(time: $0, weight: 1) }
        let events = T.onsetEvents(flux: flux, kick: kick, period: rough)
        var grid: T.Grid
        var eventsInRange: Int
        let kicked = events.count >= 16 ? T.bestFit(events, near: rough, kick: kick) : nil
        if let kicked, abs(kicked.period / rough - 1) <= 0.02 {
            let fitEvents = T.kickEvents(events, kick)
            grid = T.roundedTempo(fitEvents, kicked)
            eventsInRange = fitEvents.count
        } else {
            // No kick to fit to: the line through the network's beats.
            let start = T.Grid(period: rough, phase: T.densestPhase(beatEvents, period: rough))
            grid = T.roundedTempo(beatEvents, T.fitGrid(beatEvents, start))
            eventsInRange = beatEvents.count
        }

        guard (hintBPM.map { ($0 * 0.92)...($0 * 1.08) } ?? T.detectionRange).contains(60 / grid.period) else {
            throw Failure(reason: "Beat This! found no steady beat.")
        }

        // Bar one: where the groove starts, as the other analyser finds it,
        // moved to the beat of the bar the network's downbeats agree on -
        // but only while the network is hearing the same beats as the grid.
        // On a mechanical fixture it hears the hats instead, and its bar
        // phase then says nothing about the kicks.
        let groove = T.firstDownbeat(grid: grid, kick: kick, flux: flux, duration: duration)
        let heard = share(beats, on: grid, tolerance: beatTolerance) >= 0.5
        let bar = heard ? barOne(grid: grid, groove: groove.time, downbeats: downbeats) : nil
        let first = bar?.time ?? groove.time
        let downbeatConfidence = bar?.agreement ?? groove.confidence

        let bpm = (60 / grid.period * 1000).rounded() / 1000
        return TrackAnalysis(bpm: bpm, firstBeatSeconds: first,
                             confidence: grid.confidence(eventsInRange: eventsInRange) * 0.8 + downbeatConfidence * 0.2,
                             version: version, algorithm: .beatThis)
    }

    /// The beat nearest `groove` whose place in the bar the most downbeats
    /// share, and the share of downbeats that agree; nil unless at least
    /// eight downbeats fall on the grid and three in five agree - a split
    /// vote is the network hearing bars where this grid has none, and the
    /// other analyser's downbeat is then the better answer.
    static func barOne(grid: TempoAnalyzer.Grid, groove: Double, downbeats: [Double])
        -> (time: Double, agreement: Double)?
    {
        let beatsPerBar = 4
        var votes = [Int](repeating: 0, count: beatsPerBar)
        for time in downbeats {
            let k = Int(((time - grid.phase) / grid.period).rounded())
            guard abs(time - grid.time(ofBeat: k)) <= 2 * beatTolerance else { continue }
            votes[((k % beatsPerBar) + beatsPerBar) % beatsPerBar] += 1
        }
        let total = votes.reduce(0, +)
        guard total >= 8, total >= downbeats.count / 2 else { return nil }
        let place = votes.indices.max { votes[$0] < votes[$1] }!
        guard Double(votes[place]) / Double(total) >= 0.6 else { return nil }
        let k0 = Int(((groove - grid.phase) / grid.period).rounded())
        // The candidates two beats either side are equally near; the later
        // one keeps bar one inside the file.
        var best: Int?
        for delta in [0, 1, -1, 2, -2] {
            let k = k0 + delta
            guard ((k % beatsPerBar) + beatsPerBar) % beatsPerBar == place else { continue }
            if k < 0 { continue }
            best = k
            break
        }
        let k = best ?? (k0 + 2)
        return (grid.time(ofBeat: k), Double(votes[place]) / Double(total))
    }
}
