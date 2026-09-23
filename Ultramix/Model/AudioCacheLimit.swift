//
//  AudioCacheLimit.swift
//  Ultramix
//
//  How much decoded audio the Cache folder may hold, and whose goes first.
//  Decoded audio is about eight times the song - 10 MB a stereo minute - so a
//  500-track library would be some 55 GB. Decoding takes a fifth of a second
//  typically, half a second at most, so a song nobody has played can give its
//  audio back.
//
//  Above the limit the audio used longest ago goes, one track at a time. Audio
//  in use - open mix, live set, audition, decode, analysis - is never removed,
//  even if that alone exceeds the limit. "Used" is the file's modification
//  date, so the order survives a relaunch without a list of its own.
//
//  Waveform and loudness files stay regardless. The limit can also be lifted
//  (`noLimitKey`): every song decoded once and kept, at the cost of the whole
//  library on the drive.
//

import Foundation

nonisolated enum AudioCacheLimit {
    static let storageKey = "audioCacheLimitGB"
    /// Whether to keep every song decoded instead, so the limit never
    /// applies. The size stays remembered for when it is switched off.
    static let noLimitKey = "keepEveryTrackDecoded"
    /// The choices in Settings, in gigabytes (10⁹ bytes, as the Finder counts).
    static let choicesGB = [2, 5, 10, 20, 50]
    /// About eight hours of audio - a mix and a live set many times over.
    static let defaultGB = 5

    static func bytes(gigabytes: Int) -> Int { gigabytes * 1_000_000_000 }

    /// The limit set on this Mac, held to the choices.
    static func current(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.object(forKey: storageKey) as? Int ?? defaultGB
        return bytes(gigabytes: choicesGB.contains(stored) ? stored : defaultGB)
    }

    /// Whether the limit has been taken away. Settings greys the choice of
    /// size out while it is, because the size no longer decides anything.
    static func isLifted(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: noLimitKey)
    }

    /// The limit that actually applies. Ask this, not `current`, wherever
    /// the limit is applied - a change to either setting has to be noticed,
    /// and `current` alone would not see this one.
    static func effective(_ defaults: UserDefaults = .standard) -> Int {
        isLifted(defaults) ? .max : current(defaults)
    }

    struct Entry: Sendable, Equatable {
        let id: UUID
        let bytes: Int
        let lastUse: Date
    }

    /// The tracks whose audio to remove, least recently used first, so that
    /// what stays fits `limit` - or as close as the tracks in `pinned` allow.
    static func evictions(_ entries: [Entry], limit: Int, keeping pinned: Set<UUID>) -> [UUID] {
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return [] }
        // Ties broken by id, so the order never depends on the directory's.
        let candidates = entries.filter { !pinned.contains($0.id) }
            .sorted { ($0.lastUse, $0.id.uuidString) < ($1.lastUse, $1.id.uuidString) }
        var removed: [UUID] = []
        for entry in candidates where total > limit {
            removed.append(entry.id)
            total -= entry.bytes
        }
        return removed
    }
}
