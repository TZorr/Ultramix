//
//  PreviewPlayer.swift
//  Ultramix
//
//  Plays one library track as it is - no mix, no stretch - for auditioning and
//  for checking a beatgrid by ear. Its own AVAudioEngine, so auditioning never
//  touches the mix's render plan and the two can play at once. It plays
//  through the audition output (AudioRouting); the optional metronome clicks
//  on the track's grid, higher on each bar one.
//
//  It can cycle between two frames, wrapping sample-exact from end to start.
//  The ends may move while it plays, so they travel in one atomic word and a
//  block never reads a start from one pair and an end from another.
//

import Foundation
import Observation
@preconcurrency import AVFoundation
import Synchronization

nonisolated final class PreviewCore: @unchecked Sendable {
    let audio = Atomic<UnsafeRawPointer?>(nil)
    let position = Atomic<Int>(0)
    let playing = Atomic<Bool>(false)
    let click = Atomic<Bool>(false)
    /// The cycle: start frame in the high 32 bits, end frame in the low
    /// ones; 0 is off. A song would have to run over 27 hours to overflow.
    let loop = Atomic<UInt64>(0)
    /// A seek waiting for the next block, or −1. Handed over rather than
    /// written into `position` alone: a block already running would store
    /// its own end over it, and the seek would be lost.
    let seekTarget = Atomic<Int>(-1)

    static func packLoop(start: Int, end: Int) -> UInt64 {
        guard end > start, start >= 0 else { return 0 }
        return UInt64(min(start, Int(UInt32.max))) << 32 | UInt64(min(end, Int(UInt32.max)))
    }
    /// Grid for the click, as Double bit patterns: seconds per beat and the
    /// first downbeat's time.
    let beatSeconds = Atomic<UInt64>(0.5.bitPattern)
    let firstBeat = Atomic<UInt64>(0.0.bitPattern)

    /// Auditioning sits at the mix lanes' resting level, so switching from a
    /// preview to the mix is not a jump in loudness.
    private let gain = Float(pow(10, Automation.defaultVolumeDB / 20))

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { [self] isSilence, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frameCount)
            left.update(repeating: 0, count: count)
            right.update(repeating: 0, count: count)
            guard playing.load(ordering: .acquiring), let raw = audio.load(ordering: .acquiring) else {
                isSilence.pointee = true
                return noErr
            }
            let target = seekTarget.exchange(-1, ordering: .acquiringAndReleasing)
            let start = target >= 0 ? target : position.load(ordering: .acquiring)
            let cycle = loop.load(ordering: .acquiring)
            let loopStart = Int(cycle >> 32)
            let loopEnd = Int(cycle & 0xFFFF_FFFF)
            let cycling = loopEnd > loopStart
            let clicking = click.load(ordering: .relaxed)
            let beat = Double(bitPattern: beatSeconds.load(ordering: .relaxed))
            let first = Double(bitPattern: firstBeat.load(ordering: .relaxed))
            let rate = AudioFrames.sampleRate
            var f = start
            Unmanaged<AudioFrames>.fromOpaque(raw)._withUnsafeGuaranteedRef { frames in
                let last = frames.frameCount
                for i in 0..<count {
                    if cycling && f >= loopEnd { f = loopStart }
                    guard f < last else { break }
                    var l = frames.samples[2 * f] * gain
                    var r = frames.samples[2 * f + 1] * gain
                    if clicking && beat > 0 {
                        let t = Double(f) / rate - first
                        let k = (t / beat).rounded(.down)
                        let since = t - k * beat
                        if since < 0.03 {
                            let pitch = Int(k) % 4 == 0 ? 1760.0 : 1320.0
                            let c = Float(0.3 * sin(2 * Double.pi * pitch * since) * exp(-since / 0.008))
                            l += c
                            r += c
                        }
                    }
                    left[i] = l
                    right[i] = r
                    f += 1
                }
                if f >= last {
                    playing.store(false, ordering: .releasing)
                }
            }
            position.store(f, ordering: .releasing)
            return noErr
        }
    }
}

