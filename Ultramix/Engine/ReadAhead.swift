//
//  ReadAhead.swift
//  Ultramix
//
//  Keeps the audio just ahead of the playhead in memory, so the render
//  callback never waits for the drive. A mapped page is read on first touch -
//  0.5 to 1.5 ms on an idle external drive - so a thread of its own, four
//  times a second, touches the pages the next ten seconds will read
//  (AudioFrames.prefetch). Touching them again is nearly free and keeps them
//  from being the first the system lets go of. It runs while stopped too.
//
//  Which frames: the stretcher searches ±`searchRadius` around the map's
//  position, and a grain after a seek is worked out from the restart before
//  it, up to an eighth note back. `spans` covers all of that - a render whose
//  source is spoiled outside the spans comes out bit-identical.
//

import Foundation

nonisolated final class ReadAhead: @unchecked Sendable {
    static let seconds = 10.0
    static let interval = 0.25
    static var frames: Int { Int(seconds * AudioFrames.sampleRate) }
    /// Beyond the tempo map's position at either end of a window: the
    /// splice search, the comparison window and a grain on each side.
    static let margin = Stretcher.searchRadius + Stretcher.windowLength + 2 * Stretcher.hop

    struct Span: Sendable {
        let audio: AudioFrames
        let frames: Range<Int>
    }

    /// What to keep in memory, asked afresh on each round. Runs on the
    /// read-ahead queue, so it may only capture what is safe to read there.
    typealias Job = @Sendable () -> [Span]

    private let lock = NSLock()
    private var job: Job?
    private let timer: DispatchSourceTimer
    /// The values read, so the reads are not optimised away. Queue only.
    private var sink: Float = 0

    init() {
        // User-initiated, not utility: utility I/O is throttled, and these
        // reads are the ones playback is about to need.
        let queue = DispatchQueue(label: "Ultramix.ReadAhead", qos: .userInitiated)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.round() }
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    /// Replaces what is kept in memory; nil for nothing. The job holds on to
    /// what it captures - a plan, the audio - until it is replaced.
    func set(_ job: Job?) {
        lock.withLock { self.job = job }
    }

    private func round() {
        guard let job = lock.withLock({ self.job }) else { return }
        for span in job() {
            sink += span.audio.prefetch(span.frames)
        }
    }

    /// The source frames a render of timeline frames `from ..< from + count`
    /// can read, per segment it touches.
    static func spans(_ plan: RenderPlan, from: Int, count: Int) -> [Span] {
        var spans: [Span] = []
        let rate = AudioFrames.sampleRate
        let tempo = plan.tempo
        for segment in plan.segments {
            let a = max(from, segment.startFrame)
            let b = min(from + count, segment.endFrame)
            guard a < b else { continue }
            // Two restarts back from the one containing `a`: a cold grain
            // is walked from its restart, and the first grain of a restart
            // splices onto the last of the one before.
            let beat = tempo.beat(atSeconds: Double(a) / rate)
            let k = Int(((beat - segment.gridPhase) / Stretcher.restartBeats).rounded(.down)) - 2
            let first = min(a, Stretcher.frame(ofRestart: k, segment, tempo))
            let low = segment.nominalSourceFrame(atTimelineFrame: first, tempo: tempo).rounded(.down)
            let high = segment.nominalSourceFrame(atTimelineFrame: b, tempo: tempo).rounded(.up)
            let lower = max(0, Int(low) - margin)
            let upper = min(segment.audio.frameCount, Int(high) + margin)
            if lower < upper {
                spans.append(Span(audio: segment.audio, frames: lower..<upper))
                // Stems are as long as the song, and read at the same frames.
                for stem in segment.stems?.audio.all ?? [] {
                    spans.append(Span(audio: stem, frames: lower..<upper))
                }
            }
        }
        return spans
    }
}
