//
//  MixDocument.swift
//  Ultramix
//
//  The saved mix: clips, lanes, tempo points and the format version.
//

import Foundation

/// Where a mix's track lives, so the mix can be opened without the library
/// that made it.
///
/// The path only. A song kept outside the working directory used to bring
/// its security-scoped bookmark along, and a bookmark carries the absolute
/// path it was made from: a mix passed to somebody else handed over the
/// folder layout of the Mac that made it, in a field nobody can read. The
/// permission to a referred song belongs to the Mac that imported it and
/// lives in that library (see Track.bookmark); a mix is a document.
///
/// Dropping the field needs no format bump either way: an older build
/// reading a mix without it decodes nil, as it did for every copied song,
/// and the decoder here passes over the key an older build wrote.
nonisolated struct TrackReference: Codable, Sendable, Equatable {
    var id: UUID
    var path: String
}

nonisolated struct MixDocument: Codable, Sendable, Equatable {
    static let fileExtension = "ultramix"
    static let format = "ultramix-mix"
    /// Bumped only for changes an older build cannot read correctly. Fields
    /// added with a default do not need it - see the decoder.
    ///
    /// 2: automation moved from the lanes onto the clips. A v1 build would
    /// open a v2 mix with no automation at all and could save over it that
    /// way, so it has to refuse instead. A v1 mix still opens here; its lane
    /// curves are not read. No migration.
    ///
    /// 3: the bipolar filter became a low-pass and a high-pass (`lpf`,
    /// `hpf`). A v2 build would drop both and fail on their gestures. A v2
    /// mix still opens here without its filter. No migration.
    static let formatVersion = 3

    /// The tempo at beat 0, until a clip's target says otherwise. Set from
    /// the first track placed, so a new mix starts at that track's tempo
    /// instead of stretching it to an arbitrary default.
    var projectBPM: Double
    /// In insertion order, which is meaningful twice over: the renderer sums
    /// clips in this order (float addition is not associative, so sorting
    /// would change a bounce nobody edited), and when two tempo targets land
    /// on the same beat the later clip wins.
    var clips: [Clip]
    var lanes: [LaneSettings]
    var tracks: [TrackReference]
    /// Clock seconds at beat 0 - see TempoMap.originSeconds. Only the live
    /// set moves it, and a live set is never saved, so it is not in the
    /// file: a mix read from disk always starts its clock at 0.
    var timeOrigin: Double = 0
    /// The master tempo: while locked, the whole mix plays at this one tempo
    /// and every clip's tempo point is ignored - not changed, so unlocking
    /// brings each point back as it was. Remembered while unlocked, so a
    /// tempo can be typed first and locked after.
    var masterBPM: Double?
    var masterLocked = false

    init(projectBPM: Double = 124) {
        self.projectBPM = projectBPM
        clips = []
        lanes = Array(repeating: LaneSettings(), count: Clip.laneCount)
        tracks = []
    }

    // MARK: - Tempo

    /// The map the mix plays: flat at the master tempo while it is locked,
    /// the clips' tempo points otherwise.
    func tempoMap(_ grids: GridLookup) -> TempoMap {
        if masterLocked, let masterBPM {
            return TempoMap(projectBPM: masterBPM, targets: [], originSeconds: timeOrigin)
        }
        return clipTempoMap(grids)
    }

    /// The map the clips' tempo points make, master tempo or not. For edits
    /// that write a tempo into the clips: written from the master, it would
    /// still be there after unlocking.
    func clipTempoMap(_ grids: GridLookup) -> TempoMap {
        let targets = clips.compactMap { clip -> TempoPoint? in
            guard let grid = grids(clip.trackID) else { return nil }
            return TempoPoint(beat: Double(clip.tempoAnchorBeat), bpm: clip.targetBPM ?? grid.bpm,
                              rampStart: clip.rampStartBeat.map(Double.init))
        }
        return TempoMap(projectBPM: projectBPM, targets: targets, originSeconds: timeOrigin)
    }

    /// The last beat anything plays. Muted clips count: the mix does not get
    /// shorter because a clip is silenced, and a transport whose end moved
    /// every time a mute was toggled would jump under the user's hand.
    func endBeat(_ grids: GridLookup) -> Double {
        clips.compactMap { geometry($0, grids)?.end }.max() ?? 0
    }

    // MARK: - File

    enum CodingKeys: String, CodingKey {
        case format, version, projectBPM, clips, lanes, tracks, masterBPM, masterLocked
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.format, forKey: .format)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(projectBPM, forKey: .projectBPM)
        try c.encode(clips, forKey: .clips)
        try c.encode(lanes, forKey: .lanes)
        try c.encode(tracks, forKey: .tracks)
        try c.encodeIfPresent(masterBPM, forKey: .masterBPM)
        if masterLocked { try c.encode(true, forKey: .masterLocked) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let format = try c.decodeIfPresent(String.self, forKey: .format), format != Self.format {
            throw EditError("This is not an Ultramix mix.")
        }
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if version > Self.formatVersion {
            throw EditError("This mix was saved by a newer version of Ultramix.")
        }
        projectBPM = try c.decodeIfPresent(Double.self, forKey: .projectBPM) ?? 124
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        var lanes = try c.decodeIfPresent([LaneSettings].self, forKey: .lanes) ?? []
        // Always exactly three: a file with fewer gains empty lanes, and one
        // with more (hand-edited) cannot put clips where no lane is drawn.
        while lanes.count < Clip.laneCount { lanes.append(LaneSettings()) }
        self.lanes = Array(lanes.prefix(Clip.laneCount))
        tracks = try c.decodeIfPresent([TrackReference].self, forKey: .tracks) ?? []
        masterBPM = try c.decodeIfPresent(Double.self, forKey: .masterBPM)
        masterLocked = try c.decodeIfPresent(Bool.self, forKey: .masterLocked) ?? false
        clips = clips.filter { (0..<Clip.laneCount).contains($0.lane) }
    }

    func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func load(from data: Data) throws -> MixDocument {
        try JSONDecoder().decode(MixDocument.self, from: data)
    }

    /// Written through SafeWrite: the last good version stays in place until
    /// the new one is complete.
    func write(to url: URL) throws {
        let data = try fileData()
        try SafeWrite.replace(url) { try data.write(to: $0) }
    }
}
