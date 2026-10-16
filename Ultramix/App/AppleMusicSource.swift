//
//  AppleMusicSource.swift
//  Ultramix
//
//  The Music app's library, read through iTunesLibrary, for the library
//  sidebar's Apple Music entry. Read-only, and read only when that entry is
//  opened: nobody who never looks there is asked for access to their music.
//
//  The sandbox allows it through the Music folder entitlement (read-only),
//  which is also what lets the songs in Music's media folder be imported. A
//  media folder elsewhere - on another drive - is outside the sandbox, and
//  its songs show as missing.
//
//  Access is asked for through MusicKit's authorization first, in the
//  open: left to iTunesLibrary, the question was asked out of sight and the
//  read sat on it with no dialog anywhere. Denied, the list says where to
//  allow it. Each read logs how long it took (subsystem TZorr.Ultramix,
//  category AppleMusic), for a read that takes long all the same.
//
//  What was read is a snapshot; Reload reads it again. Everything that came
//  from iTunesLibrary is turned into plain values on the background thread
//  that read it, so nothing of the framework reaches the views.
//
//  Where a song lies on disk comes last and on its own (AppleMusicLocations):
//  `location` is a round trip to Music's library agent per song, and while
//  the agent is busy - syncing with iCloud, it seems - each one waited about
//  60 ms, minutes for a library of thousands. Every other property took a
//  few milliseconds for all of them. So the list is up at once, the files
//  are looked up behind it - the list on screen first - and a song about to
//  be imported or auditioned is looked up there and then.
//

import Foundation
import AppKit
import Observation
import iTunesLibrary
import MusicKit
import os

@Observable
final class AppleMusicSource {
    static let shared = AppleMusicSource()

    enum State: Equatable {
        case idle, loading, loaded
        case failed(String)
        /// Access to the Music library was refused.
        case denied
    }

    private(set) var state: State = .idle
    /// When the read under way began, for the time shown while it runs.
    private(set) var loadingSince: Date?
    /// Songs whose file has not been looked at yet.
    private(set) var unlocated = 0

    nonisolated private static let log = Logger(subsystem: "TZorr.Ultramix", category: "AppleMusic")
    private(set) var playlists: [AppleMusicPlaylist] = []
    private(set) var songs: [UInt64: AppleMusicSong] = [:]
    /// Every song, in Music's order: the Songs entry.
    private(set) var allSongs: [UInt64] = []
    private var byID: [UInt64: AppleMusicPlaylist] = [:]
    @ObservationIgnored private var locations: AppleMusicLocations?
    @ObservationIgnored private var locating: Task<Void, Never>?

    func playlist(_ id: UInt64) -> AppleMusicPlaylist? { byID[id] }

    func loadIfNeeded() {
        if state == .idle { reload() }
    }

    func reload() {
        guard state != .loading else { return }
        state = .loading
        loadingSince = Date()
        locating?.cancel()
        Task {
            let status = await Self.authorize()
            guard status == .authorized else {
                Self.log.notice("Access to the Music library: \(String(describing: status), privacy: .public)")
                loadingSince = nil
                state = .denied
                return
            }
            let result = await Task.detached(priority: .userInitiated) { Result { try Self.read() } }.value
            apply(result)
        }
    }

    /// The songs listed now go first when files are looked up.
    func prioritize(_ ids: [UInt64]) {
        guard let locations, unlocated > 0 else { return }
        Task { await locations.prioritize(ids) }
    }

    /// The songs with their files, looked up now where they were not yet -
    /// for a song about to be imported, auditioned or dropped somewhere.
    func locate(_ ids: [UInt64]) async -> [AppleMusicSong] {
        if let locations, ids.contains(where: { songs[$0]?.located == false }) {
            store(await locations.locate(ids))
        }
        return ids.compactMap { songs[$0] }
    }

    /// The current answer, or the question asked now if there is none yet.
    private static func authorize() async -> MusicAuthorization.Status {
        let current = MusicAuthorization.currentStatus
        log.notice("Music authorization before reading: \(String(describing: current), privacy: .public)")
        guard current == .notDetermined else { return current }
        let answer = await MusicAuthorization.request()
        log.notice("Music authorization asked: \(String(describing: answer), privacy: .public)")
        return answer
    }

