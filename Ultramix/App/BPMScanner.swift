//
//  BPMScanner.swift
//  Ultramix
//
//  Measures the tempo of songs where they lie and writes it into their own
//  tags - nothing copied, no library, no working directory. Decoded audio goes
//  into the app's temporary folder one file at a time and is deleted at once.
//
//  A file that already carries a BPM is not measured again unless asked. A row
//  says what is true of the *file*, so it reads "Tagged" either way; the
//  confidence column says which - a percentage means measured in this pass.
//
//  Permission: what is held is the thing the user handed over, the folder or
//  the file, and a folder covers everything inside it. Gathering runs off the
//  main actor.
//

import Foundation
import Observation

@Observable
final class BPMScanner {
    struct Item: Identifiable, Equatable {
        enum State: String, Equatable {
            case queued = "Queued"
            case running = "Measuring…"
            /// The file carries the tempo, measured now or already there.
            case tagged = "Tagged"
            /// Measured, but the format has nowhere to keep it.
            case untaggable = "No BPM field"
            case failed = "Failed"
        }

        let id = UUID()
        let url: URL
        var name: String
        var state: State = .queued
        var bpm: Double?
        var confidence: Double?
        /// What the file's tag says now - the measured value once it is
        /// written, or what was already in there for a skipped file.
        var tag: String?
        var note: String?
        /// The tempo was set by hand in this window.
        var corrected = false

        /// Unmeasured files sort to the end rather than refusing to sort.
        var bpmSortValue: Double { bpm ?? 0 }
        var confidenceSortValue: Double { confidence ?? -1 }
        var stateSortValue: String { state.rawValue }
    }

    private(set) var items: [Item] = []
    /// Measure files that already carry a BPM tag instead of skipping them.
    var measureTagged = false
    private(set) var isScanning = false
    /// True while a dropped folder is still being walked.
    private(set) var isGathering = false

    /// What the user handed over, with the sandbox's permission held for as
    /// long as the list lives.
    @ObservationIgnored private var roots: [URL] = []

    @ObservationIgnored private var index: [UUID: Int] = [:]
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var workers = 0
    @ObservationIgnored private var stopping = false

    /// Whether the mix is playing. A scan gives way to it - see `workerCount`.
    /// Set by whoever owns both (AppModel); on its own the scanner assumes
    /// nothing is playing.
    @ObservationIgnored var isMixPlaying: () -> Bool = { false }