@Observable
final class PreviewPlayer {
    private let engine = AVAudioEngine()
    private let core = PreviewCore()
    /// The audio being played and the one before it. The callback may still
    /// be finishing a block of the previous one when a new one is set, so it
    /// is released only after a second change.
    @ObservationIgnored private var held: [AudioFrames] = []
    /// Keeps the next ten seconds of the track in memory (see ReadAhead).
    @ObservationIgnored private let readAhead = ReadAhead()
    @ObservationIgnored private var router: OutputRouter?

    private(set) var trackID: UUID?

    var clickEnabled = false {
        didSet { core.click.store(clickEnabled, ordering: .relaxed) }
    }

    var isPlaying: Bool { core.playing.load(ordering: .acquiring) }

    var positionSeconds: Double {
        Double(core.position.load(ordering: .acquiring)) / AudioFrames.sampleRate
    }

    /// How long a sample takes from the callback to the speaker. A tap is
    /// late by at least this much relative to what the callback rendered.
    var outputLatency: Double {
        engine.outputNode.presentationLatency
    }

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioFrames.sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: format, renderBlock: core.makeRenderBlock())
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // The audition output (see AudioRouting); the router starts the engine.
        router = OutputRouter(engine: engine, role: .audition)
    }

    /// Stops the audio device and lets go of the audio being previewed -
    /// before the working directory it was mapped from goes away.
    func shutdown() {
        core.playing.store(false, ordering: .releasing)
        router?.shutdown()
        engine.stop()
        readAhead.set(nil)
        core.audio.store(nil, ordering: .releasing)
        held = []
        trackID = nil
    }

    /// Plays from `seconds` with no cycle: a loop belongs to the playback it
    /// was set for, not to the next song auditioned in the library. Set one
    /// after this call.
    func play(_ audio: AudioFrames, track: UUID, fromSeconds seconds: Double) {
        core.playing.store(false, ordering: .releasing)
        core.loop.store(0, ordering: .releasing)
        if held.last !== audio {
            held = Array((held.suffix(1) + [audio]))
            core.audio.store(UnsafeRawPointer(Unmanaged.passUnretained(audio).toOpaque()), ordering: .releasing)
            let core = core
            readAhead.set { [audio] in
                let from = core.position.load(ordering: .relaxed)
                return [ReadAhead.Span(audio: audio, frames: from..<(from + ReadAhead.frames))]
            }
        }
        trackID = track
        seek(toSeconds: seconds)
        let from = core.position.load(ordering: .relaxed)
        audio.prefetch(from..<(from + Int(AudioFrames.sampleRate)))
        core.playing.store(true, ordering: .releasing)
    }

    func stop() {
        core.playing.store(false, ordering: .releasing)
    }

    func seek(toSeconds seconds: Double) {
        let frame = max(0, Int(seconds * AudioFrames.sampleRate))
        core.position.store(frame, ordering: .releasing)
        core.seekTarget.store(frame, ordering: .releasing)
    }

    /// Plays `start…end` over and over until `clearLoop` - from wherever the
    /// playback is: before the stretch it plays into it, past its end it
    /// jumps back at once.
    func setLoop(startSeconds: Double, endSeconds: Double) {
        let start = max(0, Int(startSeconds * AudioFrames.sampleRate))
        let end = Int(endSeconds * AudioFrames.sampleRate)
        core.loop.store(PreviewCore.packLoop(start: start, end: end), ordering: .releasing)
        // The wrap lands here without warning; have its first second in
        // memory, as `play` has the first second after the start.
        if let audio = held.last { audio.prefetch(start..<(start + Int(AudioFrames.sampleRate))) }
    }

    func clearLoop() {
        core.loop.store(0, ordering: .releasing)
    }

    func setGrid(bpm: Double, firstBeatSeconds: Double) {
        core.beatSeconds.store((60 / max(bpm, 1)).bitPattern, ordering: .relaxed)
        core.firstBeat.store(firstBeatSeconds.bitPattern, ordering: .relaxed)
    }
}
