//
//  PlaybackEngine.swift
//  Ultramix
//
//  The audio device end: an AVAudioSourceNode whose render callback asks a
//  MixRenderer for samples, and the lock-free handshake with the main thread.
//
//  Everything the callback reads is an atomic, the render plan included. The
//  main thread publishes a plan by swapping the pointer; the callback
//  acknowledges each plan it renders with, and an old plan is let go of only
//  once the callback has moved past it. So no plan is freed on the audio
//  thread, and none while it is in use.
//
//  The playhead is the callback's own frame counter - there is no second clock
//  estimating where playback "should" be.
//

import Foundation
import Observation
@preconcurrency import AVFoundation
import Synchronization

/// The state shared with the render callback. Every property is either an
/// atomic or touched only by the callback.
nonisolated final class AudioCore: @unchecked Sendable {
    let renderer = MixRenderer()
    let playing = Atomic<Bool>(false)
    /// Next timeline frame the callback will render.
    let position = Atomic<Int>(0)
    /// A seek waiting for the callback; −1 when none.
    let seekTarget = Atomic<Int>(-1)
    let laneMask = Atomic<Int>(0b111)
    let plan = Atomic<UnsafeRawPointer?>(nil)
    /// Generation of the plan the callback last rendered with.
    let planInUse = Atomic<Int>(-1)
    let meterLeft = Atomic<UInt32>(0)
    let meterRight = Atomic<UInt32>(0)
    let overload = Atomic<Bool>(false)
    /// Short-term LUFS as Double bits; −∞ when silent or not playing.
    let meterShortTerm = Atomic<UInt64>((-Double.infinity).bitPattern)
    /// Stops by itself this far past the end of the mix.
    let endFrame = Atomic<Int>(Int.max)

    init() {
        // The lane knobs are heard here - in the mix and the live set - and
        // in no other renderer: not in a bounce, not in an audition.
        renderer.knobs = LaneKnobValues.shared
    }

    /// Built in a nonisolated context on purpose. With MainActor as the
    /// default isolation, a closure written inside a MainActor type is
    /// MainActor-isolated, and calling it on the audio thread would trip the
    /// runtime's isolation check.
    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frameCount)

            let seek = seekTarget.exchange(-1, ordering: .acquiringAndReleasing)
            if seek >= 0 {
                position.store(seek, ordering: .releasing)
                renderer.reset()
            }
            guard let raw = plan.load(ordering: .acquiring) else {
                left.update(repeating: 0, count: count)
                right.update(repeating: 0, count: count)
                isSilence.pointee = true
                return noErr
            }
            Unmanaged<RenderPlan>.fromOpaque(raw)._withUnsafeGuaranteedRef { plan in
                planInUse.store(plan.generation, ordering: .releasing)
                guard playing.load(ordering: .acquiring) else {
                    left.update(repeating: 0, count: count)
                    right.update(repeating: 0, count: count)
                    isSilence.pointee = true
                    renderer.clearMeters()
                    meterLeft.store(0, ordering: .relaxed)
                    meterRight.store(0, ordering: .relaxed)
                    meterShortTerm.store((-Double.infinity).bitPattern, ordering: .relaxed)
                    return
                }
                let from = position.load(ordering: .acquiring)
                renderer.render(plan: plan, laneMask: laneMask.load(ordering: .relaxed),
                                from: from, count: count, left: left, right: right)
                position.store(from + count, ordering: .releasing)
                meterLeft.store(renderer.meterLeft.bitPattern, ordering: .relaxed)
                meterRight.store(renderer.meterRight.bitPattern, ordering: .relaxed)
                meterShortTerm.store((renderer.shortTermLUFS ?? -.infinity).bitPattern, ordering: .relaxed)
                if renderer.overload {
                    overload.store(true, ordering: .relaxed)
                    renderer.overload = false
                }
                if from + count > endFrame.load(ordering: .relaxed) {
                    playing.store(false, ordering: .releasing)
                }
            }
            return noErr
        }
    }
}

