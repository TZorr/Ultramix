//
//  Library.swift
//  Ultramix
//
//  The track library of one working directory: which songs it holds, what the
//  analyser found, and the decoded audio and waveforms that go with them.
//
//  Importing is instant. A track appears at once marked pending; behind it,
//  two tracks at a time - copy into Audio/, decode into the cache, then
//  waveform and loudness, tags and tempo. Two, not one per core: the work is
//  disk-bound, and an import must not take the machine away from a playing mix.
//
//  Decoded audio is kept under a size limit (AudioCacheLimit), least recently
//  used first; a track without it is decoded again (`prepare`) when something
//  asks, and until then `audio(for:)` answers nil and the clip is silent.
//
//  A clip with a key shift or fine tune plays its track rendered at that pitch
//  (KeyShifter) into a cache file of its own, one at a time in the
//  background (`prepareShifts`); until it is there the clip plays unshifted.
//  Shifts count towards the size limit with their track and go with it.
//
//  A clip whose stems play at different levels needs its track separated
//  (StemSeparator), once, when it first asks (`separate`): the three stems
//  are kept in the working directory's Stems folder and decoded into the
//  cache beside the song. They are decoded again after the size limit took
//  them, and shifted with the clip's key, through the same queue as the
//  song's shifts (a ShiftKey for the stems). Until they are there the clip
//  plays the whole song.
//
//  With copying switched off (ImportCopy) a song outside the working directory
//  keeps its absolute path and a security-scoped bookmark, resolved for as
//  long as each read takes (`songURL`). Playback reads the cache and never
//  needs it.
//

import Foundation
import Observation

nonisolated enum LibraryError: Error, LocalizedError {
    case originalMissing(String)

    var errorDescription: String? {
        switch self {
        case .originalMissing(let name):
            "The original of “\(name)” is no longer available, and it was never copied into the working directory. Import it again."
        }
    }
}

@Observable
final class Library {
    private(set) var tracks: [Track] = []
    private(set) var waveforms: [UUID: Waveform] = [:]
    /// Each track's loudness, 100 ms at a time; see LoudnessProfile.
    private(set) var loudness: [UUID: LoudnessProfile] = [:]
    /// Tracks being worked on right now.
    private(set) var busy: Set<UUID> = []
    /// Tracks being decoded again for playback. Read by `audio(for:)`, so
    /// a view that asked for audio is drawn again when it arrives.
    private(set) var decoding: Set<UUID> = []
    /// Key shifts being rendered. Observed like `decoding`.
    private(set) var shifting: Set<ShiftKey> = []
    /// Tracks being separated into stems, with how far each has got (0…1).
    private(set) var separating: [UUID: Double] = [:]
    /// Each separated track's stems' waveforms, in the order of
    /// `Stem.allCases`, for the expanded lanes' rows (`prepareStemWaveforms`).
    private(set) var stemWaveforms: [UUID: [Waveform]] = [:]
    /// What is selected in the library panel. It lives here, not in the
    /// panel, so that a menu command can act on it too.
    var selection: Set<UUID> = []
    /// How far a round of tag writing has got; nil while none is running.
    private(set) var tagProgress: TagProgress?
    var writingTags: Bool { tagProgress != nil }
    /// The same bar, for a round of decoding every song into the cache.
    private(set) var cacheFill: TagProgress?
    var fillingCache: Bool { cacheFill != nil }
    var lastError: String?
    /// Something to tell the user that is not a failure - what a round of
    /// tag writing did, for instance.
    var notice: String?

    /// Called when a track's audio or grid changes, so the mix can rebuild.
    @ObservationIgnored var onTrackChange: ((UUID) -> Void)?
    /// The tracks as the list shows them - sorted, searched, filtered.
    /// Live's Auto takes its next track from here.
    @ObservationIgnored var visibleOrder: [UUID] = []
    /// The tracks whose audio must stay in the cache whatever its size: the
    /// ones in the open mix and live set, and the one being auditioned.
    /// Set by the owner, which knows the sessions.
    @ObservationIgnored var pinnedTracks: () -> Set<UUID> = { [] }

    @ObservationIgnored private var frames: [UUID: AudioFrames] = [:]
    @ObservationIgnored private var shiftedFrames: [ShiftKey: AudioFrames] = [:]
    @ObservationIgnored private var shiftQueue: [ShiftKey] = []
    @ObservationIgnored private var shifters = 0
    @ObservationIgnored private var shiftWaiters: [ShiftKey: [(AudioFrames?) -> Void]] = [:]
    /// Shifts that failed this session, not tried again on every rebuild.
    @ObservationIgnored private var unshiftable: Set<ShiftKey> = []
    /// The render running for each shift, to be cancelled when no clip
    /// wants it any more.
    @ObservationIgnored private var shiftTasks: [ShiftKey: Task<ShiftOutcome, Never>] = [:]
    @ObservationIgnored private var stemFrames: [ShiftKey: StemAudio] = [:]
    @ObservationIgnored private var stemWaveformLoads: Set<UUID> = []
    @ObservationIgnored private var separateQueue: [UUID] = []
    @ObservationIgnored private var separators = 0
    @ObservationIgnored private var separateTasks: [UUID: Task<SeparationOutcome, Never>] = [:]
    @ObservationIgnored private var separationWaiters: [UUID: [(Bool) -> Void]] = [:]
    /// Tracks whose separation failed this session.
    @ObservationIgnored private var unseparable: Set<UUID> = []
    /// The network, loaded for a round of separations and let go after.
    @ObservationIgnored private let separatorModel = SeparatorModel()
    /// Every shift a clip in either session plays. Set by the owner, which
    /// knows the sessions. Clicking + three times wants +3 only: +1 and +2
    /// are dropped from the queue, or stopped if already rendering.
    @ObservationIgnored var wantedShifts: (() -> Set<ShiftKey>)?
    @ObservationIgnored private var index: [UUID: Int] = [:]
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var hints: [UUID: Double] = [:]
    /// The analyser each queued track was queued for; a track missing here
    /// gets its own analyser again if it is only outdated, else the one
    /// chosen in Settings.
    @ObservationIgnored private var algorithms: [UUID: BeatAlgorithm] = [:]
    @ObservationIgnored private var workers = 0
    @ObservationIgnored private var decodeQueue: [UUID] = []
    @ObservationIgnored private var decoders = 0
    /// Waiting for a track's audio: an audition, a bounce.
    @ObservationIgnored private var waiters: [UUID: [(AudioFrames?) -> Void]] = [:]
    /// Tracks whose decode failed this session. Not tried again on every
    /// rebuild - each failure would rebuild and ask again, for ever.
    @ObservationIgnored private var undecodable: Set<UUID> = []
    /// Tracks whose cache file has been marked used this session.
    @ObservationIgnored private var marked: Set<UUID> = []
    @ObservationIgnored private var cacheLimit = AudioCacheLimit.effective()
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var tagTask: Task<Void, Never>?
    /// The songs a fill is still waiting for, which is what the bar counts.
    @ObservationIgnored private var fillPending: Set<UUID> = []
    /// Tracks imported with "also write the original": their source bookmark
    /// is kept until the tempo has been written into the file they came from.
    @ObservationIgnored private var originalsToTag: Set<UUID> = []
    @ObservationIgnored private var originalsWritten = 0
    @ObservationIgnored private var originalsUnchanged = 0
    @ObservationIgnored private var originalsFailed = 0
    private static let maxWorkers = 2
    /// Decodes for playback: one a fifth of a second typically, so two
    /// keep up with a mix being opened without starving the analysis.
    private static let maxDecoders = 2
    /// Rendering a shift takes the cores' worth of one track for a second or
    /// two; one at a time leaves room for playback and decoding.
    private static let maxShifters = 1
    /// Separating takes the GPU and a gigabyte of memory for a few seconds.
    private static let maxSeparators = 1