    /// How many files are measured at once.
    ///
    /// A scan is a batch job with nothing else going on, so it may have the
    /// machine: the performance cores, less two, so the window and the rest
    /// of the system stay responsive. While a mix plays it drops back to
    /// two, the number the library uses - a scan that made the transport
    /// stutter would be a bad bargain whatever it saved.
    private var workerCount: Int {
        if isMixPlaying() { return 2 }
        return min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    var progress: (done: Int, total: Int) {
        (items.filter { $0.state != .queued && $0.state != .running }.count, items.count)
    }

    var summary: String {
        guard !items.isEmpty else { return "" }
        let tagged = items.filter { $0.state == .tagged }.count
        let measured = items.filter { $0.confidence != nil }.count
        let untaggable = items.filter { $0.state == .untaggable }.count
        let failed = items.filter { $0.state == .failed }.count
        var parts = ["\(Self.count(items.count, "file"))"]
        if tagged > 0 { parts.append("\(tagged) with a BPM (\(measured) measured here)") }
        if untaggable > 0 { parts.append("\(untaggable) without a BPM field") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    // MARK: - The list

    /// Adds files, and the songs inside folders, skipping what is already
    /// in the list.
    func add(_ urls: [URL]) {
        for url in urls where url.startAccessingSecurityScopedResource() {
            roots.append(url)
        }
        isGathering = true
        stopping = false
        Task {
            let found = await Task.detached(priority: .userInitiated) { urls.flatMap { AudioFiles.at($0) } }.value
            var known = Set(items.map(\.url.standardizedFileURL.path))
            for file in found {
                let path = file.standardizedFileURL.path
                guard !known.contains(path) else { continue }
                known.insert(path)
                let item = Item(url: file, name: file.deletingPathExtension().lastPathComponent)
                items.append(item)
                queue.append(item.id)
            }
            reindex()
            isGathering = false
            pump()
        }
    }

    /// Puts every file back in the queue - after turning "measure tagged
    /// files" on, or to try failed ones again.
    func scanAgain() {
        stopping = false
        for i in items.indices where items[i].state != .running {
            items[i].state = .queued
            items[i].note = nil
            queue.append(items[i].id)
        }
        pump()
    }

    /// Stops after the files being measured. What was still waiting stays
    /// waiting - "Scan Again" picks it up where this left off.
    func stop() {
        stopping = true
        queue.removeAll()
        isScanning = workers > 0
    }

    func clear() {
        stopAudition()
        stop()
        items.removeAll()
        index.removeAll()
        for url in roots { url.stopAccessingSecurityScopedResource() }
        roots.removeAll()
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    }

    func item(_ id: UUID) -> Item? {
        index[id].map { items[$0] }
    }

    // MARK: - Correcting by hand

    /// Writes a tempo the user settled on into the file, in place of what
    /// was measured or found there.
    func correct(_ id: UUID, bpm value: Double) {
        guard let i = index[id], items[i].state != .running else { return }
        let bpm = (min(max(value, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound) * 100).rounded() / 100
        let url = items[i].url
        items[i].state = .running
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result in
                do {
                    switch try TagWriter.writeBPM(bpm, to: url) {
                    case .written, .unchanged:
                        return Result(state: .tagged, bpm: bpm, tag: TagWriter.readBPM(url))
                    case .unsupported(let reason):
                        return Result(state: .untaggable, bpm: bpm, tag: TagWriter.readBPM(url), note: reason)
                    }
                } catch {
                    return Result(state: .failed, bpm: bpm, tag: TagWriter.readBPM(url), note: error.localizedDescription)
                }
            }.value
            guard let i = index[id] else { return }
            items[i].state = result.state
            items[i].bpm = result.bpm
            items[i].confidence = nil
            items[i].tag = result.tag
            items[i].note = result.note
            items[i].corrected = true
        }
    }

    // MARK: - Listening

    /// The song being auditioned for tapping along, decoded into the
    /// temporary folder for as long as it is.
    private(set) var auditionID: UUID?
    private(set) var isPreparingAudition = false
    @ObservationIgnored private var auditionFrames: AudioFrames?
    @ObservationIgnored private var auditionFile: URL?
    /// Made on first use: an audio engine is not started for a window that
    /// is only ever used to scan.
    @ObservationIgnored private var player: PreviewPlayer?

    var preview: PreviewPlayer {
        if let player { return player }
        let made = PreviewPlayer()
        player = made
        return made
    }

    /// Plays a song from a third of the way in - past the intro, where the
    /// beat is.
    func audition(_ id: UUID) {
        guard let i = index[id] else { return }
        if auditionID == id, let frames = auditionFrames {
            preview.play(frames, track: id, fromSeconds: frames.duration / 3)
            return
        }
        stopAudition()
        let url = items[i].url
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultramix-listen-\(UUID().uuidString).f32")
        auditionID = id
        auditionFile = temporary
        isPreparingAudition = true
        Task {
            let frames = await Task.detached(priority: .userInitiated) { () -> AudioFrames? in
                do {
                    try AudioCache.decode(url, to: temporary)
                    return try AudioFrames(mapping: temporary)
                } catch {
                    return nil
                }
            }.value
            // Asked for another song, or stopped, while this one decoded.
            guard auditionID == id, auditionFile == temporary else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            isPreparingAudition = false
            guard let frames else {
                stopAudition()
                return
            }
            auditionFrames = frames
            preview.play(frames, track: id, fromSeconds: frames.duration / 3)
        }
    }

    func stopAudition() {
        player?.stop()
        // The mapping stays valid after the file is gone; the player lets
        // go of the frames on its own time.
        if let auditionFile { try? FileManager.default.removeItem(at: auditionFile) }
        auditionFile = nil
        auditionFrames = nil
        auditionID = nil
        isPreparingAudition = false
    }

    // MARK: - The work

    private func pump() {
        isScanning = workers > 0 || !queue.isEmpty
        while workers < workerCount, !queue.isEmpty, !stopping {
            let id = queue.removeFirst()
            guard let i = index[id], items[i].state == .queued else { continue }
            workers += 1
            items[i].state = .running
            let job = Job(url: items[i].url, measureTagged: measureTagged)
            Task {
                let result = await Task.detached(priority: .utility) { Self.scan(job) }.value
                if let i = index[id] {
                    items[i].state = result.state
                    items[i].bpm = result.bpm
                    items[i].confidence = result.confidence
                    items[i].tag = result.tag
                    items[i].note = result.note
                }
                workers -= 1
                pump()
            }
        }
        isScanning = workers > 0 || !queue.isEmpty
    }

    nonisolated private struct Job: Sendable {
        let url: URL
        let measureTagged: Bool
    }

    nonisolated private struct Result: Sendable {
        var state: Item.State
        var bpm: Double?
        var confidence: Double?
        var tag: String?
        var note: String?
    }

    /// One file, off the main actor: hold its permission, read what the tag
    /// says, decode into the temporary folder, measure, write the tempo
    /// back, and take the decoded copy away again.
    nonisolated private static func scan(_ job: Job) -> Result {
        // The permission for this file is held by the folder it came in
        // with; see `roots`.
        let url = job.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Result(state: .failed, note: "the file is no longer there")
        }
        let existing = TagWriter.readBPM(url)
        // A tag of 0 is iTunes saying "no tempo here", not a tempo: those
        // are measured like any untagged file.
        if !job.measureTagged, let existing, (Double(existing) ?? 0) > 0 {
            // Already carries a tempo, so nothing to do - the row says the
            // same as one written just now, because the file does too.
            return Result(state: .tagged, bpm: Double(existing), tag: existing)
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultramix-scan-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let analysis: TrackAnalysis
        do {
            try AudioCache.decode(url, to: temporary)
            analysis = try TempoAnalyzer.analyze(try AudioFrames(mapping: temporary))
        } catch {
            return Result(state: .failed, tag: existing, note: error.localizedDescription)
        }

        do {
            switch try TagWriter.writeBPM(analysis.bpm, to: url) {
            case .written, .unchanged:
                return Result(state: .tagged, bpm: analysis.bpm, confidence: analysis.confidence,
                              tag: TagWriter.readBPM(url))
            case .unsupported(let reason):
                // Measured, but the format has nowhere to keep it. Still
                // worth showing: the number is what the choosing is about.
                return Result(state: .untaggable, bpm: analysis.bpm, confidence: analysis.confidence,
                              tag: existing, note: reason)
            }
        } catch {
            return Result(state: .failed, bpm: analysis.bpm, confidence: analysis.confidence,
                          tag: existing, note: error.localizedDescription)
        }
    }

    nonisolated private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
