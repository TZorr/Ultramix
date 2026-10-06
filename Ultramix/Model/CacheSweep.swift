//
//  CacheSweep.swift
//  Ultramix
//
//  Which files in the audio cache belong to nobody. Each track owns three
//  files named by its id - <id>.f32, .wave, .loud - plus one <id>.k±N.sw1.f32
//  for each key shift it has been played at, and removing a track deletes
//  them all, but a track can also disappear without being removed. A
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

    /// The cache file of a track shifted by `semitones`: "<id>.k+2.sw1.f32".
    static func shiftedName(_ id: UUID, semitones: Int) -> String {
        "\(id.uuidString).k\(semitones > 0 ? "+" : "")\(semitones).\(shiftTag).f32"
    }

    /// The track and shift a key-shift cache file holds, if `name` is one
    /// of the current tag.
    static func shift(in name: String) -> (id: UUID, semitones: Int)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[2] == shiftTag, parts[3] == "f32", parts[1].hasPrefix("k"),
              let id = UUID(uuidString: String(parts[0])),
              let semitones = Int(parts[1].dropFirst()) else { return nil }
        return (id, semitones)
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
