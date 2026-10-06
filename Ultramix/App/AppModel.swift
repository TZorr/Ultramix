//
//  AppModel.swift
//  Ultramix
//
//  Which working directory is open, and the library and mix in it. Nothing is
//  open at launch: the window asks every time.
//
//  Closing one stops both audio engines first. The decoded audio is
//  memory-mapped, and a mapped file on a drive that disappears takes the app
//  down with it, so nothing on the audio thread may still hold a mapping when
//  the library goes.
//

import Foundation
import Observation
import AppKit

@Observable
final class AppModel {
    let store = WorkspaceStore()
    /// Scans and tags songs where they lie; needs no working directory, and
    /// keeps its list while its window is closed.
    let scanner = BPMScanner()
    private(set) var workspace: Workspace?
    private(set) var library: Library?
    /// The mix.
    private(set) var session: MixSession?
    /// The live set, in its own tab beside the mix: a session of its own, so
    /// switching tabs costs neither of them anything, and it plays on while
    /// the mix is looked at. Never saved.
    private(set) var liveSession: MixSession?
    /// Which of the two the window shows.
    var tab: AppTab = .mix

    /// The session the window, the menus and the library work on.
    var activeSession: MixSession? { tab == .live ? liveSession : session }
    /// Shown by the picker: why a working directory could not be opened, or
    /// why the open one was closed.
    var message: String?

    @ObservationIgnored private var access: WorkspaceAccess?
    @ObservationIgnored private var unmountObserver: NSObjectProtocol?

    init() {
        // The lane knobs listen to the MIDI controllers from launch on, not
        // from the first time a lane header happens to draw one.
        _ = LaneKnobController.shared
        // The scanner steps back while a mix plays; it needs to be able to
        // ask, and this is the only place that knows both.
        scanner.isMixPlaying = { [weak self] in
            (self?.session?.isPlaying ?? false) || (self?.liveSession?.isPlaying ?? false)
        }
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let path = note.userInfo?["NSDevicePath"] as? String else { return }
            MainActor.assumeIsolated { self?.volumeWillUnmount(path) }
        }
    }

    func open(_ entry: RecentWorkspace) {
        guard let url = store.resolve(entry) else {
            message = "“\(entry.name)” is not available. Connect its drive, or choose another working directory."
            store.refreshAvailability()
            return
        }
        start(url)
    }

    /// A folder picked in the open panel: an existing working directory, or
    /// any folder to become a new one.
    func choose(_ url: URL) {
        start(url)
    }

    private func start(_ url: URL) {
        do {
            let access = try WorkspaceAccess(url: url)
            let library = Library(workspace: access.workspace)
            let session = MixSession(library: library)
            let live = MixSession(library: library, live: true)
            session.partner = live
            live.partner = session
            // A corrected beatgrid or a finished analysis changes what both
            // play.
            library.onTrackChange = { [weak session, weak live] _ in
                session?.rebuild()
                live?.rebuild()
            }
            // The pitch shifts worth rendering: those either session plays.
            library.wantedShifts = { [weak session, weak live] in
                var wanted = Set<Library.ShiftKey>()
                for s in [session, live].compactMap({ $0 }) {
                    for clip in s.document.clips where !clip.pitch.isNone {
                        wanted.insert(Library.ShiftKey(track: clip.trackID, pitch: clip.pitch))
                    }
                }
                return wanted
            }
            // What the cache's size limit must not take: everything either
            // session plays or auditions.
            library.pinnedTracks = { [weak session, weak live] in
                var pinned = Set<UUID>()
                for s in [session, live].compactMap({ $0 }) {
                    pinned.formUnion(s.document.clips.map(\.trackID))
                    if let id = s.preview.trackID { pinned.insert(id) }
                }
                return pinned
            }
            library.enforceCacheLimit()
            self.access = access
            workspace = access.workspace
            self.library = library
            self.session = session
            liveSession = live
            tab = .mix
            AppDelegate.session = session
            if !store.remember(url) {
                session.message = "“\(url.lastPathComponent)” works for now, but Ultramix could not remember it - choose it again after the next launch."
            }
        } catch {
            message = "“\(url.lastPathComponent)” cannot be used as a working directory: \(error.localizedDescription)"
        }
    }

    /// Closes the working directory. Asks about unsaved changes first unless
    /// `confirm` is false; returns false if the user cancelled.
    @discardableResult
    func close(confirm: Bool = true) -> Bool {
        if confirm, let session, !FilePanels.confirmDiscard(session) { return false }
        session?.shutdown()
        liveSession?.shutdown()
        library?.shutdown()
        AppDelegate.session = nil
        session = nil
        liveSession = nil
        library = nil
        workspace = nil
        access?.close()
        access = nil
        store.refreshAvailability()
        return true
    }

    private func volumeWillUnmount(_ devicePath: String) {
        guard let workspace else { return }
        let root = workspace.root.resolvingSymlinksInPath().path
        guard root == devicePath || root.hasPrefix(devicePath + "/") else { return }
        let unsaved = session?.isDirty == true
        close(confirm: false)
        message = "The drive with “\(workspace.name)” is being ejected, so the working directory was closed."
            + (unsaved ? " Unsaved changes to the mix could not be kept." : "")
    }
}

/// The window's two tabs.
enum AppTab: String, CaseIterable, Identifiable {
    case mix, live
    var id: String { rawValue }
    var title: String { self == .mix ? "Mix" : "Live" }
}
