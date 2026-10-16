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
//  What was read is a snapshot; Reload reads it again. Everything that came
//  from iTunesLibrary is turned into plain values on the background thread
//  that read it, so nothing of the framework reaches the views.
//

import Foundation
import Observation
import iTunesLibrary

@Observable
final class AppleMusicSource {
    static let shared = AppleMusicSource()

    enum State: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var playlists: [AppleMusicPlaylist] = []
    private(set) var songs: [UInt64: AppleMusicSong] = [:]
    /// Every song, in Music's order: the Songs entry.
    private(set) var allSongs: [UInt64] = []
    private var byID: [UInt64: AppleMusicPlaylist] = [:]

    func playlist(_ id: UInt64) -> AppleMusicPlaylist? { byID[id] }

    func loadIfNeeded() {
        if state == .idle { reload() }
    }

    func reload() {
        guard state != .loading else { return }
        state = .loading
        Task.detached(priority: .userInitiated) {
            let result = Result { try Self.read() }
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ result: Result<Snapshot, Error>) {
        switch result {
        case .success(let snapshot):
            playlists = snapshot.playlists
            songs = snapshot.songs
            allSongs = snapshot.order
            byID = AppleMusicTree.index(snapshot.playlists)
            state = .loaded
        case .failure(let error):
            state = .failed("The Music library could not be read (\(error.localizedDescription)). "
                            + "Allow Ultramix in System Settings › Privacy & Security › Media & Apple Music.")
        }
    }

    private struct Snapshot: Sendable {
        let playlists: [AppleMusicPlaylist]
        let songs: [UInt64: AppleMusicSong]
        let order: [UInt64]
    }

    /// Songs only: no videos, podcasts or audiobooks. Playlists the user
    /// made - plain, smart and folders - and none of Music's own (Purchased,
    /// Recently Added, the library itself), which the Songs entry covers.
    nonisolated private static func read() throws -> Snapshot {
        let library = try ITLibrary(apiVersion: "1.1")
        var songs: [UInt64: AppleMusicSong] = [:]
        var order: [UInt64] = []
        let files = FileManager.default
        for item in library.allMediaItems where item.mediaKind == .kindSong {
            let id = item.persistentID.uint64Value
            let url = item.locationType == .file ? item.location : nil
            let block = AppleMusicSong.block(protected: item.isDRMProtected, cloud: item.isCloud,
                                             url: url) { files.fileExists(atPath: $0.path) }
            let artist = item.artist?.name
            let album = item.album.title
            songs[id] = AppleMusicSong(id: id, title: item.title,
                                       artist: artist?.isEmpty == false ? artist : nil,
                                       album: album?.isEmpty == false ? album : nil,
                                       bpm: item.beatsPerMinute > 0 ? item.beatsPerMinute : nil,
                                       seconds: Double(item.totalTime) / 1000, url: url, block: block)
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
        return Snapshot(playlists: AppleMusicTree.build(records), songs: songs, order: order)
    }
}
