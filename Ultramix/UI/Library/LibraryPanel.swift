//
//  LibraryPanel.swift
//  Ultramix
//
//  The library as a sortable, searchable table beside the mix. Tracks go into
//  the mix by dragging onto a lane, by double-click or Return (the add mode
//  chosen in the bottom bar), or from the context menu; files go into the
//  library by dropping them on the table or through +.
//
//  Above the table, the sources (SourceTree): Ultramix's own library with
//  the user's crates, and the Music app's songs and playlists. The search
//  and the tempo range work on whichever is listed; a crate lists its tracks
//  in the order they came in until a column header sorts them.
//
//  Search matches every typed word anywhere in artist, title and path,
//  ignoring case and accents: people remember a record by a fragment, and
//  sometimes by the folder it is in.
//

import SwiftUI

extension Track {
    /// Unanalysed tracks sort first rather than refusing to sort.
    var bpmSortValue: Double { bpm ?? 0 }
}

/// One row of the library: the track, and what the library knows about it
/// beside the track itself - its loudness lives in the cache, not in the
/// library file. A row of its own so that column can sort like any other.
struct LibraryRow: Identifiable {
    let track: Track
    let lufs: Double?
    /// Its place in the crate listed; 0 in the library itself.
    var position = 0

    var id: UUID { track.id }
    /// Unmeasured tracks sort first, like unanalysed ones by BPM.
    var lufsSortValue: Double { lufs ?? -.infinity }
    /// Round the Camelot wheel; tracks without a key first.
    var keySortValue: Int { track.key?.key.sortValue ?? -1 }
}

struct LibraryPanel: View {
    let session: MixSession
    @Bindable var library: Library

    @State private var search = ""
    /// The panel itself holds the keyboard for the list. A click on a row
    /// never makes the table first responder - the rows are draggable and
    /// the drag takes the mouse down, so the keys went to the bare window,
    /// which beeped. A click in the table puts the focus here on purpose,
    /// and ↑ ↓, Return and Space are handled here.
    @FocusState private var listFocused: Bool
    /// A text field has the keyboard - the search, a BPM bound. SwiftUI
    /// leaves `listFocused` true while a field inside the panel is typed in,
    /// so Space toggled playback instead of reaching the field. The panel's
    /// Space and Return ask AppKit who really has the keys: the field editor
    /// is an NSText.
    private var typing: Bool { NSApp.keyWindow?.firstResponder is NSText }
    /// The tempo range. Its bounds are kept on this Mac, but it starts off
    /// at every launch: a filter left on from yesterday hides tracks with
    /// nothing on screen to say why, apart from one small checkbox.
    @State private var bpmFilter = BPMFilter()
    @AppStorage("libraryBPMLower") private var storedLower = 122.0
    @AppStorage("libraryBPMUpper") private var storedUpper = 125.0
    @AppStorage("libraryBPMOctaves") private var storedOctaves = false
    @State private var sortOrder = [KeyPathComparator(\LibraryRow.track.addedAt)]
    /// Live's "BPM order": the list sorted by tempo, so Auto plays up the
    /// tempo scale and the screen shows what comes. The sort it replaced
    /// comes back when it is switched off.
    @State private var bpmOrder = false
    @State private var sortBeforeBPM: [KeyPathComparator<LibraryRow>]?
    private static let bpmSort = [KeyPathComparator(\LibraryRow.track.bpmSortValue)]
    /// Which columns show, in which order and how wide - changed with a
    /// right-click on the header. Kept on this Mac, not in the working
    /// directory: it is how this screen is set up, not part of the library.
    @State private var columns = TableColumnCustomization<LibraryRow>()
    @AppStorage("libraryColumns") private var storedColumns = Data()
    @AppStorage(BeatAlgorithm.storageKey) private var beatAlgorithm: BeatAlgorithm = BeatAlgorithm.fallback
    /// Always the library at launch: a playlist left chosen yesterday would
    /// hide the library behind a list that may not even be read yet.
    @State private var source: LibrarySource = .library
    /// Whether Apple Music is open in the tree, and so read. Kept: someone
    /// who works from their playlists wants them there next time.
    @AppStorage("appleMusicExpanded") private var appleExpanded = false
    @AppStorage("sourceTreeHeight") private var treeHeight = 220.0
    @State private var appleSelection: Set<UInt64> = []
    /// Empty: in the playlist's own order, as Music shows it.
    @State private var appleSort: [KeyPathComparator<AppleMusicRow>] = []
    private var music = AppleMusicSource.shared
    /// The tree with everything closed: its two rows and no more.
    private static let collapsedTreeHeight = 64.0
    @AppStorage("cratesExpanded") private var cratesExpanded = true
    /// A crate's own sort, apart from the library's: it starts in the
    /// crate's order every time a crate is chosen.
    @State private var crateSort = Self.crateOrder
    private static let crateOrder = [KeyPathComparator(\LibraryRow.position)]
    @State private var naming: CrateNaming?
    @State private var nameDraft = ""
    /// A crate or folder with something in it, waiting to be confirmed
    /// before it is deleted.
    @State private var deleting: UUID?

