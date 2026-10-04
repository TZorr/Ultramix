//
//  MixSession.swift
//  Ultramix
//
//  The mix being edited: the document, its undo history, its file, and the
//  engine playing it.
//
//  Every change goes through `perform`, which works on a copy and commits the
//  whole change or none of it. On commit the old document goes on the undo
//  stack and a new render plan goes to the engine, so the next buffer already
//  plays the edit - editing while the mix runs needs nothing special.
//
//  A drag is one undo step: `beginGesture` records the document once, then the
//  pointer moves it with `perform(undoable: false)`.
//

import Foundation
import Observation
import AppKit

/// A request to open the beatgrid editor for a track.
struct BeatgridRequest: Identifiable {
    let id: UUID
    /// Opens the editor with the BPM correction panel already showing.
    var correctBPM = false
}

@Observable
final class MixSession {
    let library: Library
    let engine = PlaybackEngine()
    let preview = PreviewPlayer()
    /// A track asked to be auditioned whose audio is still being decoded.
    fileprivate(set) var pendingAudition: UUID?
    /// Auditioning, or about to: what keeps the library's arrow keys
    /// auditioning while the next track is decoded.
    var isAuditioning: Bool { preview.isPlaying || pendingAudition != nil }

    // View state that more than one view reaches for.
    /// Which editing tool the timeline is in. Here rather than in the view
    /// because adding a track has to bring it back to Clips.
    var tool: TimelineTool = .clips
    /// The transition ⇧⌘X and the Crossfade buttons apply: the one chosen
    /// last, remembered on this Mac.
    var transitionStyle: TransitionStyle = TransitionStyle(
        rawValue: UserDefaults.standard.string(forKey: "transitionStyle") ?? "") ?? .crossfade {
        didSet { UserDefaults.standard.set(transitionStyle.rawValue, forKey: "transitionStyle") }
    }
    /// The beatmix the toolbar's Beatmix button adds with: the one chosen
    /// last, remembered on this Mac.
    var beatmixLength: BeatmixLength = BeatmixLength.current {
        didSet { BeatmixLength.current = beatmixLength }
    }

    /// What Return and a double-click in the library do; see LibraryAddMode.
    var libraryAddMode: LibraryAddMode = LibraryAddMode.current {
        didSet { LibraryAddMode.current = libraryAddMode }
    }
    /// What a dragged clip snaps to, or whether it moves at all:
    /// remembered on this Mac.
    var moveMode: MoveMode = MoveMode.current {
        didSet { MoveMode.current = moveMode }
    }
    var showBounce = false
    /// The track open in the beatgrid pane. A new request always shows the
    /// pane, even when it was hidden: asking for a beatgrid is asking to see it.
    var beatgridRequest: BeatgridRequest? {
        didSet { if beatgridRequest != nil { beatgridHidden = false } }
    }
    /// The pane folded down to a bar: still open on its track, with its
    /// mark and zoom, but out of the way of the timeline. E or a click on
    /// the bar brings it back.
    var beatgridHidden = false

    /// The track the clip bar's Beatgrid button means: the selected clips'
    /// track, or the one selected in the library, whichever was picked last.
    /// The editor works on the library's track, never on a clip, so a track
    /// not yet in the mix is as editable as one that is.
    var beatgridTarget: UUID? {
        let tracks = Set(document.clips.filter { selection.contains($0.id) }.map(\.trackID))
        let fromClips = tracks.count == 1 ? tracks.first : nil
        let fromLibrary = library.selection.count == 1 ? library.selection.first : nil
        return lastPick == .library ? fromLibrary ?? fromClips : fromClips ?? fromLibrary
    }

    /// The clip bar's Beatgrid button: opens the target, or - when the pane
    /// already shows it - folds it away and back, as E does.
    func beatgridButton() {
        guard let target = beatgridTarget else { return }
        if beatgridRequest?.id == target {
            toggleBeatgrid()
        } else {
            beatgridRequest = BeatgridRequest(id: target)
        }
    }

