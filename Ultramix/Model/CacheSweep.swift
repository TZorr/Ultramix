//
//  CacheSweep.swift
//  Ultramix
//
//  Which files in the audio cache belong to nobody. Each track owns three
//  files named by its id - <id>.f32, .wave, .loud - plus one <id>.k±N.sw1.f32
//  (<id>.k±Nc±C.sw1.f32 with a fine tune) for each pitch shift it has been
//  played at, and removing a track deletes them all, but a track can also
//  disappear without being removed. A
//  library that once failed to load came up empty, the tracks were imported
//  again under new ids, and half a gigabyte was left behind.
//
//  Kept apart from the file system so the harness can check it, and
//  deliberately narrow: only files following the cache's own naming are
//  candidates, plus leftovers of interrupted decodes and renders
//  (".<name>.<uuid>.partial"). A file the cache did not write is not the
//  sweep's to judge.
//

import Foundation

nonisolated enum CacheSweep {
    static let ownedExtensions: Set<String> = ["f32", "wave", "loud"]
    /// Names the key shifter's output. A new tag when its sound changes, so
    /// shifts rendered by an older version are never played again.
    static let shiftTag = "sw1"

    /// The cache file of a track at a pitch shift: "<id>.k+2.sw1.f32", and
    /// with a fine tune "<id>.k+2c-15.sw1.f32". Whole semitones keep the
    /// name they had before there were cents, so their renders stay valid.
    static func shiftedName(_ id: UUID, pitch: PitchShift) -> String {
        "\(id.uuidString).\(pitchTag(pitch)).\(shiftTag).f32"
    }

    /// "k+2", "k+2c-15", "k0c+25": how a shift is named in the cache.
    static func pitchTag(_ pitch: PitchShift) -> String {
        func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : "\(v)" }
        let cents = pitch.cents == 0 ? "" : "c\(signed(pitch.cents))"
        return "k\(signed(pitch.semitones))\(cents)"
    }

    /// The shift a `pitchTag` names; nil for anything else, "c0" included,
    /// which is never written.
    static func pitch(fromTag tag: Substring) -> PitchShift? {
        guard tag.hasPrefix("k") else { return nil }
        let amounts = tag.dropFirst().split(separator: "c", omittingEmptySubsequences: false)
        guard (1...2).contains(amounts.count), let semitones = Int(amounts[0]) else { return nil }
        var cents = 0
        if amounts.count == 2 {
            guard let c = Int(amounts[1]), c != 0 else { return nil }
            cents = c
        }
        return PitchShift(semitones: semitones, cents: cents)
    }

    /// The track and shift a pitch-shift cache file holds, if `name` is one
    /// of the current tag.
    static func shift(in name: String) -> (id: UUID, pitch: PitchShift)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[2] == shiftTag, parts[3] == "f32",
              let id = UUID(uuidString: String(parts[0])), let pitch = pitch(fromTag: parts[1]) else { return nil }
        return (id, pitch)
    }

    /// The track, stem and shift a decoded stem in the cache holds:
    /// "<id>.ht1.drums.f32", or shifted "<id>.ht1.drums.k+2.sw1.f32" -
    /// whatever separator made it, so stems of an older one still count
    /// towards the size limit and go with their track. A stem's waveform,
    /// "<id>.ht1.vocals.wave" ("other" too), counts as one, at no pitch.
    static func stem(in name: String) -> (id: UUID, stem: Stem, pitch: PitchShift)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 || parts.count == 6, parts.last == "f32" || parts.last == "wave",
              let id = UUID(uuidString: String(parts[0])) else { return nil }
        if parts.last == "wave" {
            guard parts.count == 4, let stem = Stem.allCases.first(where: { $0.name == parts[2] }) else { return nil }
            return (id, stem, .none)
        }
        guard let stem = Stem.stored.first(where: { $0.name == parts[2] }) else { return nil }
        guard parts.count == 6 else { return (id, stem, .none) }
        guard parts[4] == shiftTag, let pitch = pitch(fromTag: parts[3]) else { return nil }
        return (id, stem, pitch)
    }

    /// The stored stems among `names` - the Stems folder - that can be
    /// deleted: a track's the library no longer holds, ones another
    /// separator made (another tag: the track separates again with this
    /// one), and leftovers of interrupted writes (".<name>.<uuid>.partial.caf").
    /// Decoded stems in the cache go with `orphans`, by their id.
    static func stemOrphans(among names: [String], keeping ids: Set<UUID>) -> [String] {
        let stored = Set(Stem.stored.map(\.name))
        return names.filter { name in
            if name.hasPrefix(".") && name.hasSuffix(".partial.caf") { return true }
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[3] == "caf", stored.contains(String(parts[2])),
                  let id = UUID(uuidString: String(parts[0])) else { return false }
            return !ids.contains(id) || parts[1] != StemSeparator.tag
        }
    }

    /// The names among `names` that can be deleted, given the ids of the
    /// tracks the library holds.
    static func orphans(among names: [String], keeping ids: Set<UUID>) -> [String] {
        names.filter { name in
            if name.hasPrefix(".") && name.hasSuffix(".partial") { return true }
            let file = URL(fileURLWithPath: name)
            // The owner is the name up to its first dot, so a key shift's
            // file goes with its track.
            guard ownedExtensions.contains(file.pathExtension),
                  let first = name.split(separator: ".").first,
                  let id = UUID(uuidString: String(first)) else { return false }
            return !ids.contains(id)
        }
    }
}