    /// The sort of whatever the table lists.
    private var activeSort: Binding<[KeyPathComparator<LibraryRow>]> {
        source.crate != nil ? $crateSort : $sortOrder
    }

    private var rows: [LibraryRow] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let filter = bpmFilter
        let positions: [UUID: Int]? = source.crate.map { crate in
            Dictionary(library.crates.tracks(in: crate).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let matching = library.tracks.filter { track in
            if let positions, positions[track.id] == nil { return false }
            guard filter.matches(track.bpm) else { return false }
            guard !words.isEmpty else { return true }
            let text = "\(track.artist ?? "") \(track.title) \(track.path)"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return matching
            .map { LibraryRow(track: $0, lufs: library.loudness[$0.id]?.songLUFS, position: positions?[$0.id] ?? 0) }
            .sorted(using: activeSort.wrappedValue)
    }

    /// The songs of the Apple Music entry chosen, searched and filtered like
    /// the library. A song already imported is matched to its track by the
    /// path it was imported from.
    private var appleRows: [AppleMusicRow] {
        let ids: [UInt64]
        switch source {
        case .library, .crate: return []
        case .appleSongs: ids = music.allSongs
        case .applePlaylist(let id): ids = music.playlist(id)?.songs ?? []
        }
        var imported: [String: Track] = [:]
        for track in library.tracks {
            if let path = track.sourcePath, imported[path] == nil { imported[path] = track }
        }
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let filter = bpmFilter
        let rows = ids.compactMap { id -> AppleMusicRow? in
            guard let song = music.songs[id] else { return nil }
            let row = AppleMusicRow(song: song, track: song.path.flatMap { imported[$0] })
            guard filter.matches(row.bpm) else { return nil }
            guard !words.isEmpty else { return row }
            let text = "\(song.artist ?? "") \(song.title) \(song.album ?? "")"
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ? row : nil
        }
        return appleSort.isEmpty ? rows : rows.sorted(using: appleSort)
    }

    /// Imports the songs that can come in, in the order given; the rest are
    /// left out quietly - the list already says why.
    private func importSongs(_ ids: [UInt64]) {
        Task {
            let urls = await music.locate(ids).filter { $0.block == nil }.compactMap(\.url)
            guard !urls.isEmpty else { return }
            library.importItems(urls)
        }
    }

    /// Double-click and Return in the Apple Music list: songs in the library
    /// go into the mix the way the Return menu says, as from the library;
    /// the others are imported.
    private func activateSongs(_ ids: [UInt64]) {
        let chosen = Set(ids)
        let rows = appleRows.filter { chosen.contains($0.id) }
        importSongs(rows.filter { $0.track == nil }.map(\.id))
        let tracks = rows.compactMap(\.track).map(\.id)
        if !tracks.isEmpty { session.add(tracks, mode: session.libraryAddMode) }
    }

    /// A song from Apple Music: through its track once it is in the library,
    /// from its file before; one that cannot be read stops the preview.
    private func audition(_ row: AppleMusicRow) {
        if let track = row.track {
            session.audition(track.id)
        } else if row.song.block == nil {
            Task {
                // Its file may still be unknown; a moment's look, then play
                // - unless the selection moved on meanwhile.
                guard let song = await music.locate([row.id]).first,
                      appleSelection == [row.id] else { return }
                if let url = song.url, song.block == nil {
                    session.auditionFile(url, id: song.previewID)
                } else {
                    session.preview.stop()
                }
            }
        } else {
            session.preview.stop()
        }
    }

    /// A dragged song brings the rest of the selection along when it is part
    /// of it, as a drag out of a list does everywhere else.
    private func dropped(_ id: UInt64) -> [UInt64] {
        guard appleSelection.contains(id) else { return [id] }
        return appleRows.map(\.id).filter { appleSelection.contains($0) }
    }

    /// The library tracks for songs from Apple Music, importing those not
    /// in the library yet; songs that cannot come in are left out.
    private func tracksForSongs(_ ids: [UInt64]) async -> [UUID] {
        let urls = await music.locate(ids).filter { $0.block == nil }.compactMap(\.url)
        guard !urls.isEmpty else { return [] }
        return library.importResolving(urls).compactMap { $0 }
    }

    /// A playlist from Music as a crate, a folder as a folder of crates,
    /// its songs imported where they are not in the library yet.
    private func importAsCrates(_ playlist: AppleMusicPlaylist) {
        Task {
            let pairs = await music.locate(playlist.songs).compactMap { song -> (UInt64, URL)? in
                guard song.block == nil, let url = song.url else { return nil }
                return (song.id, url)
            }
            var tracks: [UInt64: UUID] = [:]
            for (pair, track) in zip(pairs, library.importResolving(pairs.map(\.1))) {
                if let track { tracks[pair.0] = track }
            }
            library.editCrates { $0.importPlaylist(playlist, into: nil) { tracks[$0] } }
            cratesExpanded = true
        }
    }

    /// A dragged track brings the rest of the selection along when it is
    /// part of it.
    private func draggedTracks(_ id: UUID) -> [UUID] {
        guard library.selection.contains(id) else { return [id] }
        return ordered(library.selection)
    }

    /// Tracks or Apple Music songs dropped on a crate; songs go in once
    /// their files are known and they are imported.
    private func addDropped(_ items: [String], to crate: UUID) -> Bool {
        let tracks = items.compactMap(UUID.init(uuidString:)).flatMap(draggedTracks)
        let songs = items.compactMap(AppleMusicDrag.id).flatMap(dropped)
        guard !tracks.isEmpty || !songs.isEmpty else { return false }
        if !tracks.isEmpty { library.editCrates { $0.add(tracks, to: crate) } }
        if !songs.isEmpty {
            Task {
                let imported = await tracksForSongs(songs)
                library.editCrates { $0.add(imported, to: crate) }
            }
        }
        return true
    }

    private func startNaming(_ request: CrateNaming) {
        nameDraft = request.initialName
        naming = request
    }

    /// A new crate at the top, of the tracks given once it is named.
    private func newCrate(_ tracks: @escaping () async -> [UUID]) {
        startNaming(CrateNaming(kind: .new(folder: false, parent: nil, tracks: tracks), title: "New Crate",
                                initialName: library.crates.freeName("New Crate", in: nil)))
    }

    private func commitNaming() {
        guard let request = naming else { return }
        naming = nil
        switch request.kind {
        case .new(let folder, let parent, let tracks):
            // The crate at once; its tracks as they are found - songs from
            // Apple Music are imported first.
            let name = nameDraft
            let crate = library.editCrates { $0.add(name: name, folder: folder, in: parent) }
            cratesExpanded = true
            if !folder {
                Task {
                    let ids = await tracks()
                    library.editCrates { $0.add(ids, to: crate) }
                }
            }
        case .rename(let id):
            let name = nameDraft
            library.editCrates { $0.rename(id, to: name) }
        }
    }

    /// An empty crate or folder goes at once; one with something in it is
    /// confirmed first.
    private func requestDelete(_ id: UUID) {
        guard let crate = library.crates.crate(id) else { return }
        let empty = crate.isFolder ? library.crates.descendants(of: id).isEmpty : crate.tracks.isEmpty
        if empty {
            library.editCrates { $0.delete(id) }
        } else {
            deleting = id
        }
    }

    private var deleteTitle: String {
        guard let id = deleting, let crate = library.crates.crate(id) else { return "" }
        return crate.isFolder ? "Delete the folder “\(crate.name)”?" : "Delete the crate “\(crate.name)”?"
    }

    private var deleteMessage: String {
        guard let id = deleting, let crate = library.crates.crate(id) else { return "" }
        if crate.isFolder {
            let inside = library.crates.descendants(of: id).count
            return "Everything in it goes too - \(inside) crate\(inside == 1 ? "" : "s") and folder\(inside == 1 ? "" : "s"). The tracks stay in the library."
        }
        return "Its \(crate.tracks.count) track\(crate.tracks.count == 1 ? "" : "s") stay in the library."
    }

    private func setBPMOrder(_ on: Bool) {
        guard on != bpmOrder else { return }
        let sort = activeSort
        if on {
            sortBeforeBPM = sort.wrappedValue
            bpmOrder = true
            sort.wrappedValue = Self.bpmSort
        } else {
            bpmOrder = false
            if let previous = sortBeforeBPM { sort.wrappedValue = previous }
            sortBeforeBPM = nil
        }
    }

    var body: some View {
        let used = session.usedTracks
        let visible = rows
        let appleVisible = appleRows
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search artist, title or folder", text: $search)
                    .textFieldStyle(.plain)
                Button {
                    FilePanels.importTracks(library)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add tracks or folders to the library")
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 6)
            BPMRangeBar(filter: $bpmFilter,
                        selectedBPM: library.selection.count == 1
                            ? library.selection.first.flatMap { library.track($0)?.bpm } : nil)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            let treeOpen = appleExpanded || (cratesExpanded && !library.crates.items.isEmpty)
            SourceTree(source: $source, appleExpanded: $appleExpanded, cratesExpanded: $cratesExpanded,
                       library: library,
                       actions: SourceTreeActions(importSongs: importSongs, importAsCrates: importAsCrates,
                                                  draggedSongs: dropped, addDropped: addDropped,
                                                  name: startNaming, delete: requestDelete))
                .frame(height: treeOpen ? treeHeight : Self.collapsedTreeHeight)
            if treeOpen {
                SourceTreeResizeHandle(height: $treeHeight)
            } else {
                Divider()
            }
            if !source.isAppleMusic {
                // The drag sits on the row, not on the cell in front: a
                // `.draggable` view takes the mouse down before the table sees
                // it, so clicks on the title missed while clicks on the BPM
                // column did not.
                Table(of: LibraryRow.self, selection: $library.selection, sortOrder: activeSort,
                      columnCustomization: $columns) {
                    TableColumn("Track", value: \.track.displayName) { row in
                        TrackCell(track: row.track, used: used.contains(row.id))
                    }
                    // The column people read by: it takes what the others leave.
                    .width(min: 100, ideal: 150)
                    .customizationID("track")
                    // Without it a row has nothing to recognise it by.
                    .disabledCustomizationBehavior(.visibility)
                    TableColumn("BPM", value: \.track.bpmSortValue) { row in
                        Text(row.track.bpm.map { String(format: "%.2f", $0) } ?? "–")
                            .monospacedDigit()
                            // A corrected grid shows as the pencil in the
                            // status column, not as a coloured number.
                            .foregroundStyle(Color.primary)
                    }
                    .width(58)
                    .customizationID("bpm")
                    TableColumn("Time", value: \.track.durationSeconds) { row in
                        Text(row.track.durationSeconds > 0
                             ? "\(Int(row.track.durationSeconds) / 60):\(String(format: "%02d", Int(row.track.durationSeconds) % 60))"
                             : "–")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(44)
                    .customizationID("time")
                    TableColumn("Key", value: \.keySortValue) { row in
                        KeyCell(analysis: row.track.key)
                    }
                    .width(64)
                    .customizationID("key")
                    TableColumn("LUFS", value: \.lufsSortValue) { row in
                        Text(row.lufs.map { String(format: "%.1f", $0) } ?? "–")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("Integrated loudness of the whole song, before any trim or gain")
                    }
                    .width(44)
                    .customizationID("lufs")
                    .defaultVisibility(.hidden)
                    TableColumn("Type", value: \.track.fileType) { row in
                        Text(row.track.fileType).foregroundStyle(.secondary)
                    }
                    .width(40)
                    .customizationID("type")
                    .defaultVisibility(.hidden)
                    TableColumn("") { row in
                        StatusIcon(track: row.track, busy: library.busy.contains(row.id),
                                   separating: library.separating[row.id])
                    }
                    .width(18)
                    .customizationID("status")
                    .disabledCustomizationBehavior(.visibility)
                } rows: {
                    ForEach(visible) { row in
                        TableRow(row).draggable(row.id.uuidString)
                    }
                }
                // Beside the table's own click handling, not instead of it:
                // selection and dragging stay the table's.
                .simultaneousGesture(TapGesture().onEnded { listFocused = true })
                // A new table for every search: filtering left cells blank
                // until they were scrolled away and back. Accessibility had the
                // right text every time, so the table held the new content and
                // only failed to redraw the cells it reused; a fresh identity
                // reuses none. Selection and column layout are bindings and
                // survive. The tempo range filters the same rows, so it is part
                // of the identity too.
                .id(TableIdentity(source: source, search: search, bpm: bpmFilter))
                .task {
                    if let stored = try? JSONDecoder().decode(TableColumnCustomization<LibraryRow>.self, from: storedColumns) {
                        columns = stored
                    }
                }
                .onChange(of: columns) { _, changed in
                    if let data = try? JSONEncoder().encode(changed) { storedColumns = data }
                }
                // What Auto follows: the list as it is on screen.
                .onChange(of: visible.map(\.id), initial: true) { _, ids in library.visibleOrder = ids }
                // A header clicked by hand is a sort of its own: BPM order is off.
                .onChange(of: activeSort.wrappedValue) { _, order in
                    if bpmOrder, order != Self.bpmSort {
                        bpmOrder = false
                        sortBeforeBPM = nil
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    menu(ids, used: used)
                } primaryAction: { ids in
                    // Return and double-click: the mode chosen in the bar below.
                    session.add(ordered(ids), mode: session.libraryAddMode)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    library.importItems(urls)
                    return true
                }
                .overlay {
                    if library.tracks.isEmpty {
                        ContentUnavailableView {
                            Label("No Tracks", systemImage: "music.note.list")
                        } description: {
                            Text("Drop audio files or folders here.")
                        } actions: {
                            Button("Add Tracks or Folder…") { FilePanels.importTracks(library) }
                        }
                    } else if let crate = source.crate, library.crates.tracks(in: crate).isEmpty {
                        ContentUnavailableView("Empty", systemImage: "rectangle.stack",
                                               description: Text("Drag tracks onto the crate in the list above, or right-click them › Add to Crate."))
                    } else if rows.isEmpty {
                        ContentUnavailableView("No Matching Tracks",
                                               systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text(bpmFilter.isOn
                                                                 ? "Nothing matches the search and the BPM range."
                                                                 : "Nothing matches the search."))
                    }
                }
            } else {
                AppleMusicTable(rows: appleVisible, selection: $appleSelection, sortOrder: $appleSort,
                                library: library, importSongs: importSongs, activate: activateSongs,
                                addToCrate: { songs, crate in
                                    Task {
                                        let ids = await tracksForSongs(songs)
                                        library.editCrates { $0.add(ids, to: crate) }
                                    }
                                },
                                newCrate: { songs in newCrate { await tracksForSongs(songs) } })
                    .simultaneousGesture(TapGesture().onEnded { listFocused = true })
                    // A fresh table for every list and search, for the same
                    // reason as the library's below.
                    .id(AppleTableIdentity(source: source, search: search, bpm: bpmFilter))
                    // Its files are looked up before the rest of the library's.
                    .onChange(of: appleVisible.map(\.id), initial: true) { _, ids in music.prioritize(ids) }
                    .overlay {
                        if music.state == .loaded, appleVisible.isEmpty {
                            ContentUnavailableView(search.isEmpty && !bpmFilter.isOn ? "No Songs" : "No Matching Songs",
                                                   systemImage: "music.note.list")
                        }
                    }
            }
            Divider()
            // In Apple Music the one song selected: through its track once it
            // is in the library, from its file before.
            let appleOne = source.isAppleMusic && appleSelection.count == 1
                ? appleVisible.first { appleSelection.contains($0.id) } : nil
            PreviewBar(session: session, library: library,
                       trackID: source.isAppleMusic ? appleOne?.track?.id
                           : library.selection.count == 1 ? library.selection.first : nil,
                       song: appleOne?.track == nil ? appleOne?.song : nil)
            if session.isLive {
                Divider()
                LiveAutoBar(session: session, library: library, order: visible.map(\.id),
                            bpmOrder: Binding(get: { bpmOrder }, set: { setBPMOrder($0) }))
            }
        }
        // Handled here only when the table does not have focus; with
        // focus it moves its own selection, so a step is never taken twice.
        // Restored here and not in the table's task: the table gets a new
        // identity with every change of the range, which would run that
        // task again.
        .onAppear {
            bpmFilter = BPMFilter(lower: storedLower, upper: storedUpper, includesOctaves: storedOctaves)
        }
        // Closing Apple Music in the tree goes back to the library rather
        // than leaving a list on screen whose entry can no longer be seen.
        .onChange(of: appleExpanded) { _, open in
            if !open, source.isAppleMusic { source = .library }
        }
        .onChange(of: source) { _, now in
            appleSelection = []
            // Each list starts in its own order; BPM order belonged to the
            // list it was switched on in.
            bpmOrder = false
            sortBeforeBPM = nil
            if now.crate != nil { crateSort = Self.crateOrder }
        }
        // A crate deleted - or inside a folder deleted - while it is listed.
        .onChange(of: library.crates) { _, crates in
            if let id = source.crate, crates.crate(id) == nil { source = .library }
        }
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button(naming?.confirmTitle ?? "OK") { commitNaming() }
            Button("Cancel", role: .cancel) { naming = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let id = deleting { library.editCrates { $0.delete(id) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleteMessage)
        }
        .onChange(of: bpmFilter) { _, changed in
            storedLower = changed.lower
            storedUpper = changed.upper
            storedOctaves = changed.includesOctaves
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        // Only while the panel itself has the focus: in the search field
        // Space is a space, and Return in a BPM field commits the bound.
        .onKeyPress(.return) {
            guard listFocused, !typing else { return .ignored }
            if source.isAppleMusic {
                guard !appleSelection.isEmpty else { return .ignored }
                activateSongs(appleRows.map(\.id).filter { appleSelection.contains($0) })
                return .handled
            }
            guard !library.selection.isEmpty else { return .ignored }
            session.add(ordered(library.selection), mode: session.libraryAddMode)
            return .handled
        }
        // The mix keeps playing and stopping from the list, as from the
        // timeline.
        .onKeyPress(.space) {
            guard listFocused, !typing else { return .ignored }
            session.togglePlay()
            return .handled
        }
        // The same in Apple Music, while a preview plays.
        .onChange(of: appleSelection) { _, ids in
            if NSApp.currentEvent?.type == .leftMouseDown || NSApp.currentEvent?.type == .leftMouseUp {
                listFocused = true
            }
            guard session.isAuditioning else { return }
            if ids.count == 1, let id = ids.first, let row = appleRows.first(where: { $0.id == id }) {
                audition(row)
            } else {
                session.preview.stop()
            }
        }
        // Auditioning follows the selection: flipping through the list with
        // the arrow keys plays each track as it is reached. Whatever moved
        // the selection - keys, a click, the search - ends up here.
        .onChange(of: library.selection) { _, ids in
            if !ids.isEmpty { session.lastPick = .library }
            // A selection made with the mouse brings the keyboard along; one
            // made while typing a search leaves the field its focus.
            if NSApp.currentEvent?.type == .leftMouseDown || NSApp.currentEvent?.type == .leftMouseUp {
                listFocused = true
            }
            guard session.isAuditioning else { return }
            if ids.count == 1, let id = ids.first {
                session.audition(id)
            } else {
                session.preview.stop()
            }
        }
    }

    /// Moves the selection one row through the list as it is sorted and
    /// filtered on screen.
    private func step(_ direction: Int) -> KeyPress.Result {
        if source.isAppleMusic {
            let list = appleRows.map(\.id)
            guard !list.isEmpty else { return .ignored }
            let current = appleSelection.count == 1 ? list.firstIndex { $0 == appleSelection.first } : nil
            let next = current.map { min(max($0 + direction, 0), list.count - 1) }
                ?? (direction > 0 ? 0 : list.count - 1)
            appleSelection = [list[next]]
            return .handled
        }
        let list = rows
        guard !list.isEmpty else { return .ignored }
        let current = library.selection.count == 1
            ? list.firstIndex { $0.id == library.selection.first } : nil
        let next = current.map { min(max($0 + direction, 0), list.count - 1) }
            ?? (direction > 0 ? 0 : list.count - 1)
        library.selection = [list[next].id]
        return .handled
    }

    /// Tracks in the order the table shows them, which is the order a
    /// chain of beatmixes should follow; a selection by itself has none.
    private func ordered(_ ids: Set<UUID>) -> [UUID] {
        let shown = rows.map(\.id).filter { ids.contains($0) }
        return shown + ids.subtracting(shown).sorted { $0.uuidString < $1.uuidString }
    }

    @ViewBuilder
    private func menu(_ ids: Set<UUID>, used: Set<UUID>) -> some View {
        // Flat rather than a submenu: these are the items used most while
        // building a mix. The plain add is reached by double-click and by
        // dragging onto a lane.
        ForEach(BeatmixLength.allCases) { length in
            Button(length.title) { session.addTracks(ordered(ids), beatmix: length) }
                .disabled(ids.isEmpty)
        }
        Divider()
        // One track only: a chain has no defined place in the middle of a mix.
        ForEach(BeatmixLength.allCases.filter { $0 != .noTransition }) { length in
            Button("At Playhead: \(length.title)") {
                if let id = ids.first { session.insertTrack(id, beatmix: length) }
            }
            .disabled(ids.count != 1)
        }
        Divider()
        // At the cue points of the record being mixed out of, which are set
        // in its beatgrid editor.
        ForEach(BeatmixLength.allCases.filter { $0 != .noTransition }) { length in
            Button("At Cue: \(length.title)") {
                if let id = ids.first { session.insertTrackAtCue(id, beatmix: length) }
            }
            .disabled(ids.count != 1)
        }
        Divider()
        if ids.count == 1, let id = ids.first {
            Button("Edit Beatgrid…") { session.beatgridRequest = BeatgridRequest(id: id) }
            Button("Correct BPM…") { session.beatgridRequest = BeatgridRequest(id: id, correctBPM: true) }
                .disabled(library.track(id)?.state != .done && library.track(id)?.state != .failed)
        }
        // With the analyser chosen in Settings, which the title names.
        Button("Analyse Again (\(beatAlgorithm.title))") { ids.forEach { library.reanalyse($0) } }
            .disabled(ids.isEmpty)
        Button(ids.count == 1 ? "Write BPM to File" : "Write BPM to Files") {
            library.writeBPMTags(ids)
        }
        .disabled(library.writingTags || !ids.contains { library.track($0)?.bpm != nil })
        .help("Write the measured tempo into the song files in the working directory")
        Divider()
        // Ahead of the mix that will need them, or to free their space.
        Button("Separate Stems") { library.separate(ordered(ids)) }
            .disabled(!ids.contains { library.track($0)?.state != .failed && library.separating[$0] == nil && !library.hasStems($0) })
            .help("Separate into drums, bass, vocals and the rest, kept in the Stems folder")
        Button("Delete Stems") { ids.forEach { library.deleteStems($0) } }
            .disabled(!ids.contains { library.separating[$0] != nil || library.track($0)?.stems != nil })
            .help("Delete the stems to free the space; a clip that plays them separates the song again")
        Divider()
        AddToCrateMenu(crates: library.crates) { crate in
            let tracks = ordered(ids)
            library.editCrates { $0.add(tracks, to: crate) }
        } newCrate: {
            let tracks = ordered(ids)
            newCrate { tracks }
        }
        .disabled(ids.isEmpty)
        if let crate = source.crate, library.crates.crate(crate)?.isFolder == false {
            Button("Remove from Crate") { library.editCrates { $0.remove(ids, from: crate) } }
                .disabled(ids.isEmpty)
        }
        Divider()
        Button("Remove from Library") { library.remove(ids) }
            .disabled(ids.isEmpty || !ids.isDisjoint(with: used))
    }
}

private struct AppleTableIdentity: Hashable {
    let source: LibrarySource
    let search: String
    let bpm: BPMFilter
}

private struct TableIdentity: Hashable {
    let source: LibrarySource
    let search: String
    let bpm: BPMFilter
}

/// The tempo range filter: on or off, its two bounds, and in a second row,
/// in words, whether half and double tempos count and the range centred on
/// the selected track. One row held it all only with a "½×2×" and an icon
/// nobody could read; the sidebar's narrowest 300 points leave no room for
/// the words beside the bounds.
struct BPMRangeBar: View {
    @Binding var filter: BPMFilter
    /// The tempo of the one selected track; nil with none, several, or an
    /// unanalysed one.
    let selectedBPM: Double?

    var body: some View {
        // The fields cannot shrink: a small rounded field needs 50.5 points
        // to show "126.30" whole.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Toggle("BPM", isOn: $filter.isOn)
                    .toggleStyle(.checkbox)
                    .help("Show only tracks in this tempo range. Unanalysed tracks are hidden while it is on.")
                BPMBound(value: filter.lower) { value in
                    filter.setLower(value)
                    filter.isOn = true
                }
                Text("–").foregroundStyle(.secondary)
                BPMBound(value: filter.upper) { value in
                    filter.setUpper(value)
                    filter.isOn = true
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                // Switching the option on also switches the range on -
                // otherwise the button lights up and the list does not change.
                Toggle("Incl. ½× and 2×", isOn: Binding(
                    get: { filter.includesOctaves },
                    set: { filter.includesOctaves = $0; if $0 { filter.isOn = true } }))
                    .toggleStyle(.button)
                    .help("Also list tracks at half or double a tempo in the range")
                Button("Around Selection") {
                    if let bpm = selectedBPM {
                        filter.centre(on: bpm)
                        filter.isOn = true
                    }
                }
                .disabled(selectedBPM == nil)
                .help("Set the range to ±\(Int(BPMFilter.aroundSpan)) BPM about the selected track's tempo")
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
    }
}

/// One bound of the range. Like BPMField, typing edits a draft; unlike it,
/// leaving the field applies the draft as well as Return does. A filter
/// changes what is listed and nothing else, so there is no Set to guard it.
///
/// Changing a bound also switches the filter on: someone who steps the
/// range to 124 wants to see what is at 124.
private struct BPMBound: View {
    let value: Double
    let onChange: (Double) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField("BPM", text: $draft)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 51)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { draft = BPMFilter.format(value) }
            Stepper("", onIncrement: { onChange(BPMFilter.stepped(value, by: 1)) },
                    onDecrement: { onChange(BPMFilter.stepped(value, by: -1)) })
                .labelsHidden()
        }
        .onAppear { draft = BPMFilter.format(value) }
        .onChange(of: value) { draft = BPMFilter.format(value) }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    /// Text that is not a number puts the bound back; a draft equal to the
    /// bound is no change, so tabbing through does not switch the filter on.
    private func commit() {
        guard let parsed = BPMInput.parse(draft) else {
            draft = BPMFilter.format(value)
            return
        }
        draft = BPMFilter.format(parsed)
        guard BPMFilter.format(parsed) != BPMFilter.format(value) else { return }
        onChange(parsed)
    }
}

struct TrackCell: View {
    let track: Track
    let used: Bool
    @Environment(\.accent) private var accent
    @Environment(\.backgroundProminence) private var prominence

    /// The accent, except on a highlighted selection, which is itself drawn
    /// in the accent and would swallow the dot.
    private var dot: Color {
        guard used else { return .clear }
        return prominence == .increased ? .white : accent
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
                .help(used ? "In the mix" : "")
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                if let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct StatusIcon: View {
    let track: Track
    let busy: Bool
    /// How far its separation into stems has got, while it runs.
    var separating: Double? = nil

    var body: some View {
        if busy || track.state == .pending || track.state == .running {
            ProgressView().controlSize(.mini)
        } else if let separating {
            ProgressView(value: separating)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .help("Separating into stems: \(Int(separating * 100)) %")
        } else if track.state == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(track.failure ?? "This track could not be read.")
        } else if track.isCorrected {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .help("Beatgrid corrected by hand")
        } else if let analysis = track.analysis, analysis.isLowConfidence {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help("Low confidence (\(Int(analysis.confidence * 100)) %) – worth checking the beatgrid")
        }
    }
}

/// Audition the selected track.
struct PreviewBar: View {
    let session: MixSession
    let library: Library
    let trackID: UUID?
    /// A song from Apple Music not in the library: auditioned from its file.
    var song: AppleMusicSong? = nil
    @AppStorage(PreviewPlayer.volumeKey) private var volumeDB = 0.0

    var body: some View {
        VStack(spacing: 6) {
            if let id = trackID, let track = library.track(id) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    let preview = session.preview
                    let playing = preview.isPlaying && preview.trackID == id
                    let duration = max(track.durationSeconds, 0.001)
                    HStack(spacing: 10) {
                        Button {
                            if playing {
                                preview.stop()
                            } else {
                                let from = preview.trackID == id && preview.positionSeconds < duration ? preview.positionSeconds : 0
                                session.audition(id, fromSeconds: from)
                            }
                        } label: {
                            Image(systemName: playing ? "stop.fill" : "play.fill").frame(width: 16)
                        }
                        .buttonStyle(.borderless)
                        .disabled(track.state != .done)
                        .help(playing ? "Stop the preview" : "Preview the track")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.displayName).lineLimit(1).font(.callout)
                            Slider(value: Binding(
                                get: { preview.trackID == id ? min(preview.positionSeconds, duration) : 0 },
                                set: { preview.seek(toSeconds: $0) }), in: 0...duration)
                                .controlSize(.mini)
                                .disabled(preview.trackID != id)
                        }
                    }
                }
            } else if let song {
                songRow(song)
            } else {
                Text("Select a track to preview it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 30)
            }
            // What the track can go on to: its beatgrid, or into the mix -
            // the add mode is shown whether or not a track is selected, so
            // the choice can be made before the first one is.
            // In a narrow sidebar the beatgrid button gives up its words,
            // and at the narrowest the volume its speaker, rather than be
            // squeezed to a letter.
            ViewThatFits(in: .horizontal) {
                actions(compact: false)
                actions(compact: true)
                actions(compact: true, speaker: false)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: volumeDB, initial: true) { session.preview.volumeDB = PreviewPlayer.storedVolumeDB() }
    }

    /// Like a track's row, for a song read straight from its file: a spinner
    /// while it is decoded, and the reason when it cannot be.
    private func songRow(_ song: AppleMusicSong) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let preview = session.preview
            let id = song.previewID
            let playing = preview.isPlaying && preview.trackID == id
            let loading = session.pendingAudition == id
            let duration = max(song.seconds, 0.001)
            HStack(spacing: 10) {
                Button {
                    if playing {
                        preview.stop()
                    } else {
                        let from = preview.trackID == id && preview.positionSeconds < duration ? preview.positionSeconds : 0
                        Task {
                            // Its file may not be known yet: looked up first.
                            guard let located = await AppleMusicSource.shared.locate([song.id]).first,
                                  located.block == nil, let url = located.url else { return }
                            session.auditionFile(url, id: id, fromSeconds: from)
                        }
                    }
                } label: {
                    if loading {
                        ProgressView().controlSize(.mini).frame(width: 16)
                    } else {
                        Image(systemName: playing ? "stop.fill" : "play.fill").frame(width: 16)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(song.block != nil || loading)
                .help(song.block?.reason ?? (playing ? "Stop the preview" : "Preview the song from its file in the Music library"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.artist.map { "\($0) – \(song.title)" } ?? song.title).lineLimit(1).font(.callout)
                    Slider(value: Binding(
                        get: { preview.trackID == id ? min(preview.positionSeconds, duration) : 0 },
                        set: { preview.seek(toSeconds: $0) }), in: 0...duration)
                        .controlSize(.mini)
                        .disabled(preview.trackID != id)
                }
            }
        }
    }

    private func actions(compact: Bool, speaker: Bool = true) -> some View {
        HStack(spacing: 8) {
            volume(speaker: speaker)
            Button {
                if let id = trackID { session.beatgridRequest = BeatgridRequest(id: id) }
            } label: {
                if compact { Image(systemName: "ruler") } else { Text("Beatgrid") }
            }
            .fixedSize()
            .disabled(trackID.flatMap { library.track($0) }?.state != .done)
            .help("Edit the selected track's beatgrid in the drawer under the timeline")
            Spacer(minLength: 4)
            AddModeMenu(session: session)
        }
    }

    /// How loud auditioning is, on top of the lanes' resting level - some
    /// masters are far louder than a mix held to a loudness target.
    private func volume(speaker: Bool) -> some View {
        HStack(spacing: 3) {
            if speaker {
                Image(systemName: volumeDB > -10 ? "speaker.wave.3" : volumeDB > -20 ? "speaker.wave.2" : "speaker.wave.1")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
            }
            Slider(value: $volumeDB, in: PreviewPlayer.volumeRange)
                .controlSize(.mini)
                .frame(minWidth: 44, maxWidth: 80)
        }
        .help("Preview volume: \(volumeDB < -0.05 ? "−" : "")\(String(format: "%.0f", abs(volumeDB))) dB")
    }
}

/// Live only, under the preview: Auto, BPM order, and the track Auto would
/// take next - shown before it happens, so the next decision can be seen
/// and changed in time.
struct LiveAutoBar: View {
    let session: MixSession
    let library: Library
    /// The list's rows as they are on screen.
    let order: [UUID]
    @Binding var bpmOrder: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Auto", isOn: Binding(get: { session.autoOn }, set: { session.autoOn = $0 }))
                .help("Whenever nothing waits in the playing set, add the next track of the list below with a Beatmix 4, so the set never runs empty or pauses")
            Toggle("BPM order", isOn: $bpmOrder)
                .help("Sort the list by tempo, slowest first, so Auto goes up the tempo scale")
            let next = session.autoNext(order: order).flatMap { library.track($0) }
            Text(next.map { "Next: \($0.displayName)" } ?? "Next: –")
                .font(.callout)
                .foregroundStyle(session.autoOn ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(next.map { "Auto's next track: \($0.displayName)" } ?? "Nothing left in the list for Auto")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

/// What Return and a double-click in the table do, chosen from every
/// add mode. Shown whether or not a track is selected, so the choice can be
/// made before the first one is.
struct AddModeMenu: View {
    let session: MixSession

    var body: some View {
        Menu {
            item(.plain)
            item(.end(.noTransition))
            Divider()
            ForEach(BeatmixLength.allCases.filter { $0 != .noTransition }) { item(.end($0)) }
            Divider()
            ForEach(BeatmixLength.allCases.filter { $0 != .noTransition }) { item(.playhead($0)) }
            Divider()
            ForEach(BeatmixLength.allCases.filter { $0 != .noTransition }) { item(.cue($0)) }
        } label: {
            Text("Return: \(session.libraryAddMode.shortTitle)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What Return and double-click do: \(session.libraryAddMode.title)")
    }

    private func item(_ mode: LibraryAddMode) -> some View {
        Toggle(mode.title, isOn: Binding(get: { session.libraryAddMode == mode },
                                         set: { if $0 { session.libraryAddMode = mode } }))
    }
}

/// A track's key as its Camelot code and name - "8A Am" - dimmed when the
/// analysis was unsure.
struct KeyCell: View {
    let analysis: KeyAnalysis?

    var body: some View {
        if let analysis {
            HStack(spacing: 4) {
                Text(analysis.key.camelot)
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
                Text(analysis.key.name)
            }
            .foregroundStyle(analysis.isUncertain ? Color.secondary.opacity(0.6) : Color.primary)
            .help(analysis.isUncertain
                  ? "\(analysis.key.name) (\(analysis.key.camelot)) - uncertain: another key fits almost as well"
                  : "\(analysis.key.name) (\(analysis.key.camelot))")
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }
}
