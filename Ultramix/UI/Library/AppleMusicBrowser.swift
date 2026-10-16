//
//  AppleMusicBrowser.swift
//  Ultramix
//
//  The Music app's songs in the library sidebar (see SourceTree for the
//  tree they are chosen in). A song from Music comes into
//  the mix the way any file does - it is imported first, and analysed - by
//  double-click or Return, from the context menu, or by dragging it onto
//  Ultramix Library. A whole playlist comes in from its own context menu.
//  A song already in the library (✓) goes into the mix like any track
//  there: by double-click or Return, or dragged onto a lane. Dragged onto a
//  lane before it is in the library, a song is imported and put there once
//  its analysis is done.
//
//  Songs that cannot come in - protected, only in the cloud - are listed
//  all the same, dimmed, with the reason on their symbol: a playlist that
//  silently left half its songs out would look broken.
//

import SwiftUI
import AppKit

/// A song dragged out of the Apple Music list. Not a file URL: dropped on
/// the Finder, that would copy the song out of the Music library.
nonisolated enum AppleMusicDrag {
    static let prefix = "applemusic:"

    static func payload(_ id: UInt64) -> String { prefix + String(id) }

    static func id(_ text: String) -> UInt64? {
        guard text.hasPrefix(prefix) else { return nil }
        return UInt64(text.dropFirst(prefix.count))
    }
}

/// One row of the Apple Music list: the song, and the track it became if it
/// was imported - whose tempo and key then show instead of Music's.
struct AppleMusicRow: Identifiable {
    let song: AppleMusicSong
    let track: Track?

    var id: UInt64 { song.id }
    var bpm: Double? { track?.bpm ?? song.bpm.map(Double.init) }
    var bpmSortValue: Double { bpm ?? 0 }
    var keySortValue: Int { track?.key?.key.sortValue ?? -1 }
    var artistSortValue: String { song.artist ?? "" }
}

/// The songs of the Apple Music entry chosen in the tree.
struct AppleMusicTable: View {
    let rows: [AppleMusicRow]
    @Binding var selection: Set<UInt64>
    @Binding var sortOrder: [KeyPathComparator<AppleMusicRow>]
    let library: Library
    let importSongs: ([UInt64]) -> Void
    /// Double-click and Return: into the mix if in the library, else in.
    let activate: ([UInt64]) -> Void
    /// Imported first where they are not in the library yet.
    let addToCrate: ([UInt64], UUID) -> Void
    let newCrate: ([UInt64]) -> Void

    var body: some View {
        Table(of: AppleMusicRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Track", value: \.song.title) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.song.title).lineLimit(1)
                    if let artist = row.song.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .opacity(row.song.block == nil ? 1 : 0.45)
            }
            .width(min: 100, ideal: 150)
            TableColumn("BPM", value: \.bpmSortValue) { row in
                Text(row.bpm.map { row.track?.bpm != nil ? String(format: "%.2f", $0) : String(Int($0)) } ?? "–")
                    .monospacedDigit()
                    // Music's own figure, until Ultramix has measured it.
                    .foregroundStyle(row.track?.bpm != nil ? Color.primary : Color.secondary)
                    .help(row.track?.bpm != nil ? "Measured by Ultramix" : row.bpm != nil ? "As set in Music" : "")
            }
            .width(58)
            TableColumn("Time", value: \.song.seconds) { row in
                Text(row.song.seconds > 0
                     ? "\(Int(row.song.seconds) / 60):\(String(format: "%02d", Int(row.song.seconds) % 60))"
                     : "–")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(44)
            TableColumn("Key", value: \.keySortValue) { row in
                KeyCell(analysis: row.track?.key)
            }
            .width(64)
            TableColumn("") { row in
                status(row)
            }
            .width(18)
        } rows: {
            ForEach(rows) { row in
                // Imported, it is a track like any in the library. Not yet,
                // a lane imports it and Ultramix Library only imports it.
                if let track = row.track {
                    TableRow(row).draggable(track.id.uuidString)
                } else if row.song.block == nil {
                    TableRow(row).draggable(AppleMusicDrag.payload(row.id))
                } else {
                    TableRow(row)
                }
            }
        }
        .contextMenu(forSelectionType: UInt64.self) { ids in
            Button(ids.count == 1 ? "Add to Library" : "Add \(ids.count) Songs to Library") {
                importSongs(ordered(ids))
            }
            .disabled(!rows.contains { ids.contains($0.id) && $0.song.block == nil && $0.track == nil })
            AddToCrateMenu(crates: library.crates) { crate in
                addToCrate(ordered(ids), crate)
            } newCrate: {
                newCrate(ordered(ids))
            }
            .disabled(!rows.contains { ids.contains($0.id) && $0.song.block == nil })
            if ids.count == 1, let url = rows.first(where: { ids.contains($0.id) })?.song.url {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        } primaryAction: { ids in
            activate(ordered(ids))
        }
    }

    /// Imported or not, and while it is analysed, how far it has got; or
    /// why it cannot come in.
    @ViewBuilder
    private func status(_ row: AppleMusicRow) -> some View {
        if let block = row.song.block {
            Image(systemName: block.symbol)
                .foregroundStyle(.secondary)
                .help(block.reason)
        } else if let track = row.track {
            if track.state == .done, !library.busy.contains(track.id) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .help("In the library")
            } else {
                StatusIcon(track: track, busy: library.busy.contains(track.id))
            }
        }
    }

    private func ordered(_ ids: Set<UInt64>) -> [UInt64] {
        rows.map(\.id).filter { ids.contains($0) }
    }
}
