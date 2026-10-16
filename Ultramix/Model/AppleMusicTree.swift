//
//  AppleMusicTree.swift
//  Ultramix
//
//  The Music app's library as Ultramix shows it: its songs, its playlists as
//  a tree of folders, and for each song whether Ultramix can take it in.
//
//  Pure on purpose. AppleMusicSource reads the library through iTunesLibrary
//  and hands plain records here, so the shape of the tree and the reasons a
//  song is refused can be checked without a Music library.
//
//  Only songs with a file of their own can come in. A song from an Apple
//  Music subscription is protected (FairPlay): nothing on the Mac hands out
//  its samples, so it could be neither analysed, stretched nor bounced. A
//  song that lives only in the cloud has no file until Music downloads it.
//

import Foundation

nonisolated struct AppleMusicSong: Identifiable, Sendable, Hashable {
    /// Music's persistent id.
    let id: UInt64
    let title: String
    let artist: String?
    let album: String?
    /// The tempo set in Music; nil where none was.
    let bpm: Int?
    let seconds: Double
    var url: URL?
    /// Why it cannot be imported; nil when it can - or when its file has
    /// not been looked at yet (see `located`).
    var block: Block?
    /// Whether its file has been looked at. Music hands out a song's place
    /// on disk one round trip at a time, so the list comes first and the
    /// files after (AppleMusicSource).
    var located = true

    enum Block: Sendable, Hashable {
        case protected, cloudOnly, notAudio, missing

        var reason: String {
            switch self {
            case .protected: "Protected by Apple Music (DRM) – its audio cannot be read"
            case .cloudOnly: "Only in the cloud – download it in Music first"
            case .notAudio: "Not a file type Ultramix can read"
            case .missing: "The file is missing – Music cannot find it either"
            }
        }

        var symbol: String {
            switch self {
            case .protected: "lock.fill"
            case .cloudOnly: "icloud"
            case .notAudio, .missing: "exclamationmark.triangle"
            }
        }
    }

    /// The path the library keeps as a track's source, so a song already
    /// imported is recognised.
    var path: String? { url?.standardizedFileURL.path }

    /// What its audition plays under (see FilePreview): the same for the
    /// song every time, and never a track's - "applemus" and the id.
    var previewID: UUID {
        withUnsafeBytes(of: id.bigEndian) { b in
            UUID(uuid: (0x61, 0x70, 0x70, 0x6C, 0x65, 0x6D, 0x75, 0x73, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]))
        }
    }

    /// What can be told without the file: protected, or not a file at all.
    /// Nil leaves the file still to be looked at.
    static func earlyBlock(protected: Bool, cloud: Bool, isFile: Bool) -> Block? {
        if protected { return .protected }
        return isFile ? nil : cloud ? .cloudOnly : .missing
    }

    /// Protection first: a protected song may be on disk and still be of no
    /// use. Then the file itself - where it is, what it is, whether it is.
    static func block(protected: Bool, cloud: Bool, url: URL?, exists: (URL) -> Bool) -> Block? {
        if protected { return .protected }
        guard let url, url.isFileURL else { return cloud ? .cloudOnly : .missing }
        guard AudioFiles.isAudio(url) else { return .notAudio }
        return exists(url) ? nil : .missing
    }
}

nonisolated struct AppleMusicPlaylist: Identifiable, Sendable, Hashable {
    let id: UInt64
    let name: String
    let isFolder: Bool
    let isSmart: Bool
    /// In Music's order. A folder's are those of everything in it.
    let songs: [UInt64]
    /// nil for a playlist; a folder's contents, possibly none.
    let children: [AppleMusicPlaylist]?

    var symbol: String {
        isFolder ? "folder" : isSmart ? "gearshape" : "music.note.list"
    }
}

nonisolated enum AppleMusicTree {
    /// One playlist as read from Music, before it is put in its folder.
    struct Record: Sendable {
        let id: UInt64
        let parent: UInt64?
        let name: String
        let isFolder: Bool
        let isSmart: Bool
        let songs: [UInt64]
    }

    /// Puts every playlist into its folder, keeping Music's order. One whose
    /// folder is not among the records - hidden, or not a playlist of songs -
    /// stands at the top rather than vanishing.
    static func build(_ records: [Record]) -> [AppleMusicPlaylist] {
        let ids = Set(records.map(\.id))
        var byParent: [UInt64: [Record]] = [:]
        var top: [Record] = []
        for record in records {
            if let parent = record.parent, parent != record.id, ids.contains(parent) {
                byParent[parent, default: []].append(record)
            } else {
                top.append(record)
            }
        }
        // A folder inside itself, however far down, would never end; each
        // id is entered once.
        var entered: Set<UInt64> = []
        func node(_ record: Record) -> AppleMusicPlaylist {
            entered.insert(record.id)
            guard record.isFolder else {
                return AppleMusicPlaylist(id: record.id, name: record.name, isFolder: false,
                                          isSmart: record.isSmart, songs: record.songs, children: nil)
            }
            let children = (byParent[record.id] ?? []).filter { !entered.contains($0.id) }.map(node)
            // Music lists a folder's songs itself; where it does not, they
            // are gathered from inside, each once.
            var songs = record.songs
            if songs.isEmpty {
                var seen: Set<UInt64> = []
                for child in children {
                    for song in child.songs where seen.insert(song).inserted { songs.append(song) }
                }
            }
            return AppleMusicPlaylist(id: record.id, name: record.name, isFolder: true,
                                      isSmart: record.isSmart, songs: songs, children: children)
        }
        return top.map(node)
    }

    /// Every playlist and folder by id, however deep.
    static func index(_ playlists: [AppleMusicPlaylist]) -> [UInt64: AppleMusicPlaylist] {
        var result: [UInt64: AppleMusicPlaylist] = [:]
        func add(_ list: [AppleMusicPlaylist]) {
            for playlist in list {
                result[playlist.id] = playlist
                add(playlist.children ?? [])
            }
        }
        add(playlists)
        return result
    }
}
