//
//  Track.swift
//  Ultramix
//
//  A library entry: one audio file, what the analyser measured, and what the
//  user corrected.
//
//  The two are stored side by side and never merged. A re-analysis must not be
//  able to undo a grid somebody fixed by ear, and the only way to guarantee
//  that is for the analyser to have nowhere to write the fields the user owns.
//  The effective grid is the correction where there is one and the analysis
//  otherwise, and it is computed, not stored.
//

import Foundation

/// What the tempo analyser measured about a track.
nonisolated struct TrackAnalysis: Codable, Sendable, Equatable {
    var bpm: Double
    /// Time of the first downbeat - bar one, beat one - in the source file.
    var firstBeatSeconds: Double
    /// 0...1. How well a rigid grid fits the onsets; not a probability.
    var confidence: Double
    /// The analyser version that produced this. A track analysed by an older
    /// version is analysed again at launch.
    var version: Int
    /// Which analyser produced this; nil is Ultramix's own, and is left out
    /// of the file, so libraries from before there was a choice read the
    /// same. (A build from before the choice takes a Beat This! analysis,
    /// version 1, for an outdated one of its own and analyses the track
    /// again.)
    var algorithm: BeatAlgorithm? = nil

    var analyser: BeatAlgorithm { algorithm ?? .ultramix }
    /// Older than its own analyser's current version.
    var isOutdated: Bool { version < analyser.version }

    /// Below this the library marks the grid as worth checking. Measured
    /// on a 783-track set against hand-set tempos:
    /// with analyser version 2, at 0.5 the mark sat on 454 of the 751 tracks
    /// that agreed, so it said nothing, and at 0.3 on 43 of them and 14 of
    /// the 32 that did not. Version 3 rates its fits higher (the confidence
    /// counts kicks, not all events); at 0.35 it marks 40 agreeing tracks,
    /// 14 of the 32, and 42 of the 55 whose kicks mostly miss the grid.
    static let lowConfidence = 0.35
    var isLowConfidence: Bool { confidence < Self.lowConfidence }
}

nonisolated enum AnalysisState: String, Codable, Sendable {
    case pending, running, done, failed
}

/// The part of a track the timeline needs: how its beats map onto its file.
///
/// A track is assumed to hold one tempo from start to end. That is true of
/// nearly everything a DJ mixes; a live recording that drifts is out of
/// scope, and the beatgrid editor is where it would be fixed by hand.
nonisolated struct SourceGrid: Sendable, Equatable {
    var bpm: Double
    var firstBeatSeconds: Double
    var durationSeconds: Double
    /// Where the music ends and the file's silent tail begins
    /// (`LoudnessProfile.soundEndSeconds`); nil until measured.
    var soundEndSeconds: Double? = nil

    /// Beats from the start of the file to its first downbeat.
    var preRollBeats: Double { firstBeatSeconds * bpm / 60 }
    /// The whole file, in beats of its own tempo.
    var lengthBeats: Double { durationSeconds * bpm / 60 }
    /// Up to the end of the music, in beats of its own tempo; the whole
    /// file while that is not known.
    var soundLengthBeats: Double { min(soundEndSeconds ?? durationSeconds, durationSeconds) * bpm / 60 }
}

