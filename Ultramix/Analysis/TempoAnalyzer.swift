//
//  TempoAnalyzer.swift
//  Ultramix
//
//  Tempo, beatgrid and first downbeat from the samples alone. The grid is
//  deliberately rigid - one tempo and one downbeat per track - because that is
//  what the timeline can use, and the job is to land it on the kicks to about
//  a millisecond over the whole track.
//
//  1. Spectral flux at 100 frames a second, across the spectrum and in the
//     kick band alone (43-150 Hz).
//  2. A rough period from the flux autocorrelation, 70-190 BPM in
//     quarter-frame lags. The octave (87 or 174?) cannot be read from the
//     signal, so a mild preference for the middle of the dance range decides
//     (`octavePreference`); the editor's ½× and 2× exist for when it is wrong.
//  3. Onset events: kick-band flux peaks, re-timed on a 1 ms envelope.
//  4. The exact period: within 1 % of the rough one, where the phase-vector
//     sum Σ w·e^(2πi·t/P) is largest. The measurement sharpens with length.
//  5. A least-squares line through (beat index, event time), outliers trimmed
//     in rounds (50 -> 18 ms), started from several guesses.
//  5b. A whole or half BPM where the fit allows it (`roundedTempo`).
//  6. The downbeat: where the groove starts, and which of the four beats after
//     it brings the most change.
//

import Foundation
import Accelerate

