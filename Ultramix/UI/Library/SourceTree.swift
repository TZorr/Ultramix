//
//  SourceTree.swift
//  Ultramix
//
//  What the library sidebar lists, chosen in a tree above the table:
//  Ultramix's own library with the user's crates and folders under it (see
//  Crates), then the Music app's songs and playlists (see AppleMusicBrowser),
//  which are read when Apple Music is first opened.
//
//  Tracks go into a crate by dragging them onto it - from the library, or
//  from Apple Music, where a song not yet in the library is imported on the
//  way - or from the tables' Add to Crate menu. A playlist from Music comes
//  in as a crate of its own, a folder of them as a folder of crates.
//

import SwiftUI
import AppKit

/// What the sidebar's table lists.
enum LibrarySource: Hashable {
    case library
    case crate(UUID)
    case appleSongs
    case applePlaylist(UInt64)

    var isAppleMusic: Bool {
        switch self {
        case .library, .crate: false
        case .appleSongs, .applePlaylist: true
        }
    }

    var crate: UUID? {
        if case .crate(let id) = self { id } else { nil }
    }
}

/// A crate or folder to be named: a new one, or one renamed. The tracks of
/// a new crate are asked for only once the name is given - songs from Apple
/// Music are imported then, and not when the dialog is merely cancelled.
struct CrateNaming: Identifiable {
    enum Kind {
        case new(folder: Bool, parent: UUID?, tracks: () async -> [UUID])
        case rename(UUID)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let initialName: String

    var confirmTitle: String {
        if case .rename = kind { "Rename" } else { "Create" }
    }
}

/// What the tree asks the library panel to do.
struct SourceTreeActions {
    let importSongs: ([UInt64]) -> Void
    let importAsCrates: (AppleMusicPlaylist) -> Void
    /// The song ids a drag of one song stands for: the selection, when the
    /// dragged song is part of it.
    let draggedSongs: (UInt64) -> [UInt64]
    /// Adds dragged items - library tracks or Apple Music songs - to a crate.
    let addDropped: ([String], UUID) -> Bool
    let name: (CrateNaming) -> Void
    let delete: (UUID) -> Void
}

struct SourceTree: View {
    @Binding var source: LibrarySource
    @Binding var appleExpanded: Bool
    @Binding var cratesExpanded: Bool
    let library: Library
    let actions: SourceTreeActions
    private var music = AppleMusicSource.shared

    init(source: Binding<LibrarySource>, appleExpanded: Binding<Bool>, cratesExpanded: Binding<Bool>,
         library: Library, actions: SourceTreeActions) {
        _source = source
        _appleExpanded = appleExpanded
        _cratesExpanded = cratesExpanded
        self.library = library
        self.actions = actions
    }

    var body: some View {
        let crates = library.crates.tree()
        List(selection: Binding(get: { source }, set: { if let value = $0 { source = value } })) {
            if crates.isEmpty {
                libraryLabel
            } else {
                DisclosureGroup(isExpanded: $cratesExpanded) {
                    OutlineGroup(crates, children: \.children) { node in
                        crateRow(node)
                    }
                } label: {
                    libraryLabel
                }
            }
            DisclosureGroup(isExpanded: $appleExpanded) {
                appleContent
            } label: {
                Label("Apple Music", systemImage: "music.note")
                    .contextMenu {
                        Button("Reload") { music.reload() }
                            .disabled(music.state == .loading || music.state == .idle)
                    }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: appleExpanded, initial: true) { _, open in
            if open { music.loadIfNeeded() }
        }
    }

    private var libraryLabel: some View {
        Label("Ultramix Library", systemImage: "music.note.house")
            .tag(LibrarySource.library)
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(AppleMusicDrag.id).flatMap(actions.draggedSongs)
                guard !ids.isEmpty else { return false }
                actions.importSongs(ids)
                return true
            }
            .contextMenu {
                newItems(in: nil)
            }
            .help("Ultramix's own library. Drop songs from Apple Music here to import them; right-click for a new crate.")
    }

