//
//  KnobRecorder.swift
//  Ultramix
//
//  The Rec button: while it is on and the mix plays, a turned lane knob writes
//  its movement into the clip under the playhead on its lane. The rules live
//  in AutomationRecording.swift; this listens and keeps time.
//
//  Touch: a pass begins with a knob's first Control Change and ends half a
//  second after its last. While it is open the knob is sampled every tick, so
//  a knob held still writes a hold and not a slope.
//
//  What is heard is the automation, not the knob: the knobs go to the audio
//  thread neutral and the plan is rebuilt twenty times a second, so a knob
//  cannot count twice. One run - Play to Stop - is one undo step.
//
//  The mix only: the live set moves its beats back while it plays.
//

import Foundation

@MainActor
final class KnobRecorder {
    /// How long after its last Control Change a knob lets go.
    static let release = 0.5
    /// How often a pass is sampled and written.
    static let tick = 0.05

    private weak var session: MixSession?
    private let knobs: LaneKnobController
    private var timer: Timer?

    private struct Pass {
        let kind: AutomationKind
        let function: KnobFunction
        /// Timeline-beat samples per clip, and the clips in the order the
        /// pass reached them - a pass that runs on into the next clip on
        /// its lane goes on there.
        var samples: [UUID: [AutomationNode]] = [:]
        var clips: [UUID] = []
        /// Each clip's automation as it was before the pass: what the curve
        /// returns to when the knob lets go.
        var before: [UUID: ClipAutomation] = [:]
        var lastMove: Date
    }
    private var passes: [Int: Pass] = [:]
    /// Whether this run has recorded its undo step yet.
    private var recording = false
    /// Knobs turned in this run, reset once it ends.
    private var touched = false

    var armed = false {
        didSet {
            guard armed != oldValue else { return }
            if armed {
                let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.step() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            } else {
                timer?.invalidate()
                timer = nil
                endRun()
                knobs.monitorsThroughAutomation = false
            }
        }
    }

    init(session: MixSession, knobs: LaneKnobController? = nil) {
        self.session = session
        let knobs = knobs ?? .shared
        self.knobs = knobs
        knobs.onChange = { [weak self] slot, value in self?.moved(slot, to: value) }
    }

    private var playing: Bool { session?.isPlaying == true }

    private func moved(_ slot: Int, to value: Int) {
        guard armed, playing else { return }
        touched = true
        sample(slot, value)
        passes[slot]?.lastMove = Date()
    }

    private func step() {
        guard armed, let session else { return }
        knobs.monitorsThroughAutomation = session.isPlaying
        guard session.isPlaying else {
            endRun()
            return
        }
        let now = Date()
        var releasing: Set<Int> = []
        for (slot, pass) in passes {
            if now.timeIntervalSince(pass.lastMove) > Self.release {
                releasing.insert(slot)
            } else {
                sample(slot, knobs.values[slot])
            }
        }
        write(releasing: releasing)
    }

    /// The beat being heard: the callback's position less the output's
    /// latency, so a point lands where the ear was when the hand moved.
    private func heardBeat(_ session: MixSession) -> Double {
        let seconds = Double(session.engine.positionFrame) / AudioFrames.sampleRate - session.engine.outputLatency
        return session.tempo.beat(atSeconds: max(0, seconds))
    }

    private func sample(_ slot: Int, _ value: Int) {
        guard let session, knobs.setup.slots.indices.contains(slot) else { return }
        let beat = heardBeat(session)
        let lane = slot / 2
        let document = session.document
        guard let clip = document.clip(atBeat: beat, lane: lane, grids: session.grids) else { return }
        let function = knobs.setup.slots[slot].function
        var pass = passes[slot] ?? Pass(kind: function.automationKind, function: function, lastMove: Date())
        if pass.samples[clip.id] == nil {
            pass.clips.append(clip.id)
            pass.before[clip.id] = clip.automation
        }
        pass.samples[clip.id, default: []].append(AutomationNode(beat: beat, value: function.automationValue(value)))
        passes[slot] = pass
    }

    /// Writes every open pass as it stands, and lets go of `releasing`.
    private func write(releasing: Set<Int>) {
        guard let session, !passes.isEmpty else { return }
        if !recording {
            session.beginGesture()
            recording = true
        }
        let grids = session.grids
        let open = passes
        session.perform(undoable: false, quiet: true) { document in
            for (slot, pass) in open {
                for id in pass.clips {
                    guard let samples = pass.samples[id], let last = samples.last else { continue }
                    var back: Double?
                    if releasing.contains(slot), id == pass.clips.last,
                       let clip = document.clips.first(where: { $0.id == id }),
                       let before = pass.before[id] {
                        let local = last.beat - Double(clip.anchorBeat) + MixDocument.touchReturnBeats
                        back = AutomationCurve(kind: pass.kind, automation: before).value(at: local)
                    }
                    document.writeTouch(clip: id, kind: pass.kind, samples: samples, returnTo: back, grids: grids)
                }
            }
        }
        for slot in releasing { passes[slot] = nil }
    }

    /// Play stopped or Rec switched off: every pass lets go, and the knobs
    /// that were turned go back to neutral.
    private func endRun() {
        write(releasing: Set(passes.keys))
        passes = [:]
        recording = false
        if touched {
            knobs.resetAll()
            touched = false
        }
    }
}
