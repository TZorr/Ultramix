//
//  MixRenderer.swift
//  Ultramix
//
//  Turns a render plan into stereo samples: clips through the stretcher, each
//  lane through its filter, volume and pan, the lanes summed, the sum through
//  a safety limiter. One renderer for playback and bounce, so what is bounced
//  is what was heard. It never allocates after init and never blocks.
//
//  Block-size independence: everything that is not per-sample runs on a
//  control grid fixed to absolute frame numbers - every 32nd frame of the mix,
//  not block boundaries. Automation is evaluated at grid points and
//  interpolated; filter smoothing and coefficients step at grid points. The
//  harness renders the same range in several block sizes and compares bit for
//  bit.
//
//  What carries state is the lane filters and the limiter, as any IIR filter
//  must; a seek resets them.
//
//  The lane knobs come last in a lane and only when `knobs` is set, which
//  playback does and a bounce does not. They are also the one thing here that
//  is not block-size independent: read once per block, as they are when they
//  move.
//

import Foundation

nonisolated final class MixRenderer {
    static let controlInterval = 32
    static let maxBlock = 4096
    /// The safety limiter's ceiling, −0.18 dBFS: under full scale with room
    /// for the DAC's own reconstruction overshoot.
    static let ceiling: Float = 0.98

    private let stretcher = Stretcher()
    private let laneLeft: [UnsafeMutablePointer<Float>]
    private let laneRight: [UnsafeMutablePointer<Float>]
    private var lanes: [LaneState]
    /// A bus per lane and stem, `lane * 4 + stem`: stems with automation of
    /// their own, through their own curves, then into their lane.
    private let partLeft: [UnsafeMutablePointer<Float>]
    private let partRight: [UnsafeMutablePointer<Float>]
    private var parts: [LaneState]
    private static let partCount = Clip.laneCount * Stem.allCases.count

    private var limiterGain: Float = 1
    private let attack: Float
    private let release: Float

    /// Output level for the meters: instant attack, 0.85 s release.
    private(set) var meterLeft: Float = 0
    private(set) var meterRight: Float = 0
    /// Set when the limiter could not hold the ceiling and the hard clamp
    /// had to cut. Cleared by whoever reads it.
    var overload = false
    /// Short-term loudness of what leaves the renderer, after the limiter.
    private let loudness = ShortTermLoudness()
    var shortTermLUFS: Double? { loudness.lufs }

    /// Off for a bounce through the mastering limiter: the safety limiter's
    /// clamp at −0.18 dBFS would otherwise cut the transients before the
    /// mastering limiter ever saw them.
    var safetyLimiterEnabled = true

    /// The lane knobs, for playback. Nil - a bounce, the harness - renders
    /// the lanes exactly as it did before there were knobs.
    var knobs: LaneKnobValues?

    /// Exposed for the harness.
    var usesStretchMemo: Bool {
        get { stretcher.usesMemo }
        set { stretcher.usesMemo = newValue }
    }

    init() {
        laneLeft = (0..<Clip.laneCount).map { _ in .allocate(capacity: Self.maxBlock) }
        laneRight = (0..<Clip.laneCount).map { _ in .allocate(capacity: Self.maxBlock) }
        lanes = (0..<Clip.laneCount).map { _ in LaneState() }
        partLeft = (0..<Self.partCount).map { _ in .allocate(capacity: Self.maxBlock) }
        partRight = (0..<Self.partCount).map { _ in .allocate(capacity: Self.maxBlock) }
        parts = (0..<Self.partCount).map { _ in LaneState() }
        let rate = Float(AudioFrames.sampleRate)
        attack = 1 - exp(-1 / (0.002 * rate))
        release = 1 - exp(-1 / (0.120 * rate))
    }

    deinit {
        laneLeft.forEach { $0.deallocate() }
        laneRight.forEach { $0.deallocate() }
        partLeft.forEach { $0.deallocate() }
        partRight.forEach { $0.deallocate() }
    }

    /// Forget filter and limiter history - after a seek, before a bounce.
    /// Drops the meters to silence - while paused, nothing is playing, and a
    /// meter frozen at the last level would say otherwise.
    func clearMeters() {
        meterLeft = 0
        meterRight = 0
        loudness.reset()
    }

    func reset() {
        for i in lanes.indices { lanes[i] = LaneState() }
        for i in parts.indices { parts[i] = LaneState() }
        limiterGain = 1
        meterLeft = 0
        meterRight = 0
        loudness.reset()
        overload = false
    }

    /// Renders timeline frames `from ..< from + count` into `left`/`right`.
    ///
    /// - Parameter laneMask: bit n set = lane n audible (mute and solo
    ///   resolved by the caller). A silent lane's clips are not rendered at
    ///   all; because the stretcher is a function of position, they resume
    ///   exactly where they should when the lane comes back.
    func render(plan: RenderPlan, laneMask: Int, from: Int, count: Int,
                left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < count {
            let n = min(Self.maxBlock, count - done)
            renderBlock(plan: plan, laneMask: laneMask, from: from + done, count: n,
                        left: left + done, right: right + done)
            done += n
        }
    }

    private func renderBlock(plan: RenderPlan, laneMask: Int, from: Int, count: Int,
                             left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        for lane in 0..<Clip.laneCount {
            laneLeft[lane].update(repeating: 0, count: count)
            laneRight[lane].update(repeating: 0, count: count)
        }
        let stems = Stem.allCases.count
        for bus in 0..<Self.partCount where plan.partBuses & (1 << bus) != 0 {
            partLeft[bus].update(repeating: 0, count: count)
            partRight[bus].update(repeating: 0, count: count)
        }
        for index in plan.segments.indices {
            let segment = plan.segments[index]
            guard laneMask & (1 << segment.lane) != 0,
                  segment.endFrame > from, segment.startFrame < from + count else { continue }
            let bus = segment.part.map { segment.lane * stems + $0.rawValue }
            stretcher.render(segment, tempo: plan.tempo, from: from, count: count,
                             left: bus.map { partLeft[$0] } ?? laneLeft[segment.lane],
                             right: bus.map { partRight[$0] } ?? laneRight[segment.lane],
                             memo: &plan.memos[index])
        }
        // Every bus the plan has, on every block, sounding or not: its
        // filters then run the same whatever the block size.
        for bus in 0..<Self.partCount where plan.partBuses & (1 << bus) != 0 && laneMask & (1 << (bus / stems)) != 0 {
            let lane = bus / stems
            parts[bus].process(plan: plan.partLanes[lane][bus % stems], tempo: plan.tempo, from: from, count: count,
                               left: partLeft[bus], right: partRight[bus],
                               outLeft: laneLeft[lane], outRight: laneRight[lane])
        }
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        let knobWord = knobs?.load()
        for lane in 0..<Clip.laneCount where laneMask & (1 << lane) != 0 {
            lanes[lane].process(plan: plan.lanes[lane], tempo: plan.tempo, from: from, count: count,
                                left: laneLeft[lane], right: laneRight[lane], outLeft: left, outRight: right,
                                knobs: knobWord.map { KnobTargets(word: $0, lane: lane) })
        }
        limit(left: left, right: right, count: count)
        loudness.process(left: left, right: right, count: count)
    }

    // MARK: - Safety limiter

    /// Stereo-linked: one gain for both channels, from the louder, so that
    /// limiting can never move the stereo image. Fast attack, slower
    /// release, then a hard clamp for whatever the attack was too slow for.
    private func limit(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        var gain = limiterGain
        var peakL: Float = 0, peakR: Float = 0
        let ceiling = Self.ceiling
        for i in 0..<count where !safetyLimiterEnabled {
            peakL = max(peakL, abs(left[i]))
            peakR = max(peakR, abs(right[i]))
        }
        for i in 0..<count where safetyLimiterEnabled {
            let peak = max(abs(left[i]), abs(right[i]))
            let target: Float = peak > ceiling ? ceiling / peak : 1
            gain += (target - gain) * (target < gain ? attack : release)
            var l = left[i] * gain
            var r = right[i] * gain
            if abs(l) > ceiling || abs(r) > ceiling || !l.isFinite || !r.isFinite {
                overload = true
                l = l.isFinite ? min(max(l, -ceiling), ceiling) : 0
                r = r.isFinite ? min(max(r, -ceiling), ceiling) : 0
            }
            left[i] = l
            right[i] = r
            peakL = max(peakL, abs(l))
            peakR = max(peakR, abs(r))
        }
        limiterGain = gain
        let decay = Float(exp(-Double(count) / (0.85 * AudioFrames.sampleRate)))
        meterLeft = max(peakL, meterLeft * decay)
        meterRight = max(peakR, meterRight * decay)
    }
}