@Observable
final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let core = AudioCore()
    private var sourceNode: AVAudioSourceNode?
    /// The current plan last; older ones wait here until the callback has
    /// moved on from them.
    private var plans: [RenderPlan] = []
    private var nextGeneration = 0
    /// Keeps the next ten seconds of every clip in memory (see ReadAhead).
    private let readAhead = ReadAhead()
    private var router: OutputRouter?

    private(set) var failure: String?

    var isPlaying: Bool { core.playing.load(ordering: .acquiring) }
    var positionFrame: Int { core.position.load(ordering: .acquiring) }
    /// How long a sample takes from the callback to the speaker: what is
    /// heard lies this far behind `positionFrame`. The Rec button places a
    /// knob's movement where it was heard, not where the callback was.
    var outputLatency: Double { engine.outputNode.presentationLatency }
    var currentPlan: RenderPlan? { plans.last }

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioFrames.sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format, renderBlock: core.makeRenderBlock())
        engine.attach(node)
        // Non-interleaved: AVAudioEngine refuses interleaved connections with
        // an exception rather than an error.
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        // The main output (see AudioRouting); the router starts the engine.
        router = OutputRouter(engine: engine, role: .main)
        failure = router?.failure
    }

    /// Stops the audio device and lets go of every plan - and with the plans,
    /// the mapped audio they read. Once the device is stopped the callback
    /// cannot run, so releasing the plans here is safe. The engine plays
    /// nothing afterwards; a new working directory gets a new one.
    func shutdown() {
        core.playing.store(false, ordering: .releasing)
        router?.shutdown()
        engine.stop()
        readAhead.set(nil)
        core.plan.store(nil, ordering: .releasing)
        plans.removeAll()
    }

    /// Hands a new plan to the callback.
    func install(_ build: (Int) -> RenderPlan) {
        let plan = build(nextGeneration)
        nextGeneration += 1
        plans.append(plan)
        core.plan.store(UnsafeRawPointer(Unmanaged.passUnretained(plan).toOpaque()), ordering: .releasing)
        core.endFrame.store(plan.endFrame + Int(AudioFrames.sampleRate), ordering: .relaxed)
        let core = core
        readAhead.set { [plan] in
            ReadAhead.spans(plan, from: core.position.load(ordering: .relaxed), count: ReadAhead.frames)
        }
        releaseRetiredPlans()
    }

    func play() {
        releaseRetiredPlans()
        if let plan = currentPlan, positionFrame >= plan.endFrame {
            // Back to beat 0, which is frame 0 except in a live set that has
            // let go of what it played (see LiveSet).
            seek(toFrame: Int((plan.tempo.seconds(atBeat: 0) * AudioFrames.sampleRate).rounded()))
        }
        // The first second here and now, rather than on the read-ahead's
        // next round: Play often follows a seek.
        if let plan = currentPlan {
            for span in ReadAhead.spans(plan, from: positionFrame, count: Int(AudioFrames.sampleRate)) {
                span.audio.prefetch(span.frames)
            }
        }
        core.playing.store(true, ordering: .releasing)
    }

    func pause() {
        core.playing.store(false, ordering: .releasing)
    }

    func seek(toFrame frame: Int) {
        let target = max(0, frame)
        core.seekTarget.store(target, ordering: .releasing)
        // Reflect it at once: the callback may not run again until play.
        core.position.store(target, ordering: .releasing)
    }

    func setLaneMask(_ mask: Int) {
        core.laneMask.store(mask, ordering: .relaxed)
    }

    /// Peak levels for the meters, and whether the output clipped since the
    /// last call.
    func readMeters() -> (left: Float, right: Float, overload: Bool) {
        (Float(bitPattern: core.meterLeft.load(ordering: .relaxed)),
         Float(bitPattern: core.meterRight.load(ordering: .relaxed)),
         core.overload.exchange(false, ordering: .relaxed))
    }

    /// Short-term loudness of the output, the last 3 s; nil when silent or
    /// paused. Apart from `readMeters`, which clears the overload flag it
    /// reads: a second reader would steal the lamp.
    func readShortTermLUFS() -> Double? {
        let value = Double(bitPattern: core.meterShortTerm.load(ordering: .relaxed))
        return value.isFinite ? value : nil
    }

    /// Drops every plan older than the one the callback last acknowledged.
    /// The callback acknowledges a plan before rendering with it, so a plan
    /// older than the acknowledgement is one it can no longer be holding.
    private func releaseRetiredPlans() {
        guard plans.count > 1 else { return }
        let inUse = core.playing.load(ordering: .acquiring) || engine.isRunning
            ? core.planInUse.load(ordering: .acquiring)
            : Int.max
        let current = plans.last!
        plans.removeAll { $0 !== current && $0.generation < inUse }
    }
}