    private func crateRow(_ node: CrateNode) -> some View {
        let crate = node.crate
        return Label(crate.name, systemImage: crate.isFolder ? "folder" : "rectangle.stack")
            .badge(crate.isFolder ? 0 : crate.tracks.count)
            .tag(LibrarySource.crate(crate.id))
            .dropDestination(for: String.self) { items, _ in
                guard !crate.isFolder else { return false }
                return actions.addDropped(items, crate.id)
            }
            .contextMenu {
                if crate.isFolder {
                    newItems(in: crate.id)
                    Divider()
                }
                Button("Rename…") {
                    actions.name(CrateNaming(kind: .rename(crate.id),
                                             title: crate.isFolder ? "Rename Folder" : "Rename Crate",
                                             initialName: crate.name))
                }
                let targets = library.crates.moveTargets(for: crate.id)
                Menu("Move To") {
                    if crate.parent != nil {
                        Button("Top Level") { library.editCrates { $0.move(crate.id, into: nil) } }
                        if !targets.isEmpty { Divider() }
                    }
                    ForEach(targets, id: \.id) { target in
                        Button(target.path) { library.editCrates { $0.move(crate.id, into: target.id) } }
                    }
                }
                .disabled(crate.parent == nil && targets.isEmpty)
                Divider()
                Button(crate.isFolder ? "Delete Folder…" : "Delete Crate…") { actions.delete(crate.id) }
            }
    }

    /// New Crate and New Folder, at the top or inside a folder.
    @ViewBuilder
    private func newItems(in parent: UUID?) -> some View {
        Button("New Crate…") {
            actions.name(CrateNaming(kind: .new(folder: false, parent: parent, tracks: { [] }),
                                     title: "New Crate",
                                     initialName: library.crates.freeName("New Crate", in: parent)))
        }
        Button("New Folder…") {
            actions.name(CrateNaming(kind: .new(folder: true, parent: parent, tracks: { [] }),
                                     title: "New Folder",
                                     initialName: library.crates.freeName("New Folder", in: parent)))
        }
    }

    @ViewBuilder
    private var appleContent: some View {
        switch music.state {
        case .idle, .loading:
            // The seconds count, and after a while say why it may take so
            // long: a read that only says "Reading…" looks hung.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = music.loadingSince.map { Int(context.date.timeIntervalSince($0)) } ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(seconds >= 3 ? "Reading the Music library… \(seconds) s" : "Reading the Music library…")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if seconds >= 10 {
                        Text("The Music app may be busy with its library - updating or syncing it. Ultramix waits for it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Text("Ultramix may not read the Music library. Allow it in System Settings › Privacy & Security › Media & Apple Music, then try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open System Settings") { music.openPrivacySettings() }
                    Button("Try Again") { music.reload() }
                }
                .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { music.reload() }
                    .controlSize(.small)
            }
        case .loaded:
            Label("Songs", systemImage: "music.note")
                .badge(music.allSongs.count)
                .tag(LibrarySource.appleSongs)
                .contextMenu {
                    Button("Reload") { music.reload() }
                }
            if music.unlocated > 0 {
                Text("Finding song files… \(music.unlocated) left")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Music tells where each song lies one song at a time, slowly while it is busy. The list shown goes first; ✓ appears as songs are matched with the library.")
            }
            OutlineGroup(music.playlists, children: \.children) { playlist in
                Label(playlist.name, systemImage: playlist.symbol)
                    .tag(LibrarySource.applePlaylist(playlist.id))
                    .contextMenu {
                        let usable = playlist.songs.contains { music.songs[$0]?.block == nil }
                        Button(playlist.isFolder ? "Add Folder to Library" : "Add Playlist to Library") {
                            actions.importSongs(playlist.songs)
                        }
                        .disabled(!usable)
                        Button(playlist.isFolder ? "Import Folder as Crates" : "Import as Crate") {
                            actions.importAsCrates(playlist)
                        }
                        .disabled(!usable)
                    }
            }
        }
    }
}

/// "Add to Crate": every crate by its path, and a new one made of the
/// selection.
struct AddToCrateMenu: View {
    let crates: Crates
    let add: (UUID) -> Void
    let newCrate: () -> Void

    var body: some View {
        Menu("Add to Crate") {
            Button("New Crate…", action: newCrate)
            let choices = crates.crateChoices()
            if !choices.isEmpty { Divider() }
            ForEach(choices, id: \.id) { choice in
                Button(choice.path) { add(choice.id) }
            }
        }
    }
}

/// The edge under the tree, dragged to give it more or less of the sidebar.
struct SourceTreeResizeHandle: View {
    @Binding var height: Double
    @State private var base: Double?

    static let range = 90.0...560.0

    var body: some View {
        ZStack {
            Divider()
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 3)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = base ?? height
                    if base == nil { base = height }
                    height = min(max(start + Double(value.translation.height), Self.range.lowerBound),
                                 Self.range.upperBound)
                }
                .onEnded { _ in base = nil }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Resize the list of sources")
    }
}
