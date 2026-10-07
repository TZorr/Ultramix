//
//  Stems.swift
//  Ultramix
//
//  The four parts a song is separated into, and where they are kept.
//
//  Only drums, bass and vocals are stored. "Other" is the song less those
//  three, worked out as it plays, so the four always add up to the song
//  exactly - whatever the network got wrong lands in "other" - and a quarter
//  of the separation and the space is saved.
//
//  The stored stems are 16-bit Apple Lossless in the working directory's
//  Stems folder, kept for good: separating costs seconds a song, and nothing
//  about them changes. To play, they are decoded into the cache beside the
//  song's own audio, like any other song, and may be evicted from there.
//  They are stored at half level: a stem can peak above the song it came
//  from, and 16 bits would clip it.
//

import Foundation

nonisolated enum Stem: Int, CaseIterable, Codable, Sendable {
    case drums, bass, vocals, other

    /// The stems the separator writes, in the order it writes them.
    static let stored: [Stem] = [.drums, .bass, .vocals]
    /// The level they are stored at: −6 dB of headroom.
    static let storedScale: Float = 0.5

    var name: String {
        switch self {
        case .drums: "drums"
        case .bass: "bass"
        case .vocals: "vocals"
        case .other: "other"
        }
    }
}

nonisolated enum StemFiles {
    /// `<track>.<tag>.<stem>.caf` in the Stems folder. The tag names the
    /// model and the way it was run, so stems from another separator are
    /// never mistaken for these.
    static func storedName(_ track: UUID, _ stem: Stem) -> String {
        "\(track.uuidString).\(StemSeparator.tag).\(stem.name).caf"
    }

    /// `<track>.<tag>.<stem>.wave` in the cache: a stem's waveform, all four
    /// "other" included, drawn to the song's scale (Waveform.stems).
    static func waveformName(_ track: UUID, _ stem: Stem) -> String {
        "\(track.uuidString).\(StemSeparator.tag).\(stem.name).wave"
    }

    /// `<track>.<tag>.<stem>.f32` in the cache: the stored stem decoded; at
    /// a pitch shift `<track>.<tag>.<stem>.k+2.sw1.f32`, shifted like a song.
    static func cachedName(_ track: UUID, _ stem: Stem, pitch: PitchShift = .none) -> String {
        let base = "\(track.uuidString).\(StemSeparator.tag).\(stem.name)"
        return pitch.isNone ? "\(base).f32" : "\(base).\(CacheSweep.pitchTag(pitch)).\(CacheSweep.shiftTag).f32"
    }
}

/// One stem inside a clip - a region within the region: its own level,
/// mute and automation (volume, pan, low-pass, high-pass), drawn in the
/// expanded lane's stem row. Where and how long it plays, its tempo and its
/// key are the clip's: the four are one recording, and they add up to the
/// song only if they stay together.
nonisolated struct ClipPart: Codable, Sendable, Equatable {
    /// Whole dB, held to `Clip.gainRange`, as the clip's own gain.
    var gainDB: Double = 0
    var muted = false
    /// In clip-local beats, like the clip's own. Worked on before the clip's
    /// automation: the clip's applies to the four together.
    var automation = ClipAutomation()

    init(gainDB: Double = 0, muted: Bool = false, automation: ClipAutomation = ClipAutomation()) {
        self.gainDB = gainDB
        self.muted = muted
        self.automation = automation
    }

    /// Plays the stem exactly as it is.
    var isNeutral: Bool { gainDB == 0 && !muted && automation.isEmpty }
    /// The factor its samples are played at - the clip gain's own curve, so
    /// every stem at −6 dB is exactly the clip at −6 dB.
    var gain: Float { muted ? 0 : Float(Automation.gain(dB: gainDB)) }

    enum CodingKeys: String, CodingKey { case gainDB, muted, automation, dB }

    /// What is not at rest, only.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if gainDB != 0 { try c.encode(gainDB, forKey: .gainDB) }
        if muted { try c.encode(muted, forKey: .muted) }
        if !automation.isEmpty { try c.encode(automation, forKey: .automation) }
    }

    /// Held to the clip gain's range and whole dB, as the buttons set it.
    /// "dB" is how the stem levels before stem automation stored it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let level = (try? c.decodeIfPresent(Double.self, forKey: .gainDB))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .dB)) ?? 0
        gainDB = level.isFinite ? min(max(level, Clip.gainRange.lowerBound), Clip.gainRange.upperBound).rounded() : 0
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        automation = (try? c.decodeIfPresent(ClipAutomation.self, forKey: .automation)) ?? ClipAutomation()
    }
}

/// A clip's four stems. All neutral, the clip plays its own audio as it
/// is, and its track needs no stems.
nonisolated struct ClipParts: Codable, Sendable, Equatable {
    var drums = ClipPart()
    var bass = ClipPart()
    var vocals = ClipPart()
    var other = ClipPart()

    init() {}

    subscript(stem: Stem) -> ClipPart {
        get {
            switch stem {
            case .drums: drums
            case .bass: bass
            case .vocals: vocals
            case .other: other
            }
        }
        set {
            switch stem {
            case .drums: drums = newValue
            case .bass: bass = newValue
            case .vocals: vocals = newValue
            case .other: other = newValue
            }
        }
    }

    var isNeutral: Bool { Stem.allCases.allSatisfy { self[$0].isNeutral } }

    /// Whether any stem has automation of its own - the stems are then
    /// played apart, each through its own curves.
    var hasAutomation: Bool { Stem.allCases.contains { !self[$0].automation.isEmpty } }

    /// Whether the clip needs its stems: when one has automation, or they
    /// play at different levels. All alike is the clip louder or quieter,
    /// and the song does that on its own.
    var playsStems: Bool {
        if hasAutomation { return true }
        let gains = Stem.allCases.map { self[$0].gain }
        return gains.contains { $0 != gains[0] }
    }

    enum CodingKeys: String, CodingKey { case drums, bass, vocals, other }

    /// Only the stems that are not at rest: `{"vocals": {"muted": true}}`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !drums.isNeutral { try c.encode(drums, forKey: .drums) }
        if !bass.isNeutral { try c.encode(bass, forKey: .bass) }
        if !vocals.isNeutral { try c.encode(vocals, forKey: .vocals) }
        if !other.isNeutral { try c.encode(other, forKey: .other) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drums = (try? c.decodeIfPresent(ClipPart.self, forKey: .drums)) ?? ClipPart()
        bass = (try? c.decodeIfPresent(ClipPart.self, forKey: .bass)) ?? ClipPart()
        vocals = (try? c.decodeIfPresent(ClipPart.self, forKey: .vocals)) ?? ClipPart()
        other = (try? c.decodeIfPresent(ClipPart.self, forKey: .other)) ?? ClipPart()
    }
}

/// What a track's stored stems are: the separator that made them, and the
/// length of the song they were made from - decoded again later, a song
/// that comes out a different length no longer lines up with its stems.
nonisolated struct TrackStems: Codable, Sendable, Equatable {
    var tag: String
    var frames: Int

    /// Made by the separator this version of Ultramix runs.
    var isCurrent: Bool { tag == StemSeparator.tag }
}
