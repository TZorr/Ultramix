//
//  ScannerWindow.swift
//  Ultramix
//
//  The BPM scanner's window: drop songs on it and they come back with their
//  tempo written into their own tags.
//
//  A window of its own rather than a panel in the mix, because this is what
//  you do *before* there is a mix - often before a working directory is open.
//  Nothing here touches the library. The table is sortable on every column:
//  sorted by BPM the tempo groups in a playlist stand out at a glance.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScannerWindow: View {
    @Bindable var scanner: BPMScanner
    @State private var sortOrder = [KeyPathComparator(\BPMScanner.Item.bpmSortValue, order: .reverse)]
    @State private var selection: Set<UUID> = []
    @State private var correcting: CorrectionRequest?

    private struct CorrectionRequest: Identifiable {
        let id: UUID
    }

    private var rows: [BPMScanner.Item] { scanner.items.sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Song", value: \.name) { item in
                    Text(item.name).lineLimit(1).help(item.url.path)
                }
                TableColumn("BPM", value: \.bpmSortValue) { item in
                    Text(item.bpm.map { String(format: "%.2f", $0) } ?? "–")
                        .monospacedDigit()
                }
                .width(64)
                // A percentage means Ultramix measured this file in this
                // pass; a dash means the number came out of its tag.
                TableColumn("Measured", value: \.confidenceSortValue) { item in
                    Text(item.corrected ? "by hand" : item.confidence.map { "\(Int($0 * 100)) %" } ?? "–")
                        .monospacedDigit()
                        .foregroundStyle((item.confidence ?? 1) < 0.35 ? Color.orange : Color.secondary)
                        .help(item.confidence == nil
                              ? "The tempo was already in the file"
                              : "How well a steady grid fitted - below 35 % is worth hearing for yourself")
                }
                .width(80)
                TableColumn("Status", value: \.stateSortValue) { item in
                    HStack(spacing: 6) {
                        if item.state == .running { ProgressView().controlSize(.mini) }
                        if item.state == .tagged {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        }
                        Text(item.note ?? item.state.rawValue)
                            .foregroundStyle(item.state == .failed || item.state == .untaggable
                                             ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .help(item.note ?? "")
                    }
                }
                .width(min: 110, ideal: 160)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Correct BPM") { ids.first.map { correct($0) } }
                    .disabled(ids.count != 1 || !canCorrect(ids.first))
                Button("Show in Finder") { showInFinder(ids) }
                    .disabled(ids.isEmpty)
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first { correct(id) }
            }
            .sheet(item: $correcting) { request in
                correctionSheet(request.id)
            }
            .overlay {
                if scanner.items.isEmpty { emptyState }
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        // Songs, folders, a selection dragged straight out of Music: all of
        // it arrives here as file URLs, and a dropped file is one the
        // sandbox lets us write back to.
        .dropDestination(for: URL.self) { urls, _ in
            scanner.add(urls)
            return true
        }
        .navigationTitle("BPM Scanner")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Drop Songs Here", systemImage: "metronome")
        } description: {
            Text("Drag songs, folders or a selection from Music onto this window. "
                 + "Ultramix measures the tempo and writes it into the files themselves - "
                 + "nothing is copied, and nothing is added to a library.")
        } actions: {
            Button("Choose Files…") { choose() }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Choose Files…") { choose() }
            if scanner.isGathering {
                ProgressView().controlSize(.small)
                Text("Looking through the folders…").font(.caption).foregroundStyle(.secondary)
            } else if scanner.isScanning {
                let progress = scanner.progress
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 180)
                Text("\(progress.done) of \(progress.total)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Stop") { scanner.stop() }
            } else {
                Text(scanner.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("Measure tagged files again", isOn: $scanner.measureTagged)
                .toggleStyle(.checkbox)
                .help("Off: a song that already carries a BPM is listed with the value it has and not measured again.")
            Button("Scan Again") { scanner.scanAgain() }
                .disabled(scanner.items.isEmpty || scanner.isScanning)
            Button("Clear") { scanner.clear() }
                .disabled(scanner.items.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.message = "Choose songs, or folders to scan everything in them. "
            + "Ultramix writes the measured tempo into these files and copies nothing."
        panel.prompt = "Scan"
        if panel.runModal() == .OK {
            scanner.add(panel.urls)
        }
    }

    // MARK: - Correcting a tempo

    private func canCorrect(_ id: UUID?) -> Bool {
        guard let id, let item = scanner.item(id) else { return false }
        return item.state != .running && item.state != .queued
    }

    private func correct(_ id: UUID) {
        guard canCorrect(id) else { return }
        correcting = CorrectionRequest(id: id)
    }

    @ViewBuilder
    private func correctionSheet(_ id: UUID) -> some View {
        if let item = scanner.item(id) {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .padding([.horizontal, .top], 18)
                BPMCorrectionPanel(detected: item.bpm, sourceLabel: sourceLabel(item), note: note(item)) { bpm in
                    scanner.correct(id, bpm: bpm)
                    correcting = nil
                } accessory: {
                    listenButton(id)
                }
            }
            .onDisappear { scanner.stopAudition() }
        }
    }

    private func listenButton(_ id: UUID) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let playing = scanner.auditionID == id && scanner.preview.isPlaying && scanner.preview.trackID == id
            HStack(spacing: 6) {
                if scanner.isPreparingAudition && scanner.auditionID == id {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    if playing { scanner.stopAudition() } else { scanner.audition(id) }
                } label: {
                    Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
                }
                .controlSize(.small)
            }
        }
    }

    private func sourceLabel(_ item: BPMScanner.Item) -> String {
        if item.corrected { return "Set by hand" }
        if item.confidence != nil { return "Automatic analysis" }
        return item.bpm == nil ? "Not measured" : "From the file's tag"
    }

    private func note(_ item: BPMScanner.Item) -> String? {
        switch item.url.pathExtension.lowercased() {
        case "mp3": return nil
        case "m4a", "m4b", "mp4": return "This format stores whole numbers only; the tag gets the nearest one."
        default: return "This format takes no BPM tag - the tempo is corrected in this list only."
        }
    }

    private func showInFinder(_ ids: Set<UUID>) {
        let urls = scanner.items.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