/// Where a track's gridlines fall, for the beatgrid editor: which line a
/// click means. Line k sits at
/// firstBeat + k beats; k may be negative, before bar one. The editor keeps
/// a selection as an index, not a time, so it stays on its line while bar
/// one is nudged or the tempo changes.
nonisolated enum BeatLines {
    static func time(ofLine k: Int, bpm: Double, firstBeat: Double) -> Double {
        firstBeat + Double(k) * 60 / max(bpm, 1)
    }

    static func nearestLine(to seconds: Double, bpm: Double, firstBeat: Double) -> Int {
        Int(((seconds - firstBeat) * max(bpm, 1) / 60).rounded())
    }

    /// The lines that fall inside a window of the song, for the beatgrid
    /// editor's strip: `from…to` in seconds, cut to the song itself, since
    /// past its end a grid marks nothing.
    ///
    /// Here and not in the view because it is arithmetic - and because the
    /// view clamped the two ends separately, so a window past the end of the
    /// song became a range starting after it ended and Swift aborted. Clamp
    /// the window first, answer nil when nothing is left.
    ///
    /// - Returns: nil when the window is empty, lies outside the song, or
    ///   would hold more than `limit` lines - more than can be told apart
    ///   on a screen anyway.
    static func indices(from: Double, to: Double, bpm: Double, firstBeat: Double,
                        duration: Double, limit: Int = 20_000) -> ClosedRange<Int>? {
        let end = min(max(to, 0), max(duration, 0))
        let start = min(max(from, 0), end)
        guard end > start else { return nil }
        let beat = 60 / max(bpm, 1)
        let first = Int(((start - firstBeat) / beat).rounded(.up))
        let last = Int(((end - firstBeat) / beat).rounded(.down))
        guard last >= first, last - first <= limit else { return nil }
        return first...last
    }
}