    /// E: folds the beatgrid pane away, or brings it back; nothing while no
    /// track is open in it. A preview playing in the pane stops as it folds.
    func toggleBeatgrid() {
        guard beatgridRequest != nil else { return }
        if !beatgridHidden { preview.stop() }
        beatgridHidden.toggle()
    }
    /// When the output last clipped; the meter's overload lamp holds on it.
    @ObservationIgnored var lastOverload = Date.distantPast

    private(set) var document = MixDocument() {
        // Every change reaches the rows at once, whichever way it came: an
        // edit, undo, or a clip let go of.
        didSet {
            if isLive { liveOrder = LiveSet.compacted(liveOrder, before: oldValue, after: document) }
            if let mark = selectedMark, !document.hasMark(mark) { selectedMark = nil }
        }
    }
    private(set) var fileURL: URL?
    private(set) var isDirty = false
    var selection: Set<UUID> = [] {
        didSet {
            if !selection.isEmpty {
                lastPick = .clips
                selectedMark = nil
            }
        }
    }
    /// The transition bar picked in the strip under the ruler. Picking one
    /// lets go of the clips, so Delete and ⇧⌘X mean the bar.
    var selectedMark: MarkRef?
    /// Which was picked last, clips on the timeline or a row in the library:
    /// the clip bar's Beatgrid button opens that one's track.
    enum PickSource { case clips, library }
    var lastPick: PickSource = .clips
    /// A message for the user - an edit that was refused, a file that would
    /// not open. Shown once and cleared by the view.
    var message: String?

    /// The live set (see LiveSet): its own session in its own tab, at most
    /// three clips, never saved.
    let isLive: Bool
    /// Grows by the beats the live set moved back by each time it let go of
    /// what had played, so the timeline can scroll with it and the picture
    /// stays still.
    private(set) var liveShift = 0
    @ObservationIgnored private var liveTimer: Timer?
    /// The Rec button (see KnobRecorder): the mix only, never the live set.
    @ObservationIgnored private var recorder: KnobRecorder?
    var isRecording = false {
        didSet { recorder?.armed = isRecording }
    }
    /// The other tab's session - the live set for the mix, the mix for the
    /// live set. There is one output: the two must not play over each other.
    @ObservationIgnored weak var partner: MixSession?
    /// Auto: whenever nothing waits in the playing set, the next track of
    /// the library's visible order goes in with a Beatmix 4. Off at every
    /// launch.
    var autoOn = false
    /// The track that went into the set last, by any means; Auto takes the
    /// one after it. One id, not a history.
    private(set) var lastAdded: UUID?

    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var history = UndoHistory<MixDocument>()

    /// The plan the engine is playing, for the view's tempo readout and the
    /// warnings it shows on clips.
    private(set) var plan: RenderPlan?

    /// The mixes in the working directory's Mixes folder, newest first, for
    /// File › Open Mix.
    private(set) var mixFiles: [URL] = []
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    /// The loudness target from Settings, as the plan was last built with it.
    @ObservationIgnored private var loudnessTarget = LoudnessTarget.current()

