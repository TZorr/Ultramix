//
//  WorkspacePicker.swift
//  Ultramix
//
//  What the window shows before a working directory is open: the ones this Mac
//  has used, the last preselected so Return opens it, and a way to choose or
//  create another. Shown on every launch by design - the point of a working
//  directory on an external drive is that which one is in use can change from
//  one session to the next.
//

import SwiftUI
import AppKit
import Combine

struct WorkspacePicker: View {
    let model: AppModel
    @State private var selection: UUID?
    @Environment(\.accent) private var accent

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a Working Directory")
                        .font(.title2.weight(.semibold))
                    Text("Ultramix keeps everything for your mixes in one folder – the library, copies of the songs, the mixes, the bounces and the audio cache. It can live on an external drive.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if store.recents.isEmpty {
                ContentUnavailableView("No Working Directory Yet", systemImage: "externaldrive",
                                       description: Text("Choose a folder to start - an empty one becomes a new working directory."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List(selection: $selection) {
                    ForEach(store.recents) { entry in
                        row(entry, online: store.available.contains(entry.id))
                            .tag(entry.id)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Remove from List") { remove(ids) }
                } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
                .frame(minHeight: 220)
            }

            HStack {
                Button("Remove from List") {
                    if let selection { remove([selection]) }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Choose Folder…") { choose() }
                Button("Open") {
                    if let selection { open(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.map { !store.available.contains($0) } ?? true)
            }
        }
        .padding(28)
        .frame(maxWidth: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Ultramix")
        .onAppear {
            store.refreshAvailability()
            selection = store.recents.first { store.available.contains($0.id) }?.id
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            store.refreshAvailability()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            store.refreshAvailability()
        }
        .alert("Ultramix", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private func row(_ entry: RecentWorkspace, online: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: online ? "folder.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(online ? accent : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body.weight(.medium))
                Text(online ? entry.path : "\(entry.path) – not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(entry.lastUsed, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .opacity(online ? 1 : 0.55)
    }

    private func open(_ id: UUID) {
        guard let entry = model.store.recents.first(where: { $0.id == id }) else { return }
        model.open(entry)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Working Directory"
        panel.message = "Choose an existing working directory, or a folder - an empty one, or a new one - to start a new working directory."
        if panel.runModal() == .OK, let url = panel.url {
            model.choose(url)
        }
    }

    private func remove(_ ids: Set<UUID>) {
        for entry in model.store.recents where ids.contains(entry.id) {
            model.store.remove(entry)
        }
        if let selected = selection, ids.contains(selected) { selection = nil }
    }
}
