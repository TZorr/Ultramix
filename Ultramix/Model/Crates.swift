//
//  Crates.swift
//  Ultramix
//
//  Crates: the user's own lists of library tracks, kept in folders. A track
//  can be in any number of crates and stays one track in the library; a crate
//  only names it. Removing a track from a crate leaves it in the library;
//  removing it from the library takes it out of every crate.
//
//  A crate keeps its tracks in the order they came in - a playlist imported
//  from Music keeps Music's order - and the list shows them in that order
//  until a column header sorts it otherwise.
//
//  Kept beside the library in the working directory, in a file of its own
//  ("Ultramix Crates.json"), so the library file and the builds that read it
//  are not touched.
//

import Foundation

nonisolated struct Crate: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    /// The folder it is in; nil at the top.
    var parent: UUID?
    let isFolder: Bool
    /// In the order they came in. Always empty for a folder.
    var tracks: [UUID]
}

/// A crate or folder in the tree, with a folder's contents.
nonisolated struct CrateNode: Identifiable, Sendable, Equatable {
    let crate: Crate
    /// nil for a crate; a folder's contents, possibly none.
    let children: [CrateNode]?

    var id: UUID { crate.id }
}

nonisolated struct Crates: Codable, Sendable, Equatable {
    static let formatVersion = 1

    private(set) var items: [Crate] = []

    init() {}

    func crate(_ id: UUID) -> Crate? { items.first { $0.id == id } }

    // MARK: - Reading

    /// Folders first, then crates, each by name as Finder sorts them. One
    /// whose folder is gone stands at the top rather than vanishing.
    func tree() -> [CrateNode] {
        let ids = Set(items.map(\.id))
        var byParent: [UUID?: [Crate]] = [:]
        for item in items {
            let parent = item.parent.flatMap { ids.contains($0) && $0 != item.id ? $0 : nil }
            byParent[parent, default: []].append(item)
        }
        var entered: Set<UUID> = []
        func nodes(_ parent: UUID?) -> [CrateNode] {
            (byParent[parent] ?? [])
                .filter { entered.insert($0.id).inserted }
                .sorted(by: Self.order)
                .map { CrateNode(crate: $0, children: $0.isFolder ? nodes($0.id) : nil) }
        }
        return nodes(nil)
    }

    private static func order(_ a: Crate, _ b: Crate) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// A crate's tracks; a folder's are those of everything in it, in the
    /// tree's order, each once.
    func tracks(in id: UUID) -> [UUID] {
        guard let crate = crate(id) else { return [] }
        guard crate.isFolder else { return crate.tracks }
        var seen: Set<UUID> = []
        var result: [UUID] = []
        func collect(_ nodes: [CrateNode]) {
            for node in nodes {
                for track in node.crate.tracks where seen.insert(track).inserted { result.append(track) }
                collect(node.children ?? [])
            }
        }
        collect(subtree(id))
        return result
    }

    /// Everything inside a folder, however deep.
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var frontier = [id]
        while let next = frontier.popLast() {
            for item in items where item.parent == next && result.insert(item.id).inserted {
                frontier.append(item.id)
            }
        }
        return result
    }

    /// "House / Deep": where it is, for a menu that lists crates from
    /// every folder at once.
    func path(_ id: UUID) -> String {
        var names: [String] = []
        var current = crate(id)
        var seen: Set<UUID> = []
        while let item = current, seen.insert(item.id).inserted {
            names.insert(item.name, at: 0)
            current = item.parent.flatMap { crate($0) }
        }
        return names.joined(separator: " / ")
    }

    /// The crates a track can be added to, by their path.
    func crateChoices() -> [(id: UUID, path: String)] {
        items.filter { !$0.isFolder }
            .map { (id: $0.id, path: path($0.id)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The folders `id` could be moved into: not itself, nothing inside it,
    /// and not the folder it is already in.
    func moveTargets(for id: UUID) -> [(id: UUID, path: String)] {
        let excluded = descendants(of: id).union([id])
        let current = crate(id)?.parent
        return items.filter { $0.isFolder && !excluded.contains($0.id) && $0.id != current }
            .map { (id: $0.id, path: path($0.id)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// "New Crate", or "New Crate 2" and on where that is taken in the folder.
    func freeName(_ base: String, in parent: UUID?) -> String {
        let taken = Set(items.filter { $0.parent == parent }.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    private func subtree(_ id: UUID) -> [CrateNode] {
        func find(_ nodes: [CrateNode]) -> CrateNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(tree())?.children ?? []
    }

    // MARK: - Changing

    /// A new crate or folder. A parent that is not a folder puts it at the
    /// top. An empty name gets the default one.
    @discardableResult
    mutating func add(name: String, folder: Bool, in parent: UUID?, tracks: [UUID] = []) -> UUID {
        let parent = parent.flatMap { crate($0)?.isFolder == true ? $0 : nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        items.append(Crate(id: id, name: trimmed.isEmpty ? freeName(folder ? "New Folder" : "New Crate", in: parent) : trimmed,
                           parent: parent, isFolder: folder, tracks: []))
        if !folder { add(tracks, to: id) }
        return id
    }

    mutating func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = trimmed
    }

    /// Deletes it and, for a folder, everything in it. The tracks stay in
    /// the library.
    mutating func delete(_ id: UUID) {
        let gone = descendants(of: id).union([id])
        items.removeAll { gone.contains($0.id) }
    }

    /// Into a folder, or to the top with nil. Never into itself or into
    /// anything inside it.
    @discardableResult
    mutating func move(_ id: UUID, into parent: UUID?) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        if let parent {
            guard crate(parent)?.isFolder == true, parent != id, !descendants(of: id).contains(parent) else { return false }
        }
        items[i].parent = parent
        return true
    }

    /// Appends the tracks not in the crate yet, in the order given.
    mutating func add(_ tracks: [UUID], to id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].isFolder else { return }
        var present = Set(items[i].tracks)
        for track in tracks where present.insert(track).inserted {
            items[i].tracks.append(track)
        }
    }

    mutating func remove(_ tracks: Set<UUID>, from id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].tracks.removeAll { tracks.contains($0) }
    }

    /// Tracks gone from the library leave every crate.
    mutating func forget(_ tracks: Set<UUID>) {
        for i in items.indices { items[i].tracks.removeAll { tracks.contains($0) } }
    }

    /// A playlist from Music as a crate, a folder as a folder of crates,
    /// each in Music's order. `track` answers the library track a song is,
    /// once imported; songs it has none for are left out. A name taken in
    /// the folder gets a number rather than mixing two lists in one.
    @discardableResult
    mutating func importPlaylist(_ playlist: AppleMusicPlaylist, into parent: UUID?,
                                 track: (UInt64) -> UUID?) -> UUID {
        let name = freeName(playlist.name, in: parent)
        guard playlist.isFolder else {
            return add(name: name, folder: false, in: parent, tracks: playlist.songs.compactMap(track))
        }
        let folder = add(name: name, folder: true, in: parent)
        for child in playlist.children ?? [] {
            importPlaylist(child, into: folder, track: track)
        }
        return folder
    }

    // MARK: - File

    private enum CodingKeys: String, CodingKey {
        case formatVersion, crates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard version <= Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: c,
                debugDescription: "Written by a newer Ultramix (format \(version))")
        }
        items = try c.decode([Crate].self, forKey: .crates)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(items, forKey: .crates)
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(Crates.self, from: data)
    }
}