    /// - Parameter live: a live set rather than a mix. Its owner wires the
    ///   library's track changes to both sessions (see AppModel).
    init(library: Library, live: Bool = false) {
        self.library = library
        isLive = live
        rebuild()
        if live {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pruneLive()
                    self?.autoTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            liveTimer = timer
        }
        if let failure = engine.failure { message = failure }
        if !live { recorder = KnobRecorder(session: self) }
        refreshMixFiles()
        // A mix copied into the folder in Finder shows up once Ultramix is in
        // front again; the folder is not watched while nobody can open a menu.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMixFiles() }
        }
        // Any default changing posts this, so the plan is rebuilt only
        // when the target itself changed.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target = LoudnessTarget.current()
                guard target != self.loudnessTarget else { return }
                self.loudnessTarget = target
                self.rebuild()
            }
        }
    }

    var grids: GridLookup {
        let library = library
        return { library.grid(for: $0) }
    }

    var tempo: TempoMap { plan?.tempo ?? document.tempoMap(grids) }

    // MARK: - Editing

    var title: String {
        isLive ? "Live Set" : fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled Mix"
    }

    var endBeat: Double { document.endBeat(grids) }

    var usedTracks: Set<UUID> { Set(document.clips.map(\.trackID)) }

    /// - Parameter quiet: a refused change says nothing. A drag that runs
    ///   into a neighbouring clip simply stops there; a message box on every
    ///   mouse movement would be worse than useless.
    func perform(undoable: Bool = true, quiet: Bool = false, _ change: (inout MixDocument) throws -> Void) {
        var copy = document
        do {
            try change(&copy)
        } catch {
            if !quiet { message = error.localizedDescription }
            return
        }
        guard copy != document else { return }
        if isLive, let refusal = LiveSet.refusal(before: document.clips.count, after: copy.clips.count) {
            if !quiet { message = refusal }
            return
        }
        if isLive {
            // What has played keeps its tempo (see LiveSet.protectPast). An
            // edit that still moves the clock while the set plays - a tempo
            // point dragged behind the playhead - is refused rather than
            // heard as a jump.
            let playhead = playheadBeat()
            copy = LiveSet.protectPast(copy, old: document, playhead: playhead)
            if isPlaying, LiveSet.clockMoved(copy, old: document, playhead: playhead, grids: grids) {
                if !quiet { message = "That would change the tempo of what has already played. Stop the set to change it." }
                return
            }
            let known = Set(document.clips.map(\.id))
            if let newest = copy.clips.last(where: { !known.contains($0.id) }) { lastAdded = newest.trackID }
        }
        if undoable { history.record(document) }
        document = copy
        isDirty = true
        selection = selection.filter { id in document.clips.contains { $0.id == id } }
        refreshUndo()
        rebuild()
    }

    /// Records the document once, before a drag starts changing it.
    func beginGesture() {
        history.record(document)
        refreshUndo()
    }

    func undo() {
        guard let previous = history.undo(from: document) else { return }
        document = previous
        isDirty = true
        refreshUndo()
        rebuild()
    }

    func redo() {
        guard let next = history.redo(from: document) else { return }
        document = next
        isDirty = true
        refreshUndo()
        rebuild()
    }

    private func refreshUndo() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: - Clips

    func addTrack(_ trackID: UUID, lane: Int? = nil, startBeat: Double? = nil) {
        guard let grid = library.grid(for: trackID) else {
            message = "That track has no beatgrid yet - wait for its analysis to finish."
            return
        }
        var added: UUID?
        perform { document in
            added = try document.addClip(trackID: trackID, grid: grid, lane: lane, startBeat: startBeat, grids: grids)
        }
        if let added {
            selection = [added]
            tool = .clips
        }
    }

    /// Adds tracks one after another at the end of the mix, each with a
    /// beatmix of `beatmix` into it (see Beatmix.swift). One undo step for
    /// all of them; if one cannot be placed, none is. The length becomes the
    /// one the toolbar button adds with next, unless `remember` is false.
    func addTracks(_ trackIDs: [UUID], beatmix: BeatmixLength, remember: Bool = true) {
        guard !trackIDs.isEmpty else { return }
        if remember { beatmixLength = beatmix }
        guard trackIDs.allSatisfy({ library.grid(for: $0) != nil }) else {
            message = trackIDs.count == 1
                ? "That track has no beatgrid yet - wait for its analysis to finish."
                : "Not every one of these tracks has a beatgrid yet - wait for their analysis to finish."
            return
        }
        let library = library
        let step = isLive && beatmix == .noTransition
        var added: [UUID] = []
        perform { document in
            added = []
            for id in trackIDs {
                guard let grid = library.grid(for: id) else { continue }
                added.append(try document.addClip(trackID: id, grid: grid, beatmix: beatmix, grids: grids,
                                                  stepTempo: step))
            }
        }
        if !added.isEmpty, document.clips.contains(where: { $0.id == added[0] }) {
            selection = Set(added)
            tool = .clips
        }
    }

    /// Puts one track into the mix at the playhead with a beatmix of
    /// `beatmix` from the record playing there (see `insertClip`). One undo
    /// step. The toolbar's length is left as it is - that button still adds
    /// at the end.
    func insertTrack(_ trackID: UUID, beatmix: BeatmixLength) {
        guard let grid = library.grid(for: trackID) else {
            message = "That track has no beatgrid yet - wait for its analysis to finish."
            return
        }
        let playhead = playheadBeat()
        // In a live set nothing playing at the playhead is ordinary, and
        // the track is simply the next in the queue: the same beatmix at
        // the end of the set. A mix keeps the refusal.
        if isLive, !document.clips.isEmpty, document.playing(atBeat: playhead, grids: grids) == nil {
            addTracks([trackID], beatmix: beatmix, remember: false)
            return
        }
        var added: UUID?
        perform { document in
            added = try document.insertClip(trackID: trackID, grid: grid, beatmix: beatmix,
                                            atBeat: playhead, grids: grids)
        }
        if let added, document.clips.contains(where: { $0.id == added }) {
            selection = [added]
            tool = .clips
        }
    }

    /// A track's cue points, for the model - `CueLookup`.
    var cues: CueLookup { { [library] in library.cuePoints(for: $0) } }

    /// Puts one track into the mix at the next cue point of the record
    /// playing. One undo step, and the toolbar's length is left as it is,
    /// as At Playhead leaves it.
    func insertTrackAtCue(_ trackID: UUID, beatmix: BeatmixLength) {
        guard let grid = library.grid(for: trackID) else {
            message = "That track has no beatgrid yet - wait for its analysis to finish."
            return
        }
        let playhead = playheadBeat()
        let cues = cues
        var added: UUID?
        perform { document in
            added = try document.insertClip(trackID: trackID, grid: grid, beatmix: beatmix,
                                            atCueAfter: playhead, cues: cues, grids: grids)
        }
        if let added, document.clips.contains(where: { $0.id == added }) {
            selection = [added]
            tool = .clips
        }
    }

    // MARK: - Loops

    /// Puts the region marked in the beatgrid editor into the mix as a
    /// looping clip: at the end of the mix with `beatmix`, or at the
    /// playhead when `atPlayhead` says so. The
    /// loop is the same kind of clip a dragged-out loop is; only the way it
    /// is placed is new.
    func addLoop(_ trackID: UUID, region: LoopRegion, repeats: Int, beatmix: BeatmixLength,
                 atPlayhead: Bool = false) {
        guard let grid = library.grid(for: trackID) else {
            message = "That track has no beatgrid yet - wait for its analysis to finish."
            return
        }
        guard let draft = ClipDraft.loop(region: region, grid: grid, repeats: repeats) else {
            message = "The marked stretch is too short to loop - mark at least a beat of the song."
            return
        }
        let playhead = playheadBeat()
        var added: UUID?
        perform { document in
            if atPlayhead {
                added = try document.insertClip(trackID: trackID, grid: grid, beatmix: beatmix,
                                                atBeat: playhead, grids: grids, draft: draft)
            } else {
                added = try document.addClip(trackID: trackID, grid: grid, beatmix: beatmix, grids: grids,
                                             stepTempo: isLive && beatmix == .noTransition, draft: draft)
            }
        }
        if let added, document.clips.contains(where: { $0.id == added }) {
            selection = [added]
            tool = .clips
        }
    }

    /// Adds library tracks the way `mode` says - Return and double-click.
    /// A beatmix at the end leaves the toolbar's length as it is.
    func add(_ trackIDs: [UUID], mode: LibraryAddMode) {
        switch mode {
        case .plain:
            trackIDs.forEach { addTrack($0) }
        case .end(let length):
            addTracks(trackIDs, beatmix: length, remember: false)
        case .playhead(let length):
            guard trackIDs.count == 1, let id = trackIDs.first else {
                if trackIDs.count > 1 { message = "At Playhead adds one track at a time." }
                return
            }
            insertTrack(id, beatmix: length)
        case .cue(let length):
            guard trackIDs.count == 1, let id = trackIDs.first else {
                if trackIDs.count > 1 { message = "At Cue adds one track at a time." }
                return
            }
            insertTrackAtCue(id, beatmix: length)
        }
    }

    func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        let grids = grids
        perform { $0.removeClips(ids, grids: grids) }
        selection = []
    }

    func splitSelection(atBeat beat: Double) {
        let ids = selection
        perform { document in
            for id in ids {
                guard let clip = document.clips.first(where: { $0.id == id }),
                      let shape = document.geometry(clip, grids), shape.contains(beat) else { continue }
                try document.splitClip(id, at: beat, grids: grids)
            }
        }
    }

    func duplicateSelection() {
        let ids = selection
        var copies: Set<UUID> = []
        perform { document in
            for id in ids { copies.insert(try document.duplicateClip(id, grids: grids)) }
        }
        if !copies.isEmpty { selection = copies }
    }

    func toggleLoopSelection() {
        let ids = selection
        perform { document in
            for id in ids {
                let looping = document.clips.first { $0.id == id }?.looping ?? false
                document.setLooping(id, !looping)
            }
        }
    }

    func toggleMuteSelection() {
        let ids = selection
        perform { document in
            for id in ids {
                let muted = document.clips.first { $0.id == id }?.muted ?? false
                document.setMuted(id, !muted)
            }
        }
    }

    /// Moves the selected clips by whole beats; one undo step per call. A
    /// nudge that cannot happen does nothing - no alert, and no alert sound
    /// either (see SilentResponder).
    func nudgeSelection(byBeats beats: Int) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let grids = grids
        perform(quiet: true) { try $0.nudgeClips(ids, byBeats: beats, grids: grids) }
    }

    /// Deletes the automation selected on the timeline; one undo step.
    func deleteAutomation(_ selection: AutomationSelection) {
        perform { $0.deleteAutomation(selection) }
    }

    /// Deletes the automation drawn on the selected clips and keeps the
    /// clips, and their selection; one undo step.
    func deleteSelectionAutomation() {
        let ids = selection
        guard !ids.isEmpty else { return }
        perform { try $0.removeAutomation(onClips: ids) }
    }

    /// Writes a transition over the overlaps of the selected clips, or over
    /// every transition in the mix when nothing is selected. One undo step.
    /// A style given here becomes the one ⇧⌘X applies next.
    /// With a transition bar picked, it writes into that bar alone.
    func autoCrossfade(_ style: TransitionStyle? = nil) {
        if let style { transitionStyle = style }
        let chosen = transitionStyle
        let grids = grids
        if let mark = selectedMark {
            perform { try $0.applyStyle(chosen, toMark: mark, grids: grids) }
            return
        }
        let ids = selection.isEmpty ? nil : selection
        perform { try $0.autoCrossfade(ids, style: chosen, grids: grids) }
    }

    // MARK: - Transition bars

    /// Draws a transition bar and writes the current style there; it is
    /// picked afterwards.
    func addMark(from start: Double, to end: Double) {
        let style = transitionStyle
        let grids = grids
        var added: MarkRef?
        perform { added = try $0.addMark(from: start, to: end, style: style, grids: grids) }
        if let added {
            selection = []
            selectedMark = added
        }
    }

    /// One step of a drag on a bar - recorded by `beginGesture`, as every
    /// drag is. Returns where the bar is now; nil when this step was refused
    /// and the bar stayed where it was.
    func moveMark(_ ref: MarkRef, from start: Double, to end: Double) -> MarkRef? {
        let style = transitionStyle
        let grids = grids
        var moved: MarkRef?
        perform(undoable: false, quiet: true) {
            moved = try $0.moveMark(ref, from: start, to: end, currentStyle: style, grids: grids)
        }
        if let moved, selectedMark == ref { selectedMark = moved }
        return moved
    }

    func removeSelectedMark() {
        guard let mark = selectedMark else { return }
        let grids = grids
        perform { try $0.removeMark(mark, grids: grids) }
    }

    // MARK: - Lanes

    func toggleLaneMute(_ lane: Int) {
        perform { $0.lanes[lane].muted.toggle() }
    }

    func toggleLaneSolo(_ lane: Int) {
        perform { $0.lanes[lane].solo.toggle() }
    }

    /// Mute and solo resolved into the renderer's lane mask: a lane is heard
    /// when it is not muted and either nothing is soloed or it is.
    var laneMask: Int {
        let anySolo = document.lanes.contains { $0.solo }
        var mask = 0
        for (lane, state) in document.lanes.enumerated() where !state.muted && (!anySolo || state.solo) {
            mask |= 1 << lane
        }
        return mask
    }

    // MARK: - Live

    /// The live set's rows, top to bottom: empty lanes at the bottom (see
    /// LiveSet.compacted). Not saved, like the set.
    private(set) var liveOrder = Array(0..<Clip.laneCount)

    /// The lanes top to bottom: A, B, C in a mix, the live set's own order
    /// in a live set.
    var laneOrder: [Int] { isLive ? liveOrder : Array(0..<Clip.laneCount) }

    var liveSubtitle: String {
        let count = document.clips.count
        return "\(count) of \(LiveSet.clipLimit) clips"
    }

    /// The track Auto would take now, for the library's "Next" readout and
    /// for Auto itself.
    func autoNext(order: [UUID]) -> UUID? {
        let library = library
        return LiveSet.autoNext(order: order, lastAdded: lastAdded, inSet: usedTracks,
                                hasGrid: { library.grid(for: $0) != nil })
    }

    /// Auto's turn on the live timer. Not while a mouse button is down, like
    /// letting go: a track dropping in under a drag would be a surprise.
    /// The added clip is not selected - the user's selection stays theirs.
    private func autoTick() {
        // The next track's audio, ready before Auto needs it.
        if autoOn, let next = autoNext(order: library.visibleOrder) { library.prepare([next]) }
        guard autoOn, NSEvent.pressedMouseButtons == 0,
              LiveSet.needsAuto(document, playhead: playheadBeat(), grids: grids) else { return }
        guard let next = autoNext(order: library.visibleOrder), let grid = library.grid(for: next) else {
            autoOn = false
            message = "Auto reached the end of the list."
            return
        }
        let before = document
        let grids = grids
        perform { try $0.addClip(trackID: next, grid: grid, beatmix: LiveSet.autoBeatmix, grids: grids, stepTempo: true) }
        // A track that cannot go in would be tried four times a second.
        if document == before { autoOn = false }
    }

    /// Lets go of the clips that have played. Not while a mouse button is
    /// down: a drag works out where a clip goes from where it started, and
    /// would put it back on the old beats.
    private func pruneLive() {
        guard isLive, NSEvent.pressedMouseButtons == 0 else { return }
        switch LiveSet.pruned(document, playhead: playheadBeat(), playing: isPlaying, grids: grids) {
        case .unchanged:
            return
        case .rebased(let next, let shift):
            document = next
            liveShift += shift
        case .emptied(let empty):
            document = empty
            engine.seek(toFrame: 0)
        }
        // The undo steps hold the set on its old beats; one of them put back
        // would move the clock under the playhead.
        history.clear()
        refreshUndo()
        selection = selection.filter { id in document.clips.contains { $0.id == id } }
        rebuild()
    }

    // MARK: - Engine

    func rebuild() {
        let document = document
        let grids = grids
        let library = library
        let gain = clipGain()
        engine.install { generation in
            RenderPlan(document: document, grids: grids, audio: { library.audio(for: $0) }, generation: generation,
                       gainDB: gain)
        }
        engine.setLaneMask(laneMask)
        plan = engine.currentPlan
        // A track whose audio the cache's size limit took is silent in this
        // plan; it is decoded now, and the mix rebuilt when it is there.
        // Earliest clips first: they are the ones heard first.
        let missing = document.clips.sorted { $0.anchorBeat < $1.anchorBeat }.map(\.trackID)
            .filter { library.audio(for: $0) == nil }
        if !missing.isEmpty { library.prepare(missing) }
    }

    /// Every track the mix plays, decoded - a bounce has no second chance
    /// at a clip whose audio arrives late. False, with a message, if one
    /// cannot be.
    func prepareAudio() async -> Bool {
        let ids = Set(document.clips.filter { !$0.muted }.map(\.trackID))
        let missing = await library.ready(ids)
        guard missing.isEmpty else {
            let names = missing.compactMap { library.track($0)?.displayName }.sorted()
            message = "Not bounced: the audio of \(names.joined(separator: ", ")) could not be decoded."
            return false
        }
        return true
    }

    /// Before the working directory closes: both engines stop and the plan
    /// goes, so nothing keeps mapped audio from that folder in use.
    func shutdown() {
        liveTimer?.invalidate()
        liveTimer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        engine.shutdown()
        preview.shutdown()
        plan = nil
    }

    // MARK: - Transport

    var isPlaying: Bool { engine.isPlaying }

    /// Notes an overload and says whether the lamp should be lit. It holds
    /// for a second, so a single clipped block is still seen.
    func overloadLamp(_ overloaded: Bool) -> Bool {
        let now = Date()
        if overloaded { lastOverload = now }
        return now.timeIntervalSince(lastOverload) < 1
    }

    func togglePlay() {
        if engine.isPlaying {
            engine.pause()
        } else {
            // One output, one set playing. A running live set is never
            // stopped from the mix's tab; the live set takes over from a
            // mix that was only being listened to.
            if let partner, partner.isPlaying {
                guard isLive else {
                    message = "The live set is playing. Stop it in the Live tab before playing the mix."
                    return
                }
                partner.engine.pause()
            }
            // One transport at a time: the mix takes over from the browser -
            // unless auditioning has an output of its own (see AudioRouting).
            if !AudioDevices.shared.isSplit {
                preview.stop()
                partner?.preview.stop()
                pendingAudition = nil
                partner?.pendingAudition = nil
            }
            engine.play()
        }
    }

    /// The beatgrid editor's Play: the timeline stops, in this tab and the
    /// other - the editor is where the ear is now. Unlike an audition in
    /// the library, a split output makes no exception.
    func pauseForEditorPreview() {
        engine.pause()
        partner?.engine.pause()
        partner?.preview.stop()
    }

    /// The live set, when it is playing: nothing else may reach the output.
    private var livePlaying: Bool {
        (isLive && isPlaying) || (partner?.isLive == true && partner?.isPlaying == true)
    }

    /// Auditions a library track and pauses the mix while it does; the mix
    /// keeps its position, so Space picks it up where it was.
    ///
    /// With an audition output of its own (AudioRouting) it is the cue: the
    /// mix and the live set play on, and an audition is allowed over a live
    /// set.
    func audition(_ trackID: UUID, fromSeconds seconds: Double = 0) {
        let cue = AudioDevices.shared.isSplit
        // Without a headphone cue an audition would be heard in the set, and
        // pausing for it would stop the set.
        guard cue || !livePlaying else {
            preview.stop()
            pendingAudition = nil
            message = "The live set is playing - an audition would be heard in it."
            return
        }
        guard let audio = library.audio(for: trackID) else {
            // Carrying on with the track before it would be worse than a
            // moment's silence. Its audio is decoded first; only the latest
            // request plays when it arrives.
            preview.stop()
            pendingAudition = trackID
            library.whenReady(trackID) { [weak self] audio in
                guard let self, self.pendingAudition == trackID else { return }
                self.pendingAudition = nil
                if audio != nil { self.audition(trackID, fromSeconds: seconds) }
            }
            return
        }
        pendingAudition = nil
        if !cue {
            engine.pause()
            partner?.engine.pause()
        }
        partner?.preview.stop()
        preview.play(audio, track: trackID, fromSeconds: seconds)
    }

    /// Where the playhead is, in beats - read from the engine's own frame
    /// counter, converted with the map the engine is playing.
    func playheadBeat() -> Double {
        tempo.beat(atSeconds: Double(engine.positionFrame) / AudioFrames.sampleRate)
    }

    func seek(toBeat beat: Double) {
        let seconds = tempo.seconds(atBeat: max(0, beat))
        engine.seek(toFrame: Int((seconds * AudioFrames.sampleRate).rounded()))
    }

    // MARK: - Files

    /// Reads the Mixes folder again: `.ultramix` only, no subfolders, no
    /// hidden files, most recently changed first. A folder that cannot be
    /// read lists nothing rather than failing.
    func refreshMixFiles() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let found = (try? FileManager.default.contentsOfDirectory(
            at: library.workspace.mixes, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dated = found.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == MixDocument.fileExtension,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        let sorted = dated.sorted { $0.1 > $1.1 }.map(\.0)
        if sorted != mixFiles { mixFiles = sorted }
    }

    func newMix() {
        engine.pause()
        document = MixDocument()
        fileURL = nil
        isDirty = false
        selection = []
        history.clear()
        refreshUndo()
        engine.seek(toFrame: 0)
        rebuild()
        refreshMixFiles()
    }

    func open(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let loaded = try MixDocument.load(from: Data(contentsOf: url))
            for reference in loaded.tracks { library.adopt(reference) }
            engine.pause()
            document = loaded
            fileURL = url
            isDirty = false
            selection = []
            history.clear()
            refreshUndo()
            engine.seek(toFrame: 0)
            rebuild()
            refreshMixFiles()
        } catch {
            message = "\(url.lastPathComponent) could not be opened: \(error.localizedDescription)"
        }
    }

    func save(to url: URL) {
        var stored = document
        let used = Set(document.clips.map(\.trackID))
        stored.tracks = used.compactMap { library.reference(for: $0) }.sorted { $0.path < $1.path }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try stored.write(to: url)
            document.tracks = stored.tracks
            fileURL = url
            isDirty = false
            refreshMixFiles()
        } catch {
            message = "The mix could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: - Bounce

    /// A plan of the bounce's own - its stretch memos must not be shared with
    /// the audio thread's.
    func bouncePlan() -> RenderPlan {
        let library = library
        return RenderPlan(document: document, grids: grids, audio: { library.audio(for: $0) }, generation: -1,
                          gainDB: clipGain())
    }

    /// The gain each clip plays with: its own, or - with a loudness target
    /// on - the gain bringing it to the target with its own as an offset
    /// (ClipLoudness.effectiveGainDB). The mix's stored gains never change.
    private func clipGain() -> (Clip) -> Double {
        guard let target = loudnessTarget else { return { $0.gainDB } }
        let grids = grids
        let profiles = library.loudness
        return { clip in
            guard let grid = grids(clip.trackID) else { return clip.gainDB }
            return ClipLoudness.effectiveGainDB(clip, grid: grid, profile: profiles[clip.trackID], target: target)
        }
    }
}