// MARK: - Lane processing

/// One lane's filters and control state.
nonisolated private struct LaneState {
    /// The automation's low-pass and high-pass, as Biquad positions after
    /// smoothing (−1…0 and 0…+1). Two filters in series, since the one
    /// bipolar filter was split.
    var smoothed = (0.0, 0.0)
    var filters = (Biquad(), Biquad())
    /// Control values at the grid point `grid` and the one after it.
    var grid = Int.min
    var here = Control()
    var next = Control()

    struct Control {
        var left: Float = 0
        var right: Float = 0
        var lowPass = 0.0
        var highPass = 0.0
    }

    /// The knobs' own stage: a filter per knob, and their gains glided
    /// between grid points exactly like the automation's. Everything starts
    /// neutral, so after a seek a turned knob glides in over a few ms
    /// instead of clicking.
    var knobFilters = (Biquad(), Biquad())
    var knobSmoothed = (0.0, 0.0)
    var knobHere = (left: Float(1), right: Float(1))
    var knobNext = (left: Float(1), right: Float(1))

    static let smoothing = 1 - exp(-Double(MixRenderer.controlInterval) / (0.008 * AudioFrames.sampleRate))

    static func control(at frame: Int, plan: LanePlan, tempo: TempoMap) -> Control {
        let beat = tempo.beat(atSeconds: Double(frame) / AudioFrames.sampleRate)
        let gain = Automation.gain(dB: plan.volume.value(at: beat)) / plan.volumeReference
        // Balance for a stereo source: the centre is unity on both sides,
        // and turning away from a side lowers that side only, on an
        // equal-power curve.
        let theta = (min(max(plan.pan.value(at: beat), -1), 1) + 1) * Double.pi / 4
        let left = min(1, 2.0.squareRoot() * cos(theta))
        let right = min(1, 2.0.squareRoot() * sin(theta))
        return Control(left: Float(gain * left), right: Float(gain * right),
                       lowPass: AutomationKind.filterPosition(lowPass: plan.lowPass.value(at: beat)),
                       highPass: AutomationKind.filterPosition(highPass: plan.highPass.value(at: beat)))
    }

    mutating func process(plan: LanePlan, tempo: TempoMap, from: Int, count: Int,
                          left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                          outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>,
                          knobs: KnobTargets? = nil) {
        let interval = MixRenderer.controlInterval
        var i = 0
        while i < count {
            let frame = from + i
            let point = frame - ((frame % interval) + interval) % interval
            if point != grid {
                if point == grid + interval {
                    here = next
                } else {
                    here = Self.control(at: point, plan: plan, tempo: tempo)
                }
                next = Self.control(at: point + interval, plan: plan, tempo: tempo)
                grid = point
                // The filters move one smoothing step per grid point.
                smoothed.0 += (here.lowPass - smoothed.0) * Self.smoothing
                smoothed.1 += (here.highPass - smoothed.1) * Self.smoothing
                filters.0.design(position: smoothed.0)
                filters.1.design(position: smoothed.1)
                if let knobs { stepKnobs(knobs) }
            }
            let runEnd = min(count, i + (point + interval - frame))
            let span = Float(interval)
            if knobs != nil {
                // Separate from the loop below so that without knobs not one
                // operation changes - the bounce's bits are held to that.
                for j in i..<runEnd {
                    let t = Float(from + j - point) / span
                    var l = left[j]
                    var r = right[j]
                    filters.0.process(&l, &r)
                    filters.1.process(&l, &r)
                    knobFilters.0.process(&l, &r)
                    knobFilters.1.process(&l, &r)
                    let kl = knobHere.left + (knobNext.left - knobHere.left) * t
                    let kr = knobHere.right + (knobNext.right - knobHere.right) * t
                    outLeft[j] += l * (here.left + (next.left - here.left) * t) * kl
                    outRight[j] += r * (here.right + (next.right - here.right) * t) * kr
                }
                i = runEnd
                continue
            }
            for j in i..<runEnd {
                let t = Float(from + j - point) / span
                var l = left[j]
                var r = right[j]
                filters.0.process(&l, &r)
                filters.1.process(&l, &r)
                outLeft[j] += l * (here.left + (next.left - here.left) * t)
                outRight[j] += r * (here.right + (next.right - here.right) * t)
            }
            i = runEnd
        }
    }
}