    /// System Settings at Privacy & Security › Media & Apple Music.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
            NSWorkspace.shared.open(url)
        }
    }

    private func apply(_ result: Result<Snapshot, Error>) {
        loadingSince = nil
        switch result {
        case .success(let snapshot):
            playlists = snapshot.playlists
            songs = snapshot.songs
            allSongs = snapshot.order
            byID = AppleMusicTree.index(snapshot.playlists)
            locations = snapshot.locations
            unlocated = snapshot.unlocated
            state = .loaded
            startLocating()
        case .failure(let error):
            state = .failed("The Music library could not be read (\(error.localizedDescription)). "
                            + "Allow Ultramix in System Settings › Privacy & Security › Media & Apple Music.")
        }
    }

    /// Looks up every file behind the list, a few at a time so a song asked
    /// for at once never waits long behind them, and hands them to the list
    /// a few times a second rather than for every song.
    private func startLocating() {
        locating?.cancel()
        guard let locations, unlocated > 0 else { return }
        let total = unlocated
        locating = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var found: [AppleMusicLocations.Found] = []
            var handed = clock.now
            while !Task.isCancelled {
                let step = await locations.step(20)
                if step.isEmpty { break }
                found += step
                if clock.now - handed > .milliseconds(400) {
                    self?.store(found)
                    found = []
                    handed = clock.now
                }
            }
            self?.store(found)
            Self.log.notice("Files of \(total, privacy: .public) songs looked up in \(String(describing: clock.now - start), privacy: .public)")
        }
    }

    private func store(_ found: [AppleMusicLocations.Found]) {
        guard !found.isEmpty else { return }
        var updated = songs
        var count = 0
        for item in found where updated[item.id]?.located == false {
            updated[item.id]?.url = item.url
            updated[item.id]?.block = item.block
            updated[item.id]?.located = true
            count += 1
        }
        songs = updated
        unlocated = max(0, unlocated - count)
    }

    private struct Snapshot: @unchecked Sendable {
        let playlists: [AppleMusicPlaylist]
        let songs: [UInt64: AppleMusicSong]
        let order: [UInt64]
        let locations: AppleMusicLocations
        let unlocated: Int
    }

    /// Songs only: no videos, podcasts or audiobooks. Playlists the user
    /// made - plain, smart and folders - and none of Music's own (Purchased,
    /// Recently Added, the library itself), which the Songs entry covers.
    nonisolated private static func read() throws -> Snapshot {
        let clock = ContinuousClock()
        let start = clock.now
        let library: ITLibrary
        do {
            library = try ITLibrary(apiVersion: "1.1")
        } catch {
            log.error("ITLibrary failed after \(String(describing: clock.now - start), privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let opened = clock.now
        var songs: [UInt64: AppleMusicSong] = [:]
        var order: [UInt64] = []
        var pending: [UInt64: ITLibMediaItem] = [:]
        var pendingOrder: [UInt64] = []
        for item in library.allMediaItems where item.mediaKind == .kindSong {
            let id = item.persistentID.uint64Value
            let early = AppleMusicSong.earlyBlock(protected: item.isDRMProtected, cloud: item.isCloud,
                                                  isFile: item.locationType == .file)
            let artist = item.artist?.name
            let album = item.album.title
            var song = AppleMusicSong(id: id, title: item.title,
                                      artist: artist?.isEmpty == false ? artist : nil,
                                      album: album?.isEmpty == false ? album : nil,
                                      bpm: item.beatsPerMinute > 0 ? item.beatsPerMinute : nil,
                                      seconds: Double(item.totalTime) / 1000, url: nil, block: early)
            if early == nil {
                song.located = false
                pending[id] = item
                pendingOrder.append(id)
            }
            songs[id] = song
            order.append(id)
        }
        let records = library.allPlaylists.compactMap { playlist -> AppleMusicTree.Record? in
            guard playlist.isVisible, !playlist.isPrimary, playlist.distinguishedKind == .kindNone else { return nil }
            let folder = playlist.kind == .folder
            guard folder || playlist.kind == .regular || playlist.kind == .smart else { return nil }
            return AppleMusicTree.Record(
                id: playlist.persistentID.uint64Value,
                parent: playlist.parentID?.uint64Value,
                name: playlist.name,
                isFolder: folder,
                isSmart: playlist.kind == .smart,
                songs: playlist.items.map { $0.persistentID.uint64Value }.filter { songs[$0] != nil })
        }
        log.notice("""
            Music library read in \(String(describing: clock.now - start), privacy: .public) \
            (opened in \(String(describing: opened - start), privacy: .public)): \
            \(songs.count, privacy: .public) songs, \(records.count, privacy: .public) playlists, \
            \(pendingOrder.count, privacy: .public) files to look up
            """)
        return Snapshot(playlists: AppleMusicTree.build(records), songs: songs, order: order,
                        locations: AppleMusicLocations(library: library, items: pending, order: pendingOrder),
                        unlocated: pendingOrder.count)
    }
}

/// Where Music's songs lie on disk, looked up one song at a time: the
/// library and its items stay here, off the main actor, until every file is
/// known. Songs asked for go first - the list on screen, then a song about
/// to be imported or auditioned, at once.
actor AppleMusicLocations {
    struct Found: Sendable {
        let id: UInt64
        let url: URL?
        let block: AppleMusicSong.Block?
    }

    /// Kept for as long as its items are looked up.
    private let library: ITLibrary
    private var items: [UInt64: ITLibMediaItem]
    private let order: [UInt64]
    private var next = 0
    /// Asked for first, the first at the end.
    private var priority: [UInt64] = []

    init(library: ITLibrary, items: [UInt64: ITLibMediaItem], order: [UInt64]) {
        self.library = library
        self.items = items
        self.order = order
    }

    func prioritize(_ ids: [UInt64]) {
        priority = ids.filter { items[$0] != nil }.reversed()
    }

    /// The next few, priority first; empty when every file is known.
    func step(_ count: Int) -> [Found] {
        var found: [Found] = []
        while found.count < count, let id = nextID() {
            found.append(locate(id))
        }
        return found
    }

    /// These, now, where they are still to be looked up.
    func locate(_ ids: [UInt64]) -> [Found] {
        ids.filter { items[$0] != nil }.map(locate)
    }

    private func nextID() -> UInt64? {
        while let id = priority.popLast() {
            if items[id] != nil { return id }
        }
        while next < order.count {
            let id = order[next]
            next += 1
            if items[id] != nil { return id }
        }
        return nil
    }

    private func locate(_ id: UInt64) -> Found {
        guard let item = items.removeValue(forKey: id) else { return Found(id: id, url: nil, block: .missing) }
        let url = item.location
        let block = AppleMusicSong.block(protected: false, cloud: item.isCloud, url: url) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return Found(id: id, url: url, block: block)
    }
}