nonisolated struct Track: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    /// Where the song's copy lives, relative to the working directory
    /// (`Audio/…`) - relative so the working directory can mount under
    /// another path, or on another Mac. An absolute path is used as it is.
    var path: String
    /// Where the song was imported from. Recognises a file imported twice,
    /// and lets an import interrupted by quitting finish its copy.
    var sourcePath: String?
    /// Security-scoped bookmark of the source. For a copied song, kept only
    /// until the copy in the working directory exists: the sandbox forgets a
    /// user-selected file when the app quits, and this is what lets an
    /// unfinished copy resume. For a song referred to where it lies (see
    /// ImportCopy), kept for good: it is the permission to read the song.
    var bookmark: Data?
    var title: String
    var artist: String?
    var durationSeconds: Double
    var addedAt: Date

    var state: AnalysisState
    var analysis: TrackAnalysis?
    var failure: String?

    /// The key analysis (KeyAnalyzer); nil until it has run.
    var key: KeyAnalysis?

    /// The user's correction. Each field overrides its measured counterpart.
    var manualBPM: Double?
    var manualFirstBeatSeconds: Double?

    /// The marks the user set in the song - where the next record comes in
    /// (CuePoints.swift). Set by hand like the correction, and like it never
    /// written by an analyser.
    var cuePoints: [CuePoint] = []

    var bpm: Double? { manualBPM ?? analysis?.bpm }
    var firstBeatSeconds: Double? { manualFirstBeatSeconds ?? analysis?.firstBeatSeconds }
    var isCorrected: Bool { manualBPM != nil || manualFirstBeatSeconds != nil }

    /// Nil until the track has a tempo and a first beat. A clip cannot be
    /// laid out on the timeline without both.
    var grid: SourceGrid? {
        guard let bpm, let firstBeatSeconds, durationSeconds > 0 else { return nil }
        return SourceGrid(bpm: bpm, firstBeatSeconds: firstBeatSeconds, durationSeconds: durationSeconds)
    }

    /// The song's format as its file extension says it, the way Finder
    /// names it: "MP3", "WAV", "AIFF". The two spellings of WAV and AIFF
    /// read as one, so they sort together.
    var fileType: String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "": "–"
        case "wave": "WAV"
        case "aif": "AIFF"
        case let other: other.uppercased()
        }
    }

    /// "Artist – Title" when both are known, which is how a DJ thinks of a
    /// record; the file name otherwise.
    /// Not copied: the song is read where it lies (see ImportCopy). An
    /// absolute path from before working directories counts as well.
    var isReference: Bool { path.hasPrefix("/") }

    var displayName: String {
        if let artist, !artist.isEmpty { return "\(artist) – \(title)" }
        return title
    }

    init(id: UUID = UUID(), path: String, bookmark: Data?, title: String, artist: String?,
         durationSeconds: Double, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.title = title
        self.artist = artist
        self.durationSeconds = durationSeconds
        self.addedAt = addedAt
        self.state = .pending
    }

    /// Stores a correction, or clears it where it says the same as the
    /// analysis. A correction equal to the measurement would pin the value
    /// for no reason - a later, better analyser could then never improve it.
    ///
    /// - Returns: whether the stored correction changed. The library saves
    ///   only then; confirming the tempo that is already set is not an edit.
    @discardableResult
    mutating func setCorrection(bpm: Double?, firstBeatSeconds: Double?) -> Bool {
        let before = (manualBPM, manualFirstBeatSeconds)
        if let bpm, let measured = analysis?.bpm, abs(bpm - measured) < 0.0005 {
            manualBPM = nil
        } else {
            manualBPM = bpm.map { ($0 * 1000).rounded() / 1000 }
        }
        if let first = firstBeatSeconds, let measured = analysis?.firstBeatSeconds, abs(first - measured) < 0.0005 {
            manualFirstBeatSeconds = nil
        } else {
            manualFirstBeatSeconds = firstBeatSeconds
        }
        return before != (manualBPM, manualFirstBeatSeconds)
    }

    /// Sets, moves or clears one cue point.
    ///
    /// - Returns: whether anything changed. The library is rewritten whole
    ///   on every save, so setting a cue to where it already is must not
    ///   count as an edit - the same rule `setCorrection` follows.
    @discardableResult
    mutating func setCue(number: Int, seconds: Double?) -> Bool {
        let before = cuePoints
        cuePoints = seconds.map { CueRules.setting(cuePoints, number: number, seconds: $0) }
            ?? CueRules.removing(cuePoints, number: number)
        return before != cuePoints
    }

    // MARK: Library file
    //
    // The library's JSON is written and read here and nowhere else. The
    // first version configured the encoder in one place (ISO-8601 dates) and
    // the decoder in another (the default, which expects numbers), so every
    // library failed to load after a restart - and the next import would
    // have saved the empty list over it.

    static func encodeLibrary(_ tracks: [Track]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(tracks)
    }

    static func decodeLibrary(_ data: Data) throws -> [Track] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Track].self, from: data)
    }

    // A hand-written decoder: the synthesised one throws on a missing key
    // instead of using the default, and every field added later would break
    // every library saved before it.
    enum CodingKeys: String, CodingKey {
        case id, path, bookmark, title, artist, durationSeconds, addedAt
        case state, analysis, failure, manualBPM, manualFirstBeatSeconds, sourcePath, key, cuePoints
    }

    /// Written by hand for one reason: a track with no cue points must save
    /// exactly as it did before there were any. The synthesised encoder
    /// would write `"cuePoints": []` into every one of them.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(artist, forKey: .artist)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(analysis, forKey: .analysis)
        try c.encodeIfPresent(failure, forKey: .failure)
        try c.encodeIfPresent(manualBPM, forKey: .manualBPM)
        try c.encodeIfPresent(manualFirstBeatSeconds, forKey: .manualFirstBeatSeconds)
        try c.encodeIfPresent(sourcePath, forKey: .sourcePath)
        try c.encodeIfPresent(key, forKey: .key)
        if !cuePoints.isEmpty { try c.encode(cuePoints, forKey: .cuePoints) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        state = try c.decodeIfPresent(AnalysisState.self, forKey: .state) ?? .pending
        analysis = try c.decodeIfPresent(TrackAnalysis.self, forKey: .analysis)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        manualBPM = try c.decodeIfPresent(Double.self, forKey: .manualBPM)
        manualFirstBeatSeconds = try c.decodeIfPresent(Double.self, forKey: .manualFirstBeatSeconds)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        key = try c.decodeIfPresent(KeyAnalysis.self, forKey: .key)
        // Only the numbers a key can reach again, one cue each, in order.
        let cues = try c.decodeIfPresent([CuePoint].self, forKey: .cuePoints) ?? []
        cuePoints = cues.reduce(into: [CuePoint]()) { result, cue in
            guard CueRules.numbers.contains(cue.number), !result.contains(where: { $0.number == cue.number })
            else { return }
            result.append(cue)
        }
        .sorted { $0.number < $1.number }
        // An analysis interrupted by quitting is not running any more.
        if state == .running { state = .pending }
    }
}