    /// One track at one pitch shift - or, with `stems`, its three stems
    /// there, decoded (at none) or shifted.
    struct ShiftKey: Hashable, Sendable {
        var track: UUID
        var pitch: PitchShift
        var stems = false
    }

    private enum SeparationOutcome: Sendable {
        case separated(frames: Int, waveforms: [Waveform])
        case cancelled
        case failed(String)
    }

    private enum ShiftOutcome: Sendable {
        case rendered
        case cancelled
        case failed(String)
    }

    let workspace: Workspace
    var cacheDirectory: URL { workspace.cache }
    private var libraryURL: URL { workspace.libraryFile }

    init(workspace: Workspace) {
        self.workspace = workspace
        load()
        for track in tracks where needsWork(track) { queue.append(track.id) }
        pump()
        measureMissingLoudness()
        // The limit, and whether it applies at all, are set in the
        // Settings window, which knows no library.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AudioCacheLimit.effective() != self.cacheLimit else { return }
                self.cacheLimit = AudioCacheLimit.effective()
                self.enforceCacheLimit()
            }
        }
    }

    /// Before the working directory closes: no more decodes start, and
    /// whoever waits for audio hears that none is coming.
    func shutdown() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        fillPending.removeAll()
        cacheFill = nil
        decodeQueue.removeAll()
        shiftQueue.removeAll()
        separateQueue.removeAll()
        for task in separateTasks.values { task.cancel() }
        let waitingSeparations = separationWaiters
        separationWaiters.removeAll()
        for done in waitingSeparations.values.joined() { done(false) }
        let waiting = waiters
        waiters.removeAll()
        for done in waiting.values.joined() { done(nil) }
        let waitingShifts = shiftWaiters
        shiftWaiters.removeAll()
        for done in waitingShifts.values.joined() { done(nil) }
    }

    // MARK: - Lookup

    func track(_ id: UUID) -> Track? {
        index[id].map { tracks[$0] }
    }

    func grid(for id: UUID) -> SourceGrid? {
        guard var grid = track(id)?.grid else { return nil }
        grid.soundEndSeconds = loudness[id]?.soundEndSeconds
        return grid
    }

    /// The decoded audio, if it is in the cache. Maps the cache file on
    /// first use. Nil does not start a decode; `prepare` does.
    func audio(for id: UUID) -> AudioFrames? {
        // Read for the dependency: a view that got nil here is drawn again
        // when the decode it waits for ends.
        _ = decoding
        if let loaded = frames[id] { return loaded }
        let url = cacheURL(id)
        guard FileManager.default.fileExists(atPath: url.path), let mapped = try? AudioFrames(mapping: url) else { return nil }
        frames[id] = mapped
        markUsed(id)
        return mapped
    }

    // MARK: - Audio on demand

    /// Decodes, in the background, the audio of tracks that have none in
    /// the cache. `first` puts them ahead of what is already waiting. A
    /// track still being imported or analysed gets its audio from that work.
    func prepare(_ ids: some Sequence<UUID>, first: Bool = false) {
        for id in ids {
            guard let track = track(id), track.state != .failed, !undecodable.contains(id) else {
                serve(id, nil)
                continue
            }
            if frames[id] != nil || FileManager.default.fileExists(atPath: cacheURL(id).path) {
                if waiters[id] != nil { serve(id, audio(for: id)) }
                continue
            }
            guard !busy.contains(id), !queue.contains(id) else { continue }
            if decoding.contains(id) {
                if first, let i = decodeQueue.firstIndex(of: id) {
                    decodeQueue.remove(at: i)
                    decodeQueue.insert(id, at: 0)
                }
                continue
            }
            decoding.insert(id)
            if first { decodeQueue.insert(id, at: 0) } else { decodeQueue.append(id) }
        }
        pumpDecodes()
    }

    /// Calls `done` with the track's audio once it is in the cache - at once
    /// if it is - or with nil if it cannot be had.
    func whenReady(_ id: UUID, _ done: @escaping (AudioFrames?) -> Void) {
        if let audio = audio(for: id) {
            done(audio)
            return
        }
        waiters[id, default: []].append(done)
        prepare([id], first: true)
    }

    /// Waits until every one of these tracks has its audio; returns those
    /// that could not be decoded.
    func ready(_ ids: Set<UUID>) async -> [UUID] {
        prepare(ids)
        var missing: [UUID] = []
        for id in ids {
            let audio = await withCheckedContinuation { continuation in
                whenReady(id) { continuation.resume(returning: $0) }
            }
            if audio == nil { missing.append(id) }
        }
        return missing
    }

    // MARK: - Key shifts

    /// The track's audio at a pitch shift, if it has been rendered; the
    /// plain audio for none. Nil does not start a render; `prepareShifts` does.
    func audio(for id: UUID, pitch: PitchShift) -> AudioFrames? {
        guard !pitch.isNone else { return audio(for: id) }
        _ = shifting
        let key = ShiftKey(track: id, pitch: pitch)
        if let loaded = shiftedFrames[key] { return loaded }
        let url = shiftedURL(key)
        guard FileManager.default.fileExists(atPath: url.path), let mapped = try? AudioFrames(mapping: url) else { return nil }
        shiftedFrames[key] = mapped
        return mapped
    }

    /// Renders, in the background, the shifts that are not in the cache.
    /// A track without decoded audio is decoded first; the render follows
    /// when the mix asks again after the decode.
    func prepareShifts(_ keys: some Sequence<ShiftKey>, first: Bool = false) {
        var missingAudio: [UUID] = []
        var unseparated: [UUID] = []
        for key in keys where !key.pitch.isNone || key.stems {
            guard track(key.track) != nil, !unshiftable.contains(key) else {
                serveShift(key, nil)
                continue
            }
            if isRendered(key) {
                if shiftWaiters[key] != nil { serveShift(key, rendered(key)) }
                continue
            }
            guard audio(for: key.track) != nil else {
                missingAudio.append(key.track)
                continue
            }
            // Stems come from the stored ones; without those, separation
            // first, and the stems are asked for again when it is done.
            if key.stems && !hasStems(key.track) {
                unseparated.append(key.track)
                continue
            }
            if shifting.contains(key) {
                if first, let i = shiftQueue.firstIndex(of: key) {
                    shiftQueue.remove(at: i)
                    shiftQueue.insert(key, at: 0)
                }
                continue
            }
            shifting.insert(key)
            if first { shiftQueue.insert(key, at: 0) } else { shiftQueue.append(key) }
        }
        if !missingAudio.isEmpty { prepare(missingAudio, first: first) }
        if !unseparated.isEmpty { separate(unseparated) }
        dropUnwantedShifts()
        pumpShifts()
    }

    /// Whether a shift's file - or a stems key's three - are in the cache.
    private func isRendered(_ key: ShiftKey) -> Bool {
        guard key.stems else {
            return shiftedFrames[key] != nil || FileManager.default.fileExists(atPath: shiftedURL(key).path)
        }
        return stemFrames[key] != nil || Stem.stored.allSatisfy {
            FileManager.default.fileExists(atPath: stemCacheURL(key.track, $0, key.pitch).path)
        }
    }

    /// What a waiter for `key` is handed: the shifted song, or for stems
    /// the drums - something, as a sign they are all there.
    private func rendered(_ key: ShiftKey) -> AudioFrames? {
        key.stems ? stems(for: key.track, pitch: key.pitch)?.drums : audio(for: key.track, pitch: key.pitch)
    }

    /// Forgets queued shifts no clip plays any more and stops renders of
    /// them - unless a bounce is waiting for one.
    private func dropUnwantedShifts() {
        guard let wanted = wantedShifts?() else { return }
        func unwanted(_ key: ShiftKey) -> Bool { !wanted.contains(key) && shiftWaiters[key] == nil }
        for key in shiftQueue where unwanted(key) { shifting.remove(key) }
        shiftQueue.removeAll(where: unwanted)
        for (key, task) in shiftTasks where unwanted(key) { task.cancel() }
    }

    /// Waits until every one of these shifts is rendered; returns those that
    /// could not be.
    func readyShifts(_ keys: Set<ShiftKey>) async -> [ShiftKey] {
        let wanted = keys.filter { !$0.pitch.isNone || $0.stems }
        // The plain audio first: a shift is rendered from it.
        let undecoded = Set(await ready(Set(wanted.map(\.track))))
        var missing = wanted.filter { undecoded.contains($0.track) }
        for key in wanted where !undecoded.contains(key.track) {
            let audio = await withCheckedContinuation { continuation in
                if let audio = self.rendered(key) {
                    continuation.resume(returning: Optional(audio))
                } else {
                    shiftWaiters[key, default: []].append { continuation.resume(returning: $0) }
                    prepareShifts([key], first: true)
                }
            }
            if audio == nil { missing.insert(key) }
        }
        return Array(missing)
    }

    private func serveShift(_ key: ShiftKey, _ audio: AudioFrames?) {
        guard let waiting = shiftWaiters.removeValue(forKey: key) else { return }
        for done in waiting { done(audio) }
    }

    private func pumpShifts() {
        while shifters < Self.maxShifters, !shiftQueue.isEmpty {
            let key = shiftQueue.removeFirst()
            guard let source = audio(for: key.track) else {
                // Its audio went (the size limit) while it waited.
                shifting.remove(key)
                serveShift(key, nil)
                continue
            }
            let destination = shiftedURL(key)
            let stems = Stem.stored.map {
                (stored: storedStemURL(key.track, $0), plain: stemCacheURL(key.track, $0, .none),
                 shifted: stemCacheURL(key.track, $0, key.pitch))
            }
            shifters += 1
            let work = Task.detached(priority: .userInitiated) { () -> ShiftOutcome in
                do {
                    if key.stems {
                        // Each stem decoded from the stored one if the cache
                        // lost it, then shifted like the song.
                        for stem in stems {
                            try Task.checkCancellation()
                            if !FileManager.default.fileExists(atPath: stem.plain.path) {
                                try AudioCache.decode(stem.stored, to: stem.plain)
                            }
                            if !key.pitch.isNone && !FileManager.default.fileExists(atPath: stem.shifted.path) {
                                try KeyShifter.render(try AudioFrames(mapping: stem.plain), semitones: key.pitch.amount,
                                                      to: stem.shifted)
                            }
                        }
                        return .rendered
                    }
                    guard !FileManager.default.fileExists(atPath: destination.path) else { return .rendered }
                    try KeyShifter.render(source, semitones: key.pitch.amount, to: destination)
                    return .rendered
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            shiftTasks[key] = work
            Task {
                let outcome = await work.value
                shiftTasks[key] = nil
                shifters -= 1
                shifting.remove(key)
                if case .cancelled = outcome {
                    // Nobody wants it any more; asked for again, it starts over.
                    serveShift(key, nil)
                    pumpShifts()
                    return
                }
                let shifted = track(key.track) == nil ? nil : rendered(key)
                if shifted == nil {
                    unshiftable.insert(key)
                    if case .failed(let failure) = outcome, let track = track(key.track) {
                        lastError = key.stems
                            ? "The stems of “\(track.displayName)” could not be prepared: \(failure)"
                            : "“\(track.displayName)” could not be shifted by \(key.pitch.label): \(failure)"
                    }
                }
                serveShift(key, shifted)
                enforceCacheLimit()
                if shifted != nil { onTrackChange?(key.track) }
                pumpShifts()
            }
        }
    }

    private func shiftedURL(_ key: ShiftKey) -> URL {
        cacheDirectory.appendingPathComponent(CacheSweep.shiftedName(key.track, pitch: key.pitch))
    }

    /// The key-shift files and decoded stems in the cache, by track.
    private func shiftedFiles() -> [UUID: [URL]] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) else { return [:] }
        var files: [UUID: [URL]] = [:]
        for name in names where name.hasSuffix(".f32") {
            guard let id = CacheSweep.shift(in: name)?.id ?? CacheSweep.stem(in: name)?.id else { continue }
            files[id, default: []].append(cacheDirectory.appendingPathComponent(name))
        }
        return files
    }

    /// Lets go of a track's shifts and decoded stems and deletes their files.
    private func removeShifts(of id: UUID, files: [URL]) {
        for key in shiftedFrames.keys where key.track == id { shiftedFrames[key] = nil }
        for key in stemFrames.keys where key.track == id { stemFrames[key] = nil }
        for url in files { try? FileManager.default.removeItem(at: url) }
    }

    private func serve(_ id: UUID, _ audio: AudioFrames?) {
        guard let waiting = waiters.removeValue(forKey: id) else { return }
        for done in waiting { done(audio) }
    }

    private func pumpDecodes() {
        while decoders < Self.maxDecoders, !decodeQueue.isEmpty {
            let id = decodeQueue.removeFirst()
            guard let track = track(id), !busy.contains(id) else {
                decoding.remove(id)
                continue
            }
            let copy = songURL(track)
            let reference = track.isReference
            let cache = cacheURL(id)
            decoders += 1
            Task {
                let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    guard !FileManager.default.fileExists(atPath: cache.path) else { return nil }
                    let access = copy.startAccessingSecurityScopedResource()
                    defer { if access { copy.stopAccessingSecurityScopedResource() } }
                    guard FileManager.default.fileExists(atPath: copy.path) else {
                        return reference ? "\(copy.path) is no longer there."
                                         : "\(copy.lastPathComponent) is missing from the Audio folder."
                    }
                    do {
                        try AudioCache.decode(copy, to: cache)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                decoders -= 1
                decoding.remove(id)
                noteFilled(id)
                let decoded = self.track(id) == nil ? nil : audio(for: id)
                if decoded == nil {
                    undecodable.insert(id)
                    if let failure, let track = self.track(id) {
                        lastError = "“\(track.displayName)” could not be decoded for playback: \(failure)"
                    }
                }
                serve(id, decoded)
                enforceCacheLimit()
                if decoded != nil { onTrackChange?(id) }
                pumpDecodes()
            }
        }
    }

    /// Marks a track's cache file as used now - its modification date,
    /// which is what the size limit orders by. Once a session is enough.
    private func markUsed(_ id: UUID) {
        guard marked.insert(id).inserted else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheURL(id).path)
    }

    /// Removes the audio used longest ago until the cache fits its limit
    /// (see AudioCacheLimit). Audio in use stays.
    func enforceCacheLimit() {
        // Lifted: nothing to weigh. Checked here rather than in the loop,
        // which stats every track's cache file after every decode.
        guard cacheLimit != .max else { return }
        var entries: [AudioCacheLimit.Entry] = []
        // A track's shifts weigh with it and go with it: without its
        // audio no new one can be rendered anyway.
        let shifts = shiftedFiles()
        for track in tracks {
            let values = try? cacheURL(track.id).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values?.fileSize else { continue }
            let shiftBytes = (shifts[track.id] ?? []).reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            entries.append(AudioCacheLimit.Entry(id: track.id, bytes: size + shiftBytes,
                                                 lastUse: values?.contentModificationDate ?? .distantPast))
        }
        let pinned = pinnedTracks().union(decoding).union(busy).union(queue).union(shifting.map(\.track))
            .union(separating.keys)
        for id in AudioCacheLimit.evictions(entries, limit: cacheLimit, keeping: pinned) {
            // A mapping already handed out stays valid; the space comes back
            // when the last one is let go.
            frames[id] = nil
            marked.remove(id)
            try? FileManager.default.removeItem(at: cacheURL(id))
            removeShifts(of: id, files: shifts[id] ?? [])
        }
    }

    // MARK: - Stems

    /// The track's three stems at a pitch, decoded (and shifted) in the
    /// cache, if they are all there. Nil does not start anything;
    /// `prepareShifts` with a stems key does.
    func stems(for id: UUID, pitch: PitchShift) -> StemAudio? {
        _ = shifting
        _ = separating
        guard track(id)?.stems?.isCurrent == true else { return nil }
        let key = ShiftKey(track: id, pitch: pitch, stems: true)
        if let loaded = stemFrames[key] { return loaded }
        let mapped = Stem.stored.compactMap { try? AudioFrames(mapping: stemCacheURL(id, $0, pitch)) }
        guard mapped.count == 3 else { return nil }
        let audio = StemAudio(drums: mapped[0], bass: mapped[1], vocals: mapped[2])
        stemFrames[key] = audio
        return audio
    }

    /// Whether the track has stored stems this separator made, from the song
    /// as it decodes now.
    func hasStems(_ id: UUID) -> Bool {
        guard let stems = track(id)?.stems, stems.isCurrent,
              Stem.stored.allSatisfy({ FileManager.default.fileExists(atPath: storedStemURL(id, $0).path) }) else {
            return false
        }
        // Decoded again into a different length, the song no longer lines up.
        if let audio = audio(for: id), audio.frameCount != stems.frames { return false }
        return true
    }

    /// Separates, in the background, the tracks that have no stems yet. A
    /// track without decoded audio is decoded first.
    func separate(_ ids: some Sequence<UUID>) {
        for id in ids {
            guard track(id) != nil, !unseparable.contains(id), separating[id] == nil else { continue }
            if hasStems(id) {
                serveSeparation(id, true)
                continue
            }
            separating[id] = 0
            separateQueue.append(id)
        }
        pumpSeparations()
    }

    /// Stops a track's separation, queued or running; nothing is kept.
    func cancelSeparation(_ id: UUID) {
        separateQueue.removeAll { $0 == id }
        if let task = separateTasks[id] {
            task.cancel()
        } else if separating.removeValue(forKey: id) != nil {
            serveSeparation(id, false)
        }
    }

    /// Deletes a track's stems - the stored ones and the cache's - for the
    /// space. A clip that wants them separates it again.
    func deleteStems(_ id: UUID) {
        cancelSeparation(id)
        removeStemFiles(of: id)
        if let i = index[id], tracks[i].stems != nil {
            tracks[i].stems = nil
            save()
        }
        onTrackChange?(id)
    }

    /// Waits until every one of these tracks is separated; returns those
    /// that could not be.
    func readySeparations(_ ids: Set<UUID>) async -> [UUID] {
        var missing: [UUID] = []
        for id in ids {
            let done = await withCheckedContinuation { continuation in
                if hasStems(id) {
                    continuation.resume(returning: true)
                } else {
                    separationWaiters[id, default: []].append { continuation.resume(returning: $0) }
                    separate([id])
                }
            }
            if !done { missing.append(id) }
        }
        return missing
    }

    private func serveSeparation(_ id: UUID, _ done: Bool) {
        guard let waiting = separationWaiters.removeValue(forKey: id) else { return }
        for finish in waiting { finish(done) }
    }

    private func pumpSeparations() {
        while separators < Self.maxSeparators, !separateQueue.isEmpty {
            let id = separateQueue.removeFirst()
            guard track(id) != nil else {
                separating[id] = nil
                serveSeparation(id, false)
                continue
            }
            guard let source = audio(for: id) else {
                // Decoded first; it comes back to the front of the queue.
                whenReady(id) { [weak self] audio in
                    guard let self, self.separating[id] != nil else { return }
                    if audio == nil {
                        self.finishSeparation(id, .failed("its audio could not be decoded"))
                    } else {
                        self.separateQueue.insert(id, at: 0)
                        self.pumpSeparations()
                    }
                }
                continue
            }
            // Stems from an earlier separation, decoded or shifted, are of
            // the old ones.
            removeStemFiles(of: id, keepStored: true)
            let stored = Stem.stored.map { storedStemURL(id, $0) }
            let cached = Stem.stored.map { stemCacheURL(id, $0, .none) }
            let waves = Stem.allCases.map { stemWaveformURL(id, $0) }
            let holder = separatorModel
            // Held only while the separation runs, as long as the library.
            let report: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in
                    if self.separating[id] != nil { self.separating[id] = fraction }
                }
            }
            separators += 1
            let work = Task.detached(priority: .utility) { () -> SeparationOutcome in
                do {
                    let model = try holder.model()
                    let writers = try stored.map { try StemWriter(to: $0) }
                    do {
                        try StemSeparator.separate(source, model: model, progress: report) { stem, left, right, count in
                            try writers[stem].write(left: left, right: right, count: count)
                        }
                        for writer in writers { try writer.finish() }
                    } catch {
                        for writer in writers { writer.cancel() }
                        throw error
                    }
                    for (from, to) in zip(stored, cached) { try AudioCache.decode(from, to: to) }
                    let decoded = try cached.map { try AudioFrames(mapping: $0) }
                    let waveforms = Waveform.stems(song: source, StemAudio(drums: decoded[0], bass: decoded[1], vocals: decoded[2]))
                    for (waveform, url) in zip(waveforms, waves) { try? waveform.data().write(to: url) }
                    return .separated(frames: source.frameCount, waveforms: waveforms)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            separateTasks[id] = work
            Task {
                let outcome = await work.value
                separateTasks[id] = nil
                separators -= 1
                finishSeparation(id, outcome)
                if separateQueue.isEmpty && separators == 0 { separatorModel.release() }
                pumpSeparations()
            }
        }
        if separateQueue.isEmpty && separators == 0 { separatorModel.release() }
    }

    private func finishSeparation(_ id: UUID, _ outcome: SeparationOutcome) {
        separating[id] = nil
        guard let i = index[id] else {
            // Removed while it was being separated.
            removeStemFiles(of: id)
            serveSeparation(id, false)
            return
        }
        switch outcome {
        case .separated(let frames, let waveforms):
            tracks[i].stems = TrackStems(tag: StemSeparator.tag, frames: frames)
            stemWaveforms[id] = waveforms
            save()
            serveSeparation(id, true)
            enforceCacheLimit()
            onTrackChange?(id)
            // Stems a bounce waits for, at a pitch, can be made now.
            let waiting = shiftWaiters.keys.filter { $0.track == id && $0.stems }
            if !waiting.isEmpty { prepareShifts(waiting, first: true) }
        case .cancelled:
            removeStemFiles(of: id, keepStored: tracks[i].stems?.isCurrent == true)
            serveSeparation(id, false)
        case .failed(let failure):
            unseparable.insert(id)
            lastError = "“\(tracks[i].displayName)” could not be separated into stems: \(failure)"
            serveSeparation(id, false)
            for key in shiftWaiters.keys where key.track == id && key.stems { serveShift(key, nil) }
        }
    }

    /// A track's stems in the cache, at every pitch, and unless
    /// `keepStored` the stored ones too.
    private func removeStemFiles(of id: UUID, keepStored: Bool = false) {
        for key in stemFrames.keys where key.track == id { stemFrames[key] = nil }
        stemWaveforms[id] = nil
        if let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) {
            for name in names where CacheSweep.stem(in: name)?.id == id {
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(name))
            }
        }
        guard !keepStored else { return }
        for stem in Stem.stored { try? FileManager.default.removeItem(at: storedStemURL(id, stem)) }
    }

    /// Loads, or builds, the stems' waveforms of tracks that have stems, in
    /// the background; published in `stemWaveforms`. Built from the decoded
    /// stems; where the size limit took those, they are decoded first, and
    /// the next call - the mix rebuilds when they are back - builds them.
    func prepareStemWaveforms(_ ids: some Sequence<UUID>) {
        for id in Set(ids) where stemWaveforms[id] == nil && !stemWaveformLoads.contains(id) && hasStems(id) {
            let waves = Stem.allCases.map { stemWaveformURL(id, $0) }
            let stored = waves.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            let song = audio(for: id), parts = stems(for: id, pitch: .none)
            guard stored || (song != nil && parts != nil) else {
                if song == nil { prepare([id]) } else { prepareShifts([ShiftKey(track: id, pitch: .none, stems: true)]) }
                continue
            }
            stemWaveformLoads.insert(id)
            Task {
                let waveforms = await Task.detached(priority: .utility) { () -> [Waveform]? in
                    if stored {
                        let read = waves.compactMap { (try? Data(contentsOf: $0)).flatMap(Waveform.init(data:)) }
                        if read.count == waves.count { return read }
                    }
                    guard let song, let parts else { return nil }
                    let built = Waveform.stems(song: song, parts)
                    for (waveform, url) in zip(built, waves) { try? waveform.data().write(to: url) }
                    return built
                }.value
                stemWaveformLoads.remove(id)
                if let waveforms, track(id)?.stems?.isCurrent == true { stemWaveforms[id] = waveforms }
            }
        }
    }

    private func stemWaveformURL(_ id: UUID, _ stem: Stem) -> URL {
        cacheDirectory.appendingPathComponent(StemFiles.waveformName(id, stem))
    }

    private func storedStemURL(_ id: UUID, _ stem: Stem) -> URL {
        workspace.stems.appendingPathComponent(StemFiles.storedName(id, stem))
    }

    private func stemCacheURL(_ id: UUID, _ stem: Stem, _ pitch: PitchShift) -> URL {
        cacheDirectory.appendingPathComponent(StemFiles.cachedName(id, stem, pitch: pitch))
    }

    private func cacheURL(_ id: UUID) -> URL { cacheDirectory.appendingPathComponent("\(id.uuidString).f32") }
    private func waveformURL(_ id: UUID) -> URL { cacheDirectory.appendingPathComponent("\(id.uuidString).wave") }
    private func loudnessURL(_ id: UUID) -> URL { cacheDirectory.appendingPathComponent("\(id.uuidString).loud") }

    // MARK: - Import and removal

    /// Adds files, and the audio files inside folders, skipping any already
    /// imported. Each track gets its place in Audio/ at once; the copy itself
    /// is made in the background. Returns the ids of the tracks added.
    @discardableResult
    func importItems(_ urls: [URL], tagOriginals: Bool = false, copy: Bool = ImportCopy.current()) -> [UUID] {
        var added: [UUID] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            for file in AudioFiles.at(url) {
                let source = file.standardizedFileURL.path
                guard !tracks.contains(where: {
                    $0.sourcePath == source || workspace.url(forStoredPath: $0.path).standardizedFileURL.path == source
                }) else { continue }
                let title = file.deletingPathExtension().lastPathComponent
                var track: Track
                let inside = workspace.storedPath(for: file)
                if !inside.hasPrefix("/") {
                    // Already inside this working directory: nothing to copy.
                    track = Track(path: inside, bookmark: nil, title: title, artist: nil, durationSeconds: 0)
                } else if !copy, let bookmark = try? file.bookmarkData(options: .withSecurityScope,
                                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                    // Referred to where it lies; the bookmark is the lasting
                    // permission to read it. Without one it is copied after all.
                    track = Track(path: source, bookmark: bookmark, title: title, artist: nil, durationSeconds: 0)
                } else {
                    // Destinations still to be copied count as taken too, or
                    // two songs of the same name in one import would collide.
                    let planned = Set(tracks.map(\.path))
                    let destination = Workspace.uniqueDestination(for: file.lastPathComponent, in: workspace.audio) { candidate in
                        FileManager.default.fileExists(atPath: candidate.path)
                            || planned.contains(workspace.storedPath(for: candidate))
                    }
                    let bookmark = try? file.bookmarkData(options: .withSecurityScope,
                                                          includingResourceValuesForKeys: nil, relativeTo: nil)
                    track = Track(path: workspace.storedPath(for: destination), bookmark: bookmark,
                                  title: title, artist: nil, durationSeconds: 0)
                }
                track.sourcePath = source
                if tagOriginals { originalsToTag.insert(track.id) }
                tracks.append(track)
                added.append(track.id)
                algorithms[track.id] = BeatAlgorithm.current
                queue.append(track.id)
            }
        }
        reindex()
        save()
        pump()
        return added
    }

    /// Puts a track referenced by a mix back into the library, keeping its
    /// id so the mix's clips find it. A relative path is looked for in this
    /// working directory; if the song is not there, the track shows as failed.
    ///
    /// No bookmark comes with it, so an absolute path is only read where the
    /// sandbox already allows it. A song referred to where it lies is
    /// reachable through the library that imported it; in another working
    /// directory the track shows as failed and is imported again.
    func adopt(_ reference: TrackReference) {
        guard track(reference.id) == nil else { return }
        // The path comes out of a mix file, which anyone may have written.
        guard workspace.isStorable(reference.path) else { return }
        let title = URL(fileURLWithPath: reference.path).deletingPathExtension().lastPathComponent
        tracks.append(Track(id: reference.id, path: reference.path, bookmark: nil,
                            title: title, artist: nil, durationSeconds: 0))
        algorithms[reference.id] = BeatAlgorithm.current
        queue.append(reference.id)
        reindex()
        save()
        pump()
    }

    /// Removes tracks. Their cache goes; the copy in Audio/ goes to the
    /// Trash rather than away.
    func remove(_ ids: Set<UUID>) {
        let removed = tracks.filter { ids.contains($0.id) }
        tracks.removeAll { ids.contains($0.id) }
        let shifts = shiftedFiles()
        for track in removed {
            cancelSeparation(track.id)
            removeShifts(of: track.id, files: shifts[track.id] ?? [])
            for stem in Stem.stored { try? FileManager.default.removeItem(at: storedStemURL(track.id, stem)) }
            frames[track.id] = nil
            serve(track.id, nil)
            waveforms[track.id] = nil
            loudness[track.id] = nil
            try? FileManager.default.removeItem(at: cacheURL(track.id))
            try? FileManager.default.removeItem(at: waveformURL(track.id))
            try? FileManager.default.removeItem(at: loudnessURL(track.id))
            let copy = workspace.url(forStoredPath: track.path)
            let madeByUs = track.path.hasPrefix("Audio/") && track.sourcePath != copy.standardizedFileURL.path
            if madeByUs {
                try? FileManager.default.trashItem(at: copy, resultingItemURL: nil)
            }
        }
        queue.removeAll { ids.contains($0) }
        reindex()
        save()
    }

    /// How a mix refers to a track: by id and its path in the working
    /// directory. No bookmark of either kind - neither carries meaning on
    /// another Mac, and both carry a path from this one into the file.
    func reference(for id: UUID) -> TrackReference? {
        track(id).map { TrackReference(id: $0.id, path: $0.path) }
    }

    // MARK: - Beatgrid corrections

    /// Saves only when the correction actually changed: Return in an
    /// untouched tempo field used to rewrite the whole library file and
    /// rebuild every mix behind it.
    func setCorrection(_ id: UUID, bpm: Double?, firstBeatSeconds: Double?) {
        guard let i = index[id], tracks[i].setCorrection(bpm: bpm, firstBeatSeconds: firstBeatSeconds) else { return }
        save()
        onTrackChange?(id)
    }

    func resetCorrection(_ id: UUID) {
        guard let i = index[id], tracks[i].isCorrected else { return }
        tracks[i].manualBPM = nil
        tracks[i].manualFirstBeatSeconds = nil
        save()
        onTrackChange?(id)
    }

    // MARK: - Cue points

    func cuePoints(for id: UUID) -> [CuePoint] {
        track(id)?.cuePoints ?? []
    }

    /// Sets or moves cue `number`; `seconds` nil clears it. Saves only when
    /// something changed, for the reason `setCorrection` gives.
    func setCue(_ id: UUID, number: Int, seconds: Double?) {
        guard let i = index[id], tracks[i].setCue(number: number, seconds: seconds) else { return }
        save()
    }

    func clearCues(_ id: UUID) {
        guard let i = index[id], !tracks[i].cuePoints.isEmpty else { return }
        tracks[i].cuePoints = []
        save()
    }

    /// Analyses a track again, optionally near a tapped tempo. The
    /// correction is kept unless `clearCorrection` says otherwise - which is
    /// what "refine my tapped tempo" means: the analysis is asked to improve
    /// on the taps, so its answer has to be allowed to take effect.
    func reanalyse(_ id: UUID, nearBPM hint: Double? = nil, clearCorrection: Bool = false) {
        guard let i = index[id] else { return }
        if clearCorrection {
            tracks[i].manualBPM = nil
            tracks[i].manualFirstBeatSeconds = nil
        }
        tracks[i].state = .pending
        tracks[i].analysis = nil
        undecodable.remove(id)
        hints[id] = hint
        algorithms[id] = BeatAlgorithm.current
        if !queue.contains(id) { queue.append(id) }
        pump()
    }

    // MARK: - Writing tempos into the files

    /// Writes each track's tempo into its own file in the Audio folder -
    /// the copy Ultramix owns. Only on command, never on its own. A track
    /// without a tempo is left alone, and so is a file that already says the
    /// right thing.
    func writeBPMTags(_ ids: Set<UUID>) {
        guard !writingTags else { return }
        var jobs: [TagJob] = []
        var withoutTempo = 0
        for id in ids.sorted(by: { ($0.uuidString) < ($1.uuidString) }) {
            guard let track = track(id) else { continue }
            guard let bpm = track.bpm else { withoutTempo += 1; continue }
            jobs.append(TagJob(url: songURL(track), bpm: bpm))
        }
        guard !jobs.isEmpty else {
            notice = withoutTempo > 0
                ? "Nothing written: \(Self.count(withoutTempo, "track")) still without a measured tempo."
                : nil
            return
        }
        tagProgress = TagProgress(done: 0, total: jobs.count)
        tagTask = Task {
            // `writeTags` is nonisolated, so it runs off the main actor and
            // the window stays alive while the files are rewritten.
            let summary = await Self.writeTags(jobs) { done in
                self.tagProgress?.done = done
            }
            tagProgress = nil
            tagTask = nil
            notice = summary.message(withoutTempo: withoutTempo)
        }
    }

    /// Writes the tempos into the *original* files - the ones the songs were
    /// imported from - rather than into the copies in the working directory.
    ///
    /// `folder` is a folder the user has just chosen in an open panel, which
    /// is what grants a sandboxed app access to everything inside it. Only
    /// tracks whose recorded source lies in there are written; anything else
    /// is left alone, because the app has no business with it.
    func writeBPMTagsToOriginals(in folder: URL) {
        guard !writingTags else { return }
        let root = folder.standardizedFileURL.path
        var jobs: [TagJob] = []
        var withoutTempo = 0
        var outside = 0
        for track in tracks {
            guard let source = track.sourcePath else { outside += 1; continue }
            guard source == root || source.hasPrefix(root + "/") else { outside += 1; continue }
            guard let bpm = track.bpm else { withoutTempo += 1; continue }
            jobs.append(TagJob(url: URL(fileURLWithPath: source), bpm: bpm))
        }
        guard !jobs.isEmpty else {
            notice = "No original in \(folder.lastPathComponent) has a measured tempo yet."
            return
        }
        let access = folder.startAccessingSecurityScopedResource()
        tagProgress = TagProgress(done: 0, total: jobs.count)
        tagTask = Task {
            let summary = await Self.writeTags(jobs) { done in self.tagProgress?.done = done }
            if access { folder.stopAccessingSecurityScopedResource() }
            tagProgress = nil
            tagTask = nil
            var message = summary.message(withoutTempo: withoutTempo)
            if outside > 0 {
                message += " \(Self.count(outside, "track")) came from somewhere else and was left alone."
            }
            notice = message
        }
    }

    /// The folder to start the originals panel in: the deepest folder every
    /// recorded source path has in common, so one click usually covers the
    /// whole library.
    var commonSourceFolder: URL? {
        let paths = tracks.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        guard var shared = paths.first?.components(separatedBy: "/") else { return nil }
        for path in paths.dropFirst() {
            let parts = path.components(separatedBy: "/")
            var common: [String] = []
            for (a, b) in zip(shared, parts) where a == b { common.append(a) }
            shared = common
            if shared.count <= 1 { return nil }
        }
        return URL(fileURLWithPath: shared.joined(separator: "/"))
    }

    /// Stops after the file being written. Each file is replaced as a whole,
    /// so stopping leaves every one of them either old or new, never half.
    func cancelTagWriting() {
        tagTask?.cancel()
    }

    struct TagProgress: Equatable {
        var done: Int
        var total: Int
    }

    nonisolated private struct TagJob: Sendable {
        let url: URL
        let bpm: Double
    }

    nonisolated private struct TagSummary: Sendable {
        var written = 0
        var unchanged = 0
        var stopped = false
        var missing = 0
        var skipped: [String] = []
        var failed: [String] = []

        func message(withoutTempo: Int) -> String {
            var parts: [String] = []
            if stopped { parts.append("Stopped.") }
            parts.append(written > 0 ? "BPM written to \(Library.count(written, "file"))."
                                     : "No file needed changing.")
            if unchanged > 0 { parts.append("\(Library.count(unchanged, "file")) already said the same.") }
            if let reason = skipped.first {
                parts.append("\(Library.count(skipped.count, "file")) skipped: \(reason).")
            }
            if let reason = failed.first {
                parts.append("\(Library.count(failed.count, "file")) failed: \(reason)")
            }
            if missing > 0 { parts.append("\(Library.count(missing, "file")) could not be found.") }
            if withoutTempo > 0 {
                parts.append("\(Library.count(withoutTempo, "track")) has no measured tempo yet.")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Nonisolated, so the writing happens off the main actor. `report` is
    /// called at most a hundred times however long the list: a hop per file
    /// would be the expensive part of writing a small one.
    nonisolated private static func writeTags(_ jobs: [TagJob],
                                              report: @escaping @MainActor (Int) -> Void) async -> TagSummary {
        var summary = TagSummary()
        let step = max(1, jobs.count / 100)
        for (i, job) in jobs.enumerated() {
            if Task.isCancelled {
                summary.stopped = true
                break
            }
            // A song referred to where it lies is read and written with its
            // bookmark's permission; for anything else this does nothing.
            let access = job.url.startAccessingSecurityScopedResource()
            defer { if access { job.url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: job.url.path) else {
                summary.missing += 1
                continue
            }
            do {
                switch try TagWriter.writeBPM(job.bpm, to: job.url) {
                case .written: summary.written += 1
                case .unchanged: summary.unchanged += 1
                case .unsupported(let reason): summary.skipped.append(reason)
                }
            } catch {
                summary.failed.append(error.localizedDescription)
            }
            let done = i + 1
            if done % step == 0 || done == jobs.count {
                await report(done)
            }
        }
        return summary
    }

    nonisolated private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    // MARK: - Filling the cache

    /// What filling the cache has in front of it, so the warning can say it
    /// in figures rather than in adjectives.
    struct CacheFillPlan: Equatable {
        /// Songs that still have to be decoded.
        var songs = 0
        /// What decoding them adds, and what the Cache folder holds already.
        var addedBytes = 0
        var nowBytes = 0

        var isEmpty: Bool { songs == 0 }
        var totalBytes: Int { nowBytes + addedBytes }
    }

    /// The decoded audio is 44.1 kHz stereo float, so its size follows from
    /// the measured duration; what is there already is counted from the
    /// files themselves.
    func cacheFillPlan() -> CacheFillPlan {
        var plan = CacheFillPlan()
        let bytesPerFrame = MemoryLayout<Float>.size * AudioFrames.channels
        for track in tracks {
            if let size = (try? cacheURL(track.id).resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                plan.nowBytes += size
                continue
            }
            guard canDecode(track) else { continue }
            plan.songs += 1
            plan.addedBytes += Int(track.durationSeconds * AudioFrames.sampleRate) * bytesPerFrame
        }
        return plan
    }

    /// Decodes every song that has none in the cache, so that from then on
    /// nothing is decoded while the music plays.
    ///
    /// No worker of its own: the decode queue `prepare` already uses, two
    /// at a time, with the same error handling. An audition still jumps
    /// ahead, since `whenReady` asks `first`.
    func fillCache() {
        guard !fillingCache else { return }
        let ids = tracks.filter { track in
            canDecode(track) && !FileManager.default.fileExists(atPath: cacheURL(track.id).path)
        }.map(\.id)
        guard !ids.isEmpty else {
            notice = "Every song is decoded already."
            return
        }
        fillPending = Set(ids)
        cacheFill = TagProgress(done: 0, total: ids.count)
        prepare(ids)
    }

    /// Stops after the songs being decoded, which are then whole. What has
    /// been decoded stays; the setting stays on.
    func cancelCacheFill() {
        guard fillingCache else { return }
        // A song somebody is waiting for stays in the queue: an audition
        // asked for while the fill runs lands there too, and telling its
        // waiter that nothing is coming would silence it for good.
        let stopped = Set(decodeQueue.filter { fillPending.contains($0) && waiters[$0] == nil })
        decodeQueue.removeAll { stopped.contains($0) }
        for id in stopped { decoding.remove(id) }
        fillPending.removeAll()
        cacheFill = nil
        notice = "Stopped. \(Self.count(stopped.count, "song")) left undecoded."
    }

    /// One song decoded during a fill. Called from the decode lane whatever
    /// the outcome: a song that cannot be decoded must not leave the bar
    /// standing for ever.
    private func noteFilled(_ id: UUID) {
        guard let progress = cacheFill, fillPending.remove(id) != nil else { return }
        // Read out of a copy and written back whole: reading and writing
        // the same property in one expression is an exclusivity violation
        // and aborts the app on the first song.
        let total = progress.total
        cacheFill = TagProgress(done: total - fillPending.count, total: total)
        guard fillPending.isEmpty else { return }
        cacheFill = nil
        notice = "\(Self.count(total, "song")) decoded and kept."
    }

    /// Whether a track is one the decode queue would take at all.
    private func canDecode(_ track: Track) -> Bool {
        track.state != .failed && !undecodable.contains(track.id)
    }

    // MARK: - Background work

    private func needsWork(_ track: Track) -> Bool {
        switch track.state {
        case .pending, .running: return true
        case .failed: return false
        case .done:
            // A missing cache file is not work: the size limit removes them,
            // and playback decodes again what it needs. Missing waveforms are.
            let files = FileManager.default
            return (track.analysis?.isOutdated ?? true)
                || (track.key?.version ?? 0) < KeyAnalyzer.version
                || !files.fileExists(atPath: waveformURL(track.id).path)
                || (!files.fileExists(atPath: loudnessURL(track.id).path)
                    && !files.fileExists(atPath: cacheURL(track.id).path))
        }
    }

    private func pump() {
        while workers < Self.maxWorkers, !queue.isEmpty {
            let id = queue.removeFirst()
            guard index[id] != nil, !busy.contains(id) else { continue }
            workers += 1
            busy.insert(id)
            Task {
                await work(id)
                workers -= 1
                busy.remove(id)
                pump()
            }
        }
    }

    /// Measures the loudness of tracks analysed before loudness was
    /// measured: one at a time, from the cache they already have. Apart from
    /// `work`, which would mark each track busy, save the library and
    /// rebuild the mix for a file that changes neither.
    private func measureMissingLoudness() {
        let files = FileManager.default
        let jobs = tracks.filter { $0.state == .done && loudness[$0.id] == nil && !queue.contains($0.id) }
            .map { (id: $0.id, cache: cacheURL($0.id), file: loudnessURL($0.id)) }
            .filter { files.fileExists(atPath: $0.cache.path) }
        guard !jobs.isEmpty else { return }
        Task { [weak self] in
            for job in jobs {
                let profile = await Task.detached(priority: .utility) { () -> LoudnessProfile? in
                    guard let audio = try? AudioFrames(mapping: job.cache) else { return nil }
                    let profile = LoudnessProfile(audio: audio)
                    try? profile.data().write(to: job.file)
                    return profile
                }.value
                // The working directory may have been closed meanwhile.
                guard let self else { return }
                if let profile, self.track(job.id) != nil, self.loudness[job.id] == nil {
                    self.loudness[job.id] = profile
                    // With a loudness target on, a clip of this track plays
                    // at its own gain until the plan is built again.
                    self.onTrackChange?(job.id)
                }
            }
        }
    }

    nonisolated private struct WorkResult: Sendable {
        var copied = false
        var audio: AudioFrames?
        var waveform: Waveform?
        var loudness: LoudnessProfile?
        var analysis: TrackAnalysis?
        var key: KeyAnalysis?
        var failure: String?
    }

    private func work(_ id: UUID) async {
        guard let i = index[id] else { return }
        tracks[i].state = .running
        let track = tracks[i]
        let copy = songURL(track)
        let reference = track.isReference
        let source = sourceURL(track)
        let cache = cacheURL(id)
        let waveURL = waveformURL(id)
        let loudURL = loudnessURL(id)
        let hint = hints.removeValue(forKey: id)
        let algorithm = algorithms.removeValue(forKey: id) ?? track.analysis?.analyser ?? BeatAlgorithm.current
        let analyse = track.analysis?.isOutdated ?? true
        let findKey = (track.key?.version ?? 0) < KeyAnalyzer.version

        let result = await Task.detached(priority: .utility) { () -> WorkResult in
            var result = WorkResult()
            let files = FileManager.default
            // The song's own permission, for a song referred to where it lies.
            let access = copy.startAccessingSecurityScopedResource()
            defer { if access { copy.stopAccessingSecurityScopedResource() } }
            do {
                if reference {
                    guard files.fileExists(atPath: copy.path) || files.fileExists(atPath: cache.path) else {
                        throw LibraryError.originalMissing(track.title)
                    }
                } else if !files.fileExists(atPath: copy.path) {
                    guard let source else { throw LibraryError.originalMissing(track.title) }
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    guard files.fileExists(atPath: source.path) else { throw LibraryError.originalMissing(track.title) }
                    try files.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Copied under a temporary name and renamed at the end, so
                    // a copy cut short by quitting is never taken for the song.
                    let partial = copy.deletingLastPathComponent()
                        .appendingPathComponent(".\(copy.lastPathComponent).\(UUID().uuidString).partial")
                    try files.copyItem(at: source, to: partial)
                    try files.moveItem(at: partial, to: copy)
                    result.copied = true
                }
                if !files.fileExists(atPath: cache.path) {
                    try AudioCache.decode(copy, to: cache)
                }
                let audio = try AudioFrames(mapping: cache)
                result.audio = audio
                if let data = try? Data(contentsOf: waveURL), let stored = Waveform(data: data) {
                    result.waveform = stored
                } else {
                    // Not atomic, deliberately: a waveform cut short fails its
                    // size check on load and is simply built again.
                    let waveform = Waveform(audio: audio)
                    try? waveform.data().write(to: waveURL)
                    result.waveform = waveform
                }
                if let data = try? Data(contentsOf: loudURL), let stored = LoudnessProfile(data: data) {
                    result.loudness = stored
                } else {
                    let profile = LoudnessProfile(audio: audio)
                    try? profile.data().write(to: loudURL)
                    result.loudness = profile
                }
                if findKey {
                    result.key = KeyAnalyzer.analyze(audio)
                }
                if analyse {
                    switch algorithm {
                    case .ultramix:
                        result.analysis = try TempoAnalyzer.analyze(audio, hintBPM: hint)
                    case .beatThis:
                        result.analysis = try BeatThisAnalyzer.analyze(audio, hintBPM: hint, model: .bundled())
                    }
                }
            } catch {
                result.failure = error.localizedDescription
            }
            return result
        }.value

        var tags = TagReader.Tags()
        if track.artist == nil {
            let access = copy.startAccessingSecurityScopedResource()
            if FileManager.default.fileExists(atPath: copy.path) {
                tags = await TagReader.read(copy)
            }
            if access { copy.stopAccessingSecurityScopedResource() }
        }

        guard let j = index[id] else { return }
        if result.copied, !originalsToTag.contains(id) {
            // The copy exists now; the source bookmark has served its purpose.
            // Unless the original is still to be written - that needs it.
            tracks[j].bookmark = nil
        }
        if let audio = result.audio {
            frames[id] = audio
            markUsed(id)
            tracks[j].durationSeconds = audio.duration
        }
        serve(id, result.audio)
        if let waveform = result.waveform { waveforms[id] = waveform }
        if let profile = result.loudness { loudness[id] = profile }
        if let analysis = result.analysis { tracks[j].analysis = analysis }
        if let key = result.key { tracks[j].key = key }
        if let title = tags.title { tracks[j].title = title }
        if let artist = tags.artist { tracks[j].artist = artist }
        if let failure = result.failure {
            tracks[j].state = result.audio == nil || tracks[j].analysis == nil ? .failed : .done
            tracks[j].failure = failure
        } else {
            tracks[j].state = .done
            tracks[j].failure = nil
        }
        await tagOriginal(id)
        save()
        enforceCacheLimit()
        onTrackChange?(id)
    }

    /// Writes the tempo into the song file and into the file it was imported
    /// from, for a track imported with that box ticked.
    ///
    /// It happens here, the moment the tempo is known, because this is while
    /// the permission the import panel gave for the original still holds;
    /// afterwards the bookmark is dropped like any other.
    private func tagOriginal(_ id: UUID) async {
        guard originalsToTag.contains(id), let i = index[id] else { return }
        defer {
            originalsToTag.remove(id)
            // A song referred to where it lies keeps its bookmark: it is the
            // permission to read it at all.
            if let i = index[id], !tracks[i].isReference { tracks[i].bookmark = nil }
            if originalsToTag.isEmpty && (originalsWritten + originalsUnchanged + originalsFailed) > 0 {
                notice = "BPM written into \(Self.count(originalsWritten, "song")) and the files they came from."
                    + (originalsUnchanged > 0 ? " \(Self.count(originalsUnchanged, "song")) already said the same." : "")
                    + (originalsFailed > 0 ? " \(Self.count(originalsFailed, "file")) could not be written." : "")
                originalsWritten = 0
                originalsUnchanged = 0
                originalsFailed = 0
            }
        }
        guard tracks[i].state == .done, let bpm = tracks[i].bpm, let source = sourceURL(tracks[i]) else {
            if tracks[i].state == .failed { originalsFailed += 1 }
            return
        }
        let copy = workspace.url(forStoredPath: tracks[i].path)
        if tracks[i].isReference {
            // The original is the song: one file, written once.
            let song = songURL(tracks[i])
            let outcome = await Task.detached(priority: .utility) { () -> TagWriter.Outcome? in
                let access = song.startAccessingSecurityScopedResource()
                defer { if access { song.stopAccessingSecurityScopedResource() } }
                return try? TagWriter.writeBPM(bpm, to: song)
            }.value
            switch outcome {
            case .written: originalsWritten += 1
            case .unchanged: originalsUnchanged += 1
            default: originalsFailed += 1
            }
            return
        }
        let outcome = await Task.detached(priority: .utility) { () -> TagWriter.Outcome? in
            // The copy needs no permission; the original does, and only the
            // bookmark from the import panel can give it.
            _ = try? TagWriter.writeBPM(bpm, to: copy)
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            return source == copy ? .unchanged : (try? TagWriter.writeBPM(bpm, to: source))
        }.value
        switch outcome {
        case .written: originalsWritten += 1
        case .unchanged: originalsUnchanged += 1
        default: originalsFailed += 1
        }
    }

    /// Where a track's song is. For a copy, in the working directory; for a
    /// song referred to where it lies, wherever its bookmark finds it now -
    /// a song moved on the same drive is followed, and its path updated.
    /// The URL is security-scoped then: wrap each read in
    /// start/stopAccessingSecurityScopedResource (harmless for a copy).
    private func songURL(_ track: Track) -> URL {
        guard track.isReference, let bookmark = track.bookmark else {
            return workspace.url(forStoredPath: track.path)
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return URL(fileURLWithPath: track.path)
        }
        let path = url.standardizedFileURL.path
        if let i = index[track.id], stale || path != track.path {
            if stale {
                let access = url.startAccessingSecurityScopedResource()
                if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil, relativeTo: nil) {
                    tracks[i].bookmark = fresh
                }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            if path != track.path {
                tracks[i].path = path
                tracks[i].sourcePath = path
            }
            save()
        }
        return url
    }

    /// The original a copy is made from: the bookmark taken at import
    /// (refreshed when stale), or the recorded source path when there is no
    /// bookmark. Only needed while the copy does not exist yet.
    private func sourceURL(_ track: Track) -> URL? {
        if let bookmark = track.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale, let i = index[track.id] {
                    let access = url.startAccessingSecurityScopedResource()
                    tracks[i].bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                               includingResourceValuesForKeys: nil, relativeTo: nil)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
                return url
            }
        }
        return track.sourcePath.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Persistence

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        let stored: [Track]
        do {
            stored = try Track.decodeLibrary(data)
        } catch {
            // Never start empty on top of a file that could not be read: the
            // first save would replace it. Move it aside and say so.
            let aside = workspace.root.appendingPathComponent("Ultramix Library (unreadable \(Int(Date().timeIntervalSince1970))).json")
            try? FileManager.default.moveItem(at: libraryURL, to: aside)
            lastError = "The library could not be read and was set aside as “\(aside.lastPathComponent)”: \(error.localizedDescription)"
            return
        }
        tracks = stored
        reindex()
        sweep()
        for track in tracks {
            if let data = try? Data(contentsOf: waveformURL(track.id)), let waveform = Waveform(data: data) {
                waveforms[track.id] = waveform
            }
            if let data = try? Data(contentsOf: loudnessURL(track.id)), let profile = LoudnessProfile(data: data) {
                loudness[track.id] = profile
            }
        }
    }

    /// Deletes cache files that belong to no track (see CacheSweep), and
    /// copies into Audio/ that an earlier session left unfinished.
    ///
    /// Only from `load`, after the library file was read without error and
    /// before background work starts. Both matter: a library that could not
    /// be read looks like an empty one, and a decode in progress owns a
    /// ".partial" file the sweep would take.
    private func sweep() {
        let files = FileManager.default
        if let names = try? files.contentsOfDirectory(atPath: cacheDirectory.path) {
            for name in CacheSweep.orphans(among: names, keeping: Set(tracks.map(\.id))) {
                try? files.removeItem(at: cacheDirectory.appendingPathComponent(name))
            }
        }
        if let names = try? files.contentsOfDirectory(atPath: workspace.stems.path) {
            for name in CacheSweep.stemOrphans(among: names, keeping: Set(tracks.map(\.id))) {
                try? files.removeItem(at: workspace.stems.appendingPathComponent(name))
            }
        }
        if let names = try? files.contentsOfDirectory(atPath: workspace.audio.path) {
            for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
                try? files.removeItem(at: workspace.audio.appendingPathComponent(name))
            }
        }
    }

    private func save() {
        do {
            let data = try Track.encodeLibrary(tracks)
            try SafeWrite.replace(libraryURL) { try data.write(to: $0) }
        } catch {
            lastError = "The library could not be saved: \(error.localizedDescription)"
        }
    }
}

/// The Demucs network for a round of separations: loaded by the first,
/// kept while more are queued, let go when the queue is empty - it holds
/// about a gigabyte while loaded.
private nonisolated final class SeparatorModel: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: DemucsModel?

    func model() throws -> DemucsModel {
        try lock.withLock {
            if let loaded { return loaded }
            let model = try DemucsModel.bundled()
            loaded = model
            return model
        }
    }

    func release() {
        lock.withLock { loaded = nil }
    }
}