nonisolated extension LaneState {
    /// One grid step of the knobs: the same 8 ms glide as the automation
    /// filter, for the filters and the gains alike.
    mutating func stepKnobs(_ knobs: KnobTargets) {
        knobSmoothed.0 += (knobs.filter.0 - knobSmoothed.0) * Self.smoothing
        knobSmoothed.1 += (knobs.filter.1 - knobSmoothed.1) * Self.smoothing
        knobFilters.0.design(position: knobSmoothed.0)
        knobFilters.1.design(position: knobSmoothed.1)
        let glide = Float(Self.smoothing)
        knobHere = knobNext
        knobNext.left += (knobs.left - knobNext.left) * glide
        knobNext.right += (knobs.right - knobNext.right) * glide
    }
}

/// What one lane's two knobs ask for, worked out once per block.
nonisolated struct KnobTargets {
    var filter: (Double, Double)
    var left: Float
    var right: Float

    init(word: UInt64, lane: Int) {
        let a = LaneKnobMath.unpack(word, slot: LaneKnobMath.slot(lane: lane, knob: 0))
        let b = LaneKnobMath.unpack(word, slot: LaneKnobMath.slot(lane: lane, knob: 1))
        filter = (LaneKnobMath.filterPosition(a), LaneKnobMath.filterPosition(b))
        let ga = LaneKnobMath.gains(a), gb = LaneKnobMath.gains(b)
        left = Float(ga.left * gb.left)
        right = Float(ga.right * gb.right)
    }
}

