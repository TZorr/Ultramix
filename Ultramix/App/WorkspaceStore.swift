//
//  WorkspaceStore.swift
//  Ultramix
//
//  The working directories this Mac has used, and the sandbox's permission to
//  the one that is open.
//
//  The sandbox forgets a picked folder at quit; what survives is a
//  security-scoped bookmark, so that is what the list holds - in UserDefaults,
//  because the list has to be readable before any working directory is. A
//  drive that is not connected is shown unavailable rather than dropped.
//

import Foundation
import Observation

struct RecentWorkspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var bookmark: Data
    var lastUsed: Date
}

@Observable
final class WorkspaceStore {
    /// Most recently used first.
    private(set) var recents: [RecentWorkspace] = []
    /// The entries whose folder is reachable right now.
    private(set) var available: Set<UUID> = []

    private static let key = "workingDirectories"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([RecentWorkspace].self, from: data) {
            recents = stored.sorted { $0.lastUsed > $1.lastUsed }
        }
        refreshAvailability()
    }

    /// The folder behind an entry, or nil when it cannot be reached - its
    /// drive is not connected, or the folder is gone. Never tries to mount
    /// anything or show UI: a picker that stalls on a missing network share
    /// would be worse than one that says "not connected".
    func resolve(_ entry: RecentWorkspace) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark,
                                 options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    func refreshAvailability() {
        available = Set(recents.filter { resolve($0) != nil }.map(\.id))
    }

    /// Records `url` as the most recently used working directory, with a
    /// fresh bookmark. Call while access to it is held. False if no bookmark
    /// could be made - the folder then works for this session only.
    @discardableResult
    func remember(_ url: URL) -> Bool {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        let path = url.standardizedFileURL.path
        if let i = recents.firstIndex(where: { $0.path == path }) {
            recents[i].bookmark = bookmark
            recents[i].name = url.lastPathComponent
            recents[i].lastUsed = Date()
        } else {
            recents.append(RecentWorkspace(id: UUID(), name: url.lastPathComponent, path: path,
                                           bookmark: bookmark, lastUsed: Date()))
        }
        recents.sort { $0.lastUsed > $1.lastUsed }
        save()
        refreshAvailability()
        return true
    }

    /// Takes an entry off the list. The folder itself is not touched.
    func remove(_ entry: RecentWorkspace) {
        recents.removeAll { $0.id == entry.id }
        available.remove(entry.id)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Holds the sandbox's permission to an open working directory for as long
/// as it is open, and makes sure the folder structure exists.
nonisolated final class WorkspaceAccess: @unchecked Sendable {
    let workspace: Workspace
    private let url: URL
    private var accessing: Bool

    init(url: URL) throws {
        self.url = url
        // False for a folder just picked in an open panel - that access is
        // already granted for the session - and true for one reopened from
        // a bookmark, which has to be released again.
        accessing = url.startAccessingSecurityScopedResource()
        do {
            workspace = try Workspace.prepare(at: url)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func close() {
        guard accessing else { return }
        url.stopAccessingSecurityScopedResource()
        accessing = false
    }

    deinit {
        close()
    }
}
