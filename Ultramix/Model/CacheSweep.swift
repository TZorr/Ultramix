//
//  CacheSweep.swift
//  Ultramix
//
//  Which files in the audio cache belong to nobody. Each track owns three
//  files named by its id - <id>.f32, .wave, .loud - and removing a track
//  deletes all three, but a track can also disappear without being removed. A
//  library that once failed to load came up empty, the tracks were imported
//  again under new ids, and half a gigabyte was left behind.
//
//  Kept apart from the file system so the harness can check it, and
//  deliberately narrow: only files following the cache's own naming are
//  candidates, plus leftovers of interrupted decodes
//  (".<name>.<uuid>.partial"). A file the cache did not write is not the
//  sweep's to judge.
//

import Foundation

nonisolated enum CacheSweep {
    static let ownedExtensions: Set<String> = ["f32", "wave", "loud"]

    /// The names among `names` that can be deleted, given the ids of the
    /// tracks the library holds.
    static func orphans(among names: [String], keeping ids: Set<UUID>) -> [String] {
        names.filter { name in
            if name.hasPrefix(".") && name.hasSuffix(".partial") { return true }
            let file = URL(fileURLWithPath: name)
            guard ownedExtensions.contains(file.pathExtension),
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { return false }
            return !ids.contains(id)
        }
    }
}