/// The lane filter: a 12 dB/oct high-pass for positive positions, a low-pass
/// for negative ones, faded in over the first tenth of the travel so that
/// leaving the centre is not a click.
nonisolated private struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var wet: Float = 0
    var makeup: Float = 1
    // Transposed direct form II state, per channel.
    var l1: Float = 0, l2: Float = 0, r1: Float = 0, r2: Float = 0

    mutating func design(position: Double) {
        let amount = abs(position)
        guard amount >= 0.001 else {
            wet = 0
            l1 = 0; l2 = 0; r1 = 0; r2 = 0
            return
        }
        // High-pass sweeps 50 Hz → 12 kHz, low-pass 18 kHz → 90 Hz, both
        // exponentially, so equal travel is an equal musical interval.
        let highPass = position > 0
        let cutoff = highPass ? 50 * pow(240, amount) : 18_000 * pow(1.0 / 200, amount)
        let w = 2 * Double.pi * min(cutoff, 0.45 * AudioFrames.sampleRate) / AudioFrames.sampleRate
        let alpha = sin(w) / (2 * 0.7071)
        let cosw = cos(w)
        let a0 = 1 + alpha
        if highPass {
            b0 = Float((1 + cosw) / 2 / a0); b1 = Float(-(1 + cosw) / a0); b2 = b0
        } else {
            b0 = Float((1 - cosw) / 2 / a0); b1 = Float((1 - cosw) / a0); b2 = b0
        }
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
        wet = Float(min(1, amount / 0.1))
        // A filtered track sounds quieter than its level says; a little
        // make-up keeps a sweep from reading as a fade.
        makeup = Float(pow(10, amount * (highPass ? 4.5 : 6) / 20))
    }

    @inline(__always)
    mutating func process(_ l: inout Float, _ r: inout Float) {
        guard wet > 0 else { return }
        let yl = b0 * l + l1
        l1 = b1 * l - a1 * yl + l2
        l2 = b2 * l - a2 * yl
        let yr = b0 * r + r1
        r1 = b1 * r - a1 * yr + r2
        r2 = b2 * r - a2 * yr
        l = (l + (yl - l) * wet) * makeup
        r = (r + (yr - r) * wet) * makeup
    }
}