nonisolated enum TempoAnalyzer {
    /// Bump when a change would give a different grid for the same track.
    /// Tracks analysed by an older version are analysed again.
    ///
    /// 2: quarter-frame rough period (`lagStep`), no octave rule, several
    /// fit starts (`bestFit`), round tempos (`roundedTempo`). Over a
    /// 783-track set: 26 of 30 hand-set tempos right or within 1 %, against
    /// 11; 261 whole-number tempos, against 144.
    ///
    /// 3: the grid line is fitted through the kicks alone (`kickEvents`) and
    /// the confidence counts them. Mean kick offset +0.26 -> −0.01 ms; two
    /// grids that sat on the off-beat now sit on the kicks.
    static let version = 3

    static let detectionRange: ClosedRange<Double> = 70...190

    private static let sampleRate = AudioFrames.sampleRate
    private static let hop = 441                 // 10 ms
    private static let fftSize = 2048
    private static let frameRate = sampleRate / Double(hop)

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// - Parameter hintBPM: a tempo the user tapped. The search then stays
    ///   within ±8 % of it and the octave question does not arise.
    static func analyze(_ audio: AudioFrames, hintBPM: Double? = nil) throws -> TrackAnalysis {
        let mono = audio.monoMix()
        guard Double(mono.count) > sampleRate * 8 else {
            throw Failure(reason: "The track is too short to find a tempo in.")
        }
        let flux = spectralFlux(mono)
        let kick = KickEnvelope(mono)
        let rough = try roughPeriod(flux, hint: hintBPM)
        let events = onsetEvents(flux: flux, kick: kick, period: rough)
        guard events.count >= 16 else {
            throw Failure(reason: "No steady beat was found.")
        }
        let fitEvents = kickEvents(events, kick)
        let grid = roundedTempo(fitEvents, bestFit(events, near: rough, kick: kick))
        let range = detectionRange
        let bpmRange = hintBPM.map { ($0 * 0.92)...($0 * 1.08) } ?? range
        guard bpmRange.contains(60 / grid.period) else {
            throw Failure(reason: "No steady beat was found.")
        }
        let downbeat = firstDownbeat(grid: grid, kick: kick, flux: flux, duration: audio.duration)
        let bpm = (60 / grid.period * 1000).rounded() / 1000
        return TrackAnalysis(bpm: bpm, firstBeatSeconds: downbeat.time,
                             confidence: grid.confidence(eventsInRange: fitEvents.count) * 0.8 + downbeat.confidence * 0.2,
                             version: version)
    }

    /// The kicks in the track, timed exactly as the grid fit sees them - for
    /// the beatgrid editor to draw beside its lines, so a grid that is off
    /// shows as a steady gap. Nothing is fitted or stored. Runs over the
    /// whole track: a second or so.
    ///
    /// The onset events include the hats. Neither an event's level in the
    /// kick band nor its rise *ratio* tells them apart - the bass fills that
    /// band, and a hat over a quiet intro rises from almost nothing. The
    /// absolute rise does: a kick climbs far in the band, a hat hardly moves
    /// it. An event is kept when it rises by `kickRiseShare` of the rise the
    /// strongest tenth of events reach. At 0.4, on-grid events are kept at
    /// 66-100 % against 0-12 % off-grid. Quiet kicks - a filtered intro -
    /// lose their tick first.
    static func kicks(_ audio: AudioFrames, bpm: Double) -> [Double] {
        let mono = audio.monoMix()
        let kick = KickEnvelope(mono)
        let events = onsetEvents(flux: spectralFlux(mono), kick: kick, period: 60 / max(bpm, 1))
        let threshold = kickThreshold(events, kick)
        guard threshold > 0 else { return [] }
        return events.filter { kick.rise(at: $0.time) >= threshold }.map(\.time)
    }

    static let kickRiseShare: Float = 0.4

    /// The events that count as kicks (`kickThreshold`), which is what the
    /// grid is fitted to - or all of them, if fewer than 16 do.
    static func kickEvents(_ events: [Event], _ kick: KickEnvelope) -> [Event] {
        let threshold = kickThreshold(events, kick)
        let kicks = events.filter { kick.rise(at: $0.time) >= threshold }
        return kicks.count >= 16 ? kicks : events
    }

    /// The rise an event needs to count as a kick; 0 when there is nothing.
    static func kickThreshold(_ events: [Event], _ kick: KickEnvelope) -> Float {
        guard !events.isEmpty else { return 0 }
        let sorted = events.map { kick.rise(at: $0.time) }.sorted()
        return kickRiseShare * sorted[Int(Double(sorted.count - 1) * 0.9)]
    }

    // MARK: - 1. Spectral flux

    struct Flux {
        /// Onset strength per frame, local average removed, never negative.
        var broad: [Float]
        var low: [Float]
        /// Log energy in 12 bands per frame, frame-major - for the downbeat.
        var bands: [Float]
        static let bandCount = 12
        var frameCount: Int { broad.count }

        /// Time of frame `f`: the centre of the hop the frame adds.
        func time(_ frame: Int) -> Double {
            (Double(frame * TempoAnalyzer.hop) + Double(TempoAnalyzer.fftSize) - Double(TempoAnalyzer.hop) / 2)
                / TempoAnalyzer.sampleRate
        }
    }

    static func spectralFlux(_ mono: [Float]) -> Flux {
        let frames = max(0, (mono.count - fftSize) / hop + 1)
        let fft = RealFFT(size: fftSize)
        let bins = fft.binCount
        let binHz = sampleRate / Double(fftSize)
        let lowBins = Int((43 / binHz).rounded(.up))...Int(150 / binHz)
        let broadBins = 1..<Int(11_000 / binHz)
        // Twelve log-spaced bands from 60 Hz to 8 kHz.
        let edges = (0...Flux.bandCount).map { Int(60 * pow(8000 / 60, Double($0) / Double(Flux.bandCount)) / binHz) }

        var broad = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var bands = [Float](repeating: 0, count: frames * Flux.bandCount)
        var magnitude = [Float](repeating: 0, count: bins)
        var current = [Float](repeating: 0, count: bins)
        var previous = [Float](repeating: 0, count: bins)
        var rise = [Float](repeating: 0, count: bins)
        var count = Int32(bins)
        var zero: Float = 0
        var compression: Float = 1000

        mono.withUnsafeBufferPointer { input in
            for f in 0..<frames {
                magnitude.withUnsafeMutableBufferPointer { fft.magnitudes(of: input.baseAddress! + f * hop, into: $0.baseAddress!) }
                // log(1 + C·|X|): compresses the dynamic range so a quiet hat
                // and a loud kick both register as the attacks they are.
                vDSP_vsmul(magnitude, 1, &compression, &current, 1, vDSP_Length(bins))
                vvlog1pf(&current, current, &count)
                vDSP_vsub(previous, 1, current, 1, &rise, 1, vDSP_Length(bins))
                vDSP_vthres(rise, 1, &zero, &rise, 1, vDSP_Length(bins))
                if f > 0 {
                    broad[f] = rise[broadBins].reduce(0, +)
                    low[f] = rise[lowBins].reduce(0, +)
                }
                for band in 0..<Flux.bandCount {
                    let range = max(1, edges[band])..<max(edges[band] + 1, edges[band + 1])
                    var energy: Float = 0
                    for bin in range { energy += magnitude[bin] * magnitude[bin] }
                    bands[f * Flux.bandCount + band] = log10(1e-9 + energy)
                }
                swap(&previous, &current)
            }
        }
        return Flux(broad: removeLocalMean(broad), low: removeLocalMean(low), bands: bands)
    }

    /// Subtracts a one-second moving average and clips at zero, so a loud
    /// passage does not simply look like one long onset.
    private static func removeLocalMean(_ values: [Float]) -> [Float] {
        let radius = Int(frameRate / 2)
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for i in values.indices { prefix[i + 1] = prefix[i] + Double(values[i]) }
        return values.indices.map { i in
            let a = max(0, i - radius), b = min(values.count, i + radius + 1)
            let mean = (prefix[b] - prefix[a]) / Double(b - a)
            return max(0, values[i] - Float(mean))
        }
    }

    // MARK: - 2. Rough period

    /// Relative preference for a tempo when the autocorrelation cannot tell
    /// two octaves apart. A broad bell centred on 125 BPM with a standard
    /// deviation of one octave: it barely changes a clear winner, and in a
    /// near-tie it sides with the tempo most dance music is written at.
    static func octavePreference(_ bpm: Double) -> Double {
        let octaves = log2(bpm / 125)
        return exp(-0.5 * octaves * octaves)
    }

    /// Autocorrelation of the combined onset strength, in frames of lag.
    struct OnsetCorrelation {
        var values: [Double]

        init(_ flux: Flux, longestLag: Int) {
            let n = flux.frameCount
            let broadPeak = max(flux.broad.max() ?? 0, 1e-9)
            let lowPeak = max(flux.low.max() ?? 0, 1e-9)
            let onset = (0..<n).map { flux.broad[$0] / broadPeak + flux.low[$0] / lowPeak }
            let longest = max(1, min(longestLag, n - 1))
            var correlation = [Double](repeating: 0, count: longest + 1)
            onset.withUnsafeBufferPointer { o in
                for lag in 1...longest where lag < n {
                    var sum: Float = 0
                    vDSP_dotpr(o.baseAddress!, 1, o.baseAddress! + lag, 1, &sum, vDSP_Length(n - lag))
                    correlation[lag] = Double(sum) / Double(n - lag)
                }
            }
            values = correlation
        }

        /// Linearly interpolated between whole frames.
        func at(_ lag: Double) -> Double {
            let i = Int(lag.rounded(.down))
            guard i >= 0, i + 1 < values.count else { return 0 }
            let fraction = lag - Double(i)
            return values[i] * (1 - fraction) + values[i + 1] * fraction
        }
    }

    /// Lag step of the rough-period search, in frames.
    ///
    /// Whole-frame steps read the two- and four-beat terms at whole
    /// multiples, so a beat of 66.7 frames (90 BPM) was scored at 67, 134
    /// and 268 - the four-beat term a frame and a half beside its narrow
    /// peak - while half the beat, 33.3, was scored at 33, 66 and 132, all
    /// within a frame. A clear 90 then lost to 180. Quarter-frame lags read
    /// between frames give 26 of 30 hand-set tempos right or within 1 %,
    /// against 19. Steps of 0.1 score the same; whole frames do not.
    static let lagStep = 0.25

    static func roughPeriod(_ flux: Flux, hint: Double?) throws -> Double {
        let n = flux.frameCount
        let range = hint.map { ($0 * 0.92)...($0 * 1.08) } ?? detectionRange
        let minLag = 60 / range.upperBound * frameRate
        let maxLag = 60 / range.lowerBound * frameRate
        guard Double(n) > maxLag * 8 else { throw Failure(reason: "The track is too short to find a tempo in.") }

        // Autocorrelation up to four times the longest lag, for the
        // harmonic terms below.
        let correlation = OnsetCorrelation(flux, longestLag: Int(maxLag.rounded(.up)) * 4 + 2)
        // A beat period also correlates at two and four beats; counting
        // those favours the period over an accidental half-beat match.
        func score(_ lag: Double) -> Double {
            (correlation.at(lag) + 0.5 * correlation.at(lag * 2) + 0.25 * correlation.at(lag * 4))
                * (hint == nil ? octavePreference(60 * frameRate / lag) : 1)
        }
        let steps = Int(((maxLag - minLag) / lagStep).rounded(.down))
        var best = 0
        var bestScore = -Double.infinity
        for step in 0...steps {
            let s = score(minLag + Double(step) * lagStep)
            if s > bestScore { bestScore = s; best = step }
        }
        // Parabolic interpolation between neighbouring steps.
        var lag = minLag + Double(best) * lagStep
        if best > 0 && best < steps {
            let a = score(lag - lagStep), b = bestScore, c = score(lag + lagStep)
            let denominator = a - 2 * b + c
            if denominator < 0 { lag += 0.5 * (a - c) / denominator * lagStep }
        }
        return lag / frameRate
    }

    // MARK: - 3. Onset events

    struct Event {
        var time: Double
        var weight: Double
    }

    /// The kick band's energy, sampled every millisecond. Where each kick
    /// actually starts is read from this.
    ///
    /// Every stage runs forwards and then backwards, which makes the whole
    /// envelope zero-phase: its rise sits on the attack, not a filter delay
    /// after it. The smoothing has to be a few milliseconds long, because a
    /// squared 50–150 Hz tone ripples at 100–300 Hz; a 1 ms one-way smoother
    /// let that ripple through, and the "steepest rise" then landed on a
    /// ripple 16 ms into the kick - measured, on every fixture.
    struct KickEnvelope {
        static let rate = 1000.0
        var values: [Float]

        init(_ mono: [Float]) {
            // RBJ low-pass at 150 Hz, Q 0.707, run forwards and backwards:
            // 24 dB/oct with no delay, enough to keep hats and snares out.
            let w = 2 * Double.pi * 150 / TempoAnalyzer.sampleRate
            let alpha = sin(w) / (2 * 0.7071)
            let a0 = 1 + alpha
            let section = (b0: Float((1 - cos(w)) / 2 / a0), b1: Float((1 - cos(w)) / a0),
                           b2: Float((1 - cos(w)) / 2 / a0), a1: Float(-2 * cos(w) / a0), a2: Float((1 - alpha) / a0))
            var signal = mono
            Self.biquad(&signal, section, reverse: false)
            Self.biquad(&signal, section, reverse: true)
            signal.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsq(buffer.baseAddress!, 1, buffer.baseAddress!, 1, vDSP_Length(buffer.count))
            }
            // 3 ms each way.
            let smooth = Float(exp(-1 / (0.003 * TempoAnalyzer.sampleRate)))
            Self.onePole(&signal, smooth, reverse: false)
            Self.onePole(&signal, smooth, reverse: true)
            let step = TempoAnalyzer.sampleRate / Self.rate
            let count = Int(Double(mono.count) / step)
            values = (0..<count).map { signal[min(signal.count - 1, Int((Double($0) * step).rounded()))] }
        }

        private static func biquad(_ x: inout [Float],
                                   _ c: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float),
                                   reverse: Bool) {
            x.withUnsafeMutableBufferPointer { buffer in
                let n = buffer.count
                var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
                for j in 0..<n {
                    let i = reverse ? n - 1 - j : j
                    let input = buffer[i]
                    let y = c.b0 * input + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                    x2 = x1; x1 = input; y2 = y1; y1 = y
                    buffer[i] = y
                }
            }
        }

        private static func onePole(_ x: inout [Float], _ coefficient: Float, reverse: Bool) {
            x.withUnsafeMutableBufferPointer { buffer in
                let n = buffer.count
                var state: Float = 0
                for j in 0..<n {
                    let i = reverse ? n - 1 - j : j
                    state = buffer[i] + coefficient * (state - buffer[i])
                    buffer[i] = state
                }
            }
        }

        func peak(from start: Double, to end: Double) -> Float {
            let a = max(0, Int(start * Self.rate)), b = min(values.count, Int(end * Self.rate) + 1)
            return a < b ? values[a..<b].max() ?? 0 : 0
        }

        /// How far the envelope climbs at a time: its peak in the 15 ms from
        /// it, above its lowest point in the 40 ms before.
        func rise(at time: Double) -> Float {
            guard !values.isEmpty else { return 0 }
            let i = min(values.count - 1, max(0, Int(time * Self.rate)))
            let low = values[max(0, i - 40)...i].min() ?? 0
            let high = values[i...min(values.count - 1, i + 15)].max() ?? 0
            return max(0, high - low)
        }
    }

    /// Where the timing rule below lands relative to a kick's first sample.
    /// Measured on the harness's synthetic kick with nothing else playing:
    /// 1.30 ms *early*, the same on every kick - the zero-phase smoothing
    /// spreads the rise to both sides of the attack. Subtracted, so grid
    /// lines sit on the attack itself.
    static let attackLatency = -0.0013

    static func onsetEvents(flux: Flux, kick: KickEnvelope, period: Double) -> [Event] {
        // Kick-band peaks when the track has a kick; the whole spectrum when
        // the low band is too sparse to carry a grid.
        var events = peaks(flux.low, flux: flux, period: period)
        if events.count < 32 {
            events = peaks(flux.broad, flux: flux, period: period)
        }
        // Re-time each on the 1 ms envelope; the flux frame alone reads
        // about 3 ms late and is only good to its 10 ms frame.
        //
        // Two-stage because of the bass: a note held under the kick sits in
        // the same band and beats against it, so the envelope's biggest
        // jumps come 11-21 ms *into* the kick. "Steepest rise" followed
        // those (−0.6 ms bare, up to +21.5 ms with the bass); "30 % of the
        // way to the peak" still moved with the interference (−2 … +6 ms).
        // The attack itself does not move:
        //
        //   1. the rise starts where the envelope first passes 15 % of the
        //      swing from the floor before the kick to the local peak;
        //   2. the attack peak is the highest point in the 6 ms after that;
        //   3. the onset is where the envelope passes half way from the
        //      floor to that peak, interpolated between milliseconds.
        //
        // Measured: −1.30 ms bare, −2.3 … +0.2 ms under the bass, with an
        // occasional +4 the grid fit's trimming absorbs.
        let v = kick.values
        let rate = KickEnvelope.rate
        return events.compactMap { event in
            let low = max(1, Int((event.time - 0.060) * rate))
            let first = max(low, Int((event.time - 0.050) * rate))
            let last = min(v.count - 1, Int((event.time + 0.060) * rate))
            guard last - first > 8 else { return nil }
            let peakIndex = (first...last).max { v[$0] < v[$1] }!
            let floorIndex = (low...peakIndex).min { v[$0] < v[$1] }!
            let floor = v[floorIndex]
            let swing = v[peakIndex] - floor
            guard swing > 0 else { return event }
            var riseStart = floorIndex
            while riseStart < peakIndex && v[riseStart] < floor + 0.15 * swing { riseStart += 1 }
            let attackEnd = min(v.count - 1, riseStart + 6)
            let attackPeak = v[riseStart...attackEnd].max()!
            let half = floor + 0.5 * (attackPeak - floor)
            var i = floorIndex
            while i < attackEnd && v[i] < half { i += 1 }
            let step = v[i] - v[max(i - 1, 0)]
            let fraction = i > floorIndex && step > 0 ? Double((half - v[i - 1]) / step) : 0
            let time = (Double(i - 1) + fraction) / rate - attackLatency
            return Event(time: time, weight: Double(v[peakIndex]).squareRoot())
        }
    }

    /// Local maxima above one and a half times their neighbourhood's mean,
    /// at least 40 % of a beat apart (the stronger wins).
    private static func peaks(_ values: [Float], flux: Flux, period: Double) -> [Event] {
        let radius = Int(frameRate)
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for i in values.indices { prefix[i + 1] = prefix[i] + Double(values[i]) }
        let floor = Double(values.max() ?? 0) * 0.05
        let spacing = Int(period * 0.4 * frameRate)
        var result: [(frame: Int, value: Float)] = []
        guard values.count > 6 else { return [] }
        for i in 3..<(values.count - 3) {
            let v = values[i]
            guard v > 0, Double(v) > floor else { continue }
            guard v >= values[i - 1], v >= values[i - 2], v >= values[i - 3],
                  v > values[i + 1], v >= values[i + 2], v >= values[i + 3] else { continue }
            let a = max(0, i - radius), b = min(values.count, i + radius + 1)
            let mean = (prefix[b] - prefix[a]) / Double(b - a)
            guard Double(v) > 1.5 * mean else { continue }
            if let last = result.last, i - last.frame < spacing {
                if v > last.value { result[result.count - 1] = (i, v) }
                continue
            }
            result.append((i, v))
        }
        return result.map { Event(time: flux.time($0.frame), weight: Double($0.value)) }
    }

    // MARK: - 4–5. The grid

    struct Grid {
        var period: Double
        /// Time of beat index 0; any beat, not necessarily a downbeat.
        var phase: Double
        /// 0…1: how well the events line up at this period (1 = all on it).
        var coherence = 0.0
        var matched = 0
        var residual = 0.0

        func time(ofBeat k: Int) -> Double { phase + Double(k) * period }

        /// How well the grid fits: share of events on it, times how tightly.
        func confidence(eventsInRange: Int) -> Double {
            guard eventsInRange > 0 else { return 0 }
            let coverage = min(1, Double(matched) / Double(eventsInRange))
            let tightness = max(0, 1 - residual / 0.020)
            return coverage * 0.6 + tightness * 0.4
        }
    }

    /// The period near the rough one at which the events line up best. The
    /// octave is the rough period's; nothing here second-guesses it.
    ///
    /// Two starting phases come back, because neither is always right: the
    /// phase-vector mean (`meanPhase`) is dragged towards any second cluster
    /// of events, and the densest cluster (`densestPhase`) is sometimes not
    /// the kicks. `bestFit` fits from both and keeps the one landing on more
    /// kick.
    ///
    /// With `halfBeats` the search also scores half the period. Where the
    /// kicks fall on every half-beat - 174 read as 87 - the plain sum
    /// cancels (86.21 on the fixture, 132 ms off) and the half-period term
    /// holds it (87.000, 0.3 ms). Elsewhere it can pull towards the hats, so
    /// it is one start among several, not the rule.
    static func coherentGrid(_ events: [Event], near rough: Double, halfBeats: Bool = false)
        -> (grid: Grid, meanPhase: Double)
    {
        func coherence(_ period: Double) -> (length: Double, angle: Double) {
            var re = 0.0, im = 0.0
            let k = 2 * Double.pi / period
            for event in events {
                re += event.weight * cos(k * event.time)
                im += event.weight * sin(k * event.time)
            }
            return ((re * re + im * im).squareRoot(), atan2(im, re))
        }
        // ±1 % around the rough period, in 0.02 % steps, then golden-section
        // refinement between the neighbours of the best step. (It was ±4 %
        // while the rough period came from whole-frame lags; with the finer
        // rough period a wider window only let the search wander onto a
        // neighbouring peak - 91.7 for a track at 89.85, measured.)
        func score(_ period: Double) -> Double {
            coherence(period).length + (halfBeats ? coherence(period / 2).length : 0)
        }
        var best = rough
        var bestLength = -1.0
        let step = 0.0002
        for i in -50...50 {
            let period = rough * (1 + Double(i) * step)
            let length = score(period)
            if length > bestLength { bestLength = length; best = period }
        }
        var a = best * (1 - step), b = best * (1 + step)
        let ratio = (5.0.squareRoot() - 1) / 2
        for _ in 0..<40 {
            let c = b - ratio * (b - a), d = a + ratio * (b - a)
            if score(c) > score(d) { b = d } else { a = c }
        }
        let period = (a + b) / 2
        let result = coherence(period)
        let total = events.reduce(0) { $0 + $1.weight }
        var mean = result.angle / (2 * Double.pi) * period
        mean = mean.truncatingRemainder(dividingBy: period)
        if mean < 0 { mean += period }
        let grid = Grid(period: period, phase: densestPhase(events, period: period),
                        coherence: total > 0 ? result.length / total : 0)
        return (grid, mean)
    }

    /// The best grid near the rough period: fitted from each starting grid
    /// `coherentGrid` offers, plus one from where the kicks cluster, and
    /// kept by how many kicks it lands on - the events `kicks` would tick in
    /// the beatgrid editor, within `fitTolerance` of a line. Their summed
    /// rise breaks a tie, then the tighter fit.
    ///
    /// Counting all matched events chose the off-beat on three tracks: hats
    /// and bass notes outnumber the kicks. Summing the rise of all matched
    /// events still left one off-beat ahead (39.8 against 38.8). Without a
    /// kick envelope - the harness's bare events - every event counts, by
    /// its weight.
    static func bestFit(_ events: [Event], near rough: Double, kick: KickEnvelope? = nil) -> Grid {
        let rises = kick.map { envelope in events.map { envelope.rise(at: $0.time) } }
        let threshold = kick.map { kickThreshold(events, $0) } ?? 0
        var index: [Double: Int] = [:]
        for (i, event) in events.enumerated() { index[event.time] = i }

        var starts: [Grid] = []
        for halfBeats in [false, true] {
            let start = coherentGrid(events, near: rough, halfBeats: halfBeats)
            var fromMean = start.grid
            fromMean.phase = start.meanPhase
            starts += [start.grid, fromMean]
            if let rises, !halfBeats {
                var fromKicks = start.grid
                let kickEvents = zip(events, rises).map { Event(time: $0.time, weight: Double($1)) }
                fromKicks.phase = densestPhase(kickEvents, period: start.grid.period)
                starts.append(fromKicks)
            }
        }
        typealias Score = (kicks: Double, rise: Double, residual: Double)
        func better(_ a: Score, than b: Score) -> Bool {
            if a.kicks != b.kicks { return a.kicks > b.kicks }
            if a.rise != b.rise { return a.rise > b.rise }
            return a.residual < b.residual
        }
        // The period and the starting phases come from all events; the
        // line itself is fitted through the kicks alone.
        let fitEvents = kick.map { kickEvents(events, $0) } ?? events
        var best: (grid: Grid, score: Score)?
        for start in starts {
            let fitted = fitGrid(fitEvents, start)
            var score: Score = (0, 0, fitted.residual)
            for match in nearestEvents(events, fitted, tolerance: fitTolerance).values {
                if let rises, let i = index[match.time] {
                    if rises[i] >= threshold { score.kicks += 1 }
                    score.rise += Double(rises[i])
                } else {
                    score.kicks += match.weight
                }
            }
            if let current = best, !better(score, than: current.score) { continue }
            best = (fitted, score)
        }
        return best!.grid
    }

    /// Where in the beat most of the events' weight falls, in seconds from
    /// a multiple of `period`.
    ///
    /// The phase-vector sum gives the *mean* phase, and a second cluster
    /// pulls the mean towards itself: on a harness fixture at 96 BPM the
    /// kicks (weight 0.55) and a bass onset a third of a beat after each
    /// (weight 0.2) averaged to 67 ms beside the kicks, outside even the
    /// first 50 ms round of `fitGrid`, which then matched nothing and
    /// returned the rough grid unchanged. The densest point of the weighted
    /// phase histogram is the kicks' phase whatever else plays, and is taken
    /// to a millisecond by the weighted mean of the events within 15 ms of it.
    static func densestPhase(_ events: [Event], period: Double) -> Double {
        let binWidth = 0.001
        let bins = max(1, Int((period / binWidth).rounded()))
        var histogram = [Double](repeating: 0, count: bins)
        func phase(_ time: Double) -> Double {
            let p = time.truncatingRemainder(dividingBy: period)
            return p < 0 ? p + period : p
        }
        for event in events {
            histogram[min(bins - 1, Int(phase(event.time) / binWidth))] += event.weight
        }
        // Triangular kernel, 15 ms each side, around the circle.
        let radius = 15
        var bestBin = 0
        var bestDensity = -1.0
        for bin in 0..<bins {
            var density = 0.0
            for offset in -radius...radius {
                let index = ((bin + offset) % bins + bins) % bins
                density += histogram[index] * Double(radius + 1 - abs(offset))
            }
            if density > bestDensity { bestDensity = density; bestBin = bin }
        }
        let centre = (Double(bestBin) + 0.5) * binWidth
        var sum = 0.0, weight = 0.0
        for event in events {
            var offset = phase(event.time) - centre
            if offset > period / 2 { offset -= period }
            if offset < -period / 2 { offset += period }
            guard abs(offset) <= Double(radius) * binWidth else { continue }
            sum += event.weight * offset
            weight += event.weight
        }
        return phase(centre + (weight > 0 ? sum / weight : 0))
    }

    typealias Matches = [Int: (time: Double, weight: Double, error: Double)]

    /// The nearest event to each beat of `grid`, within `tolerance` seconds.
    static func nearestEvents(_ events: [Event], _ grid: Grid, tolerance: Double) -> Matches {
        var chosen: Matches = [:]
        for event in events {
            let k = Int(((event.time - grid.phase) / grid.period).rounded())
            let error = event.time - grid.time(ofBeat: k)
            guard abs(error) <= tolerance else { continue }
            if let existing = chosen[k], abs(existing.error) <= abs(error) { continue }
            chosen[k] = (event.time, event.weight, error)
        }
        return chosen
    }

    /// Weighted RMS distance of the matched events from their beats.
    static func residual(_ chosen: Matches, _ grid: Grid) -> Double {
        var squared = 0.0, sw = 0.0
        for (k, e) in chosen {
            let r = e.time - grid.time(ofBeat: k)
            squared += e.weight * r * r
            sw += e.weight
        }
        return sw > 0 ? (squared / sw).squareRoot() : 0
    }

    static let fitTolerance = 0.018

    static func fitGrid(_ events: [Event], _ start: Grid) -> Grid {
        var grid = start
        for tolerance in [0.050, 0.035, 0.025, fitTolerance, fitTolerance] {
            let chosen = nearestEvents(events, grid, tolerance: tolerance)
            guard chosen.count >= 16 else { break }
            var sw = 0.0, sk = 0.0, st = 0.0
            for (k, e) in chosen { sw += e.weight; sk += e.weight * Double(k); st += e.weight * e.time }
            let kMean = sk / sw, tMean = st / sw
            var covariance = 0.0, variance = 0.0
            for (k, e) in chosen {
                covariance += e.weight * (Double(k) - kMean) * (e.time - tMean)
                variance += e.weight * (Double(k) - kMean) * (Double(k) - kMean)
            }
            guard variance > 0 else { break }
            let period = covariance / variance
            let phase = tMean - period * kMean
            var fitted = Grid(period: period, phase: phase, coherence: grid.coherence,
                              matched: chosen.count)
            fitted.residual = residual(chosen, fitted)
            grid = fitted
        }
        return rebased(grid)
    }

    /// The same grid with its phase on the first beat at or after zero.
    static func rebased(_ grid: Grid) -> Grid {
        var grid = grid
        let shift = (-grid.phase / grid.period).rounded(.up)
        grid.phase += shift * grid.period
        return grid
    }

    // MARK: - 5b. Round tempos

    /// How far a rounded tempo may pull the grid off the fitted one, at
    /// either end of the stretch the events cover.
    static let roundingDrift = 0.010

    /// Snaps the tempo to a whole BPM, or failing that a half, when the
    /// events allow it.
    ///
    /// Most dance music is made against a clock set to a round tempo, and a
    /// fit over a few hundred rough events lands a few thousandths beside
    /// it: 126.953 for a track at 127. A rounded tempo is taken only when:
    ///
    ///  - pivoting the fitted line to it, about the middle of the events,
    ///    moves neither end by more than `roundingDrift`, and
    ///  - with its phase fitted again, it matches as many events (to 2 %)
    ///    and fits them as tightly (to 1 ms RMS) as the fitted tempo.
    ///
    /// A live drummer or a sampled loop at an odd tempo fails the first test
    /// on any track of normal length, and keeps its measured tempo.
    static func roundedTempo(_ events: [Event], _ grid: Grid) -> Grid {
        let chosen = nearestEvents(events, grid, tolerance: fitTolerance)
        guard let first = chosen.keys.min(), let last = chosen.keys.max(), last > first else { return grid }
        let span = Double(last - first)
        let bpm = 60 / grid.period
        let before = (matched: chosen.count, residual: residual(chosen, grid))
        for step in [1.0, 0.5] {
            let rounded = (bpm / step).rounded() * step
            let period = 60 / rounded
            guard abs(period - grid.period) * span / 2 <= roundingDrift else { continue }
            // The phase that fits the same events best at this period.
            var sw = 0.0, sum = 0.0
            for (k, e) in chosen {
                sw += e.weight
                sum += e.weight * (e.time - Double(k) * period)
            }
            var candidate = Grid(period: period, phase: sum / sw, coherence: grid.coherence)
            let after = nearestEvents(events, candidate, tolerance: fitTolerance)
            candidate.matched = after.count
            candidate.residual = residual(after, candidate)
            guard Double(after.count) >= 0.98 * Double(before.matched),
                  candidate.residual <= before.residual + 0.001 else { continue }
            return rebased(candidate)
        }
        return grid
    }

    // MARK: - 6. Downbeat

    static func firstDownbeat(grid: Grid, kick: KickEnvelope, flux: Flux, duration: Double)
        -> (time: Double, confidence: Double)
    {
        let beatCount = max(0, Int((duration - grid.phase) / grid.period))
        guard beatCount > 16 else { return (grid.phase, 0) }
        let strength = (0..<beatCount).map { k -> Float in
            let t = grid.time(ofBeat: k)
            return kick.peak(from: t - 0.1 * grid.period, to: t + 0.25 * grid.period)
        }
        // The groove starts at the first beat from which the kick keeps
        // playing: six of the next eight beats at 30 % of a typical kick.
        let reference = strength.sorted()[Int(Double(beatCount - 1) * 0.8)]
        let threshold = reference * 0.3
        var groove = 0
        for k in 0..<max(1, beatCount - 8) {
            let playing = strength[k..<(k + 8)].filter { $0 >= threshold }.count
            if strength[k] >= threshold && playing >= 6 { groove = k; break }
        }

        // Beat-synchronous band energy; novelty is how much it changed from
        // the previous beat. Changes cluster on the one.
        func bandVector(_ k: Int) -> [Float] {
            let startFrame = max(0, Int((grid.time(ofBeat: k) * frameRate).rounded()) - 2)
            let endFrame = min(flux.frameCount, startFrame + max(1, Int(grid.period * frameRate)))
            var vector = [Float](repeating: 0, count: Flux.bandCount)
            guard startFrame < endFrame else { return vector }
            for f in startFrame..<endFrame {
                for b in 0..<Flux.bandCount { vector[b] += flux.bands[f * Flux.bandCount + b] }
            }
            let n = Float(endFrame - startFrame)
            return vector.map { $0 / n }
        }
        var scores = [Double](repeating: 0, count: 4)
        var counts = [Double](repeating: 0, count: 4)
        var previous = bandVector(groove)
        if groove + 1 < beatCount {
            for k in (groove + 1)..<beatCount {
                let current = bandVector(k)
                var change: Float = 0
                for b in 0..<Flux.bandCount { change += abs(current[b] - previous[b]) }
                scores[(k - groove) % 4] += Double(change)
                counts[(k - groove) % 4] += 1
                previous = current
            }
        }
        let means = (0..<4).map { counts[$0] > 0 ? scores[$0] / counts[$0] : 0 }
        let ranked = means.enumerated().sorted { $0.element > $1.element }
        let separation = ranked[0].element > 0 ? (ranked[0].element - ranked[1].element) / ranked[0].element : 0
        // Without a clear winner the groove's own first beat is the better
        // bet: intros and drops begin on bar lines.
        let phase = separation >= 0.1 ? ranked[0].offset : 0
        // Nearest beat of that phase to the groove start, the earlier on a
        // tie, and never before the start of the file.
        var index = groove + (phase <= 2 ? phase : phase - 4)
        if phase == 2 { index = groove - 2 }
        while index < 0 { index += 4 }
        return (grid.time(ofBeat: index), min(1, separation * 2))
    }
}
