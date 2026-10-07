//
//  UltramixApp.swift
//  Ultramix
//
//  One window, one mix, one working directory. Ultramix edits one mix at a
//  time on purpose: the library is shared, and so is the audio device. Two mix
//  windows would compete for both, and neither would be the obvious owner of
//  the transport.
//
//  The window starts on the working-directory picker; the mix appears once a
//  working directory is open (see AppModel).
//

import SwiftUI
import AppKit

@main
struct UltramixApp: App {
    static let scannerWindow = "scanner"
    static let helpWindow = "help"
    static let settingsWindow = "settings"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    /// Dark unless changed: a mix is built with the lights down, and the
    /// waveforms read better on a dark ground.
    @AppStorage("appearance") private var appearance: AppAppearance = .dark
    /// Empty while the system's own accent is in use; see AppAccent.
    @AppStorage("accentColor") private var accentHex = AppAccent.system

    var body: some Scene {
        Window("Ultramix", id: "main") {
            Group {
                if let session = model.activeSession, let library = model.library, let workspace = model.workspace {
                    ContentView(session: session, library: library, workspaceName: workspace.name,
                                tab: Binding(get: { model.tab }, set: { model.tab = $0 }))
                } else {
                    WorkspacePicker(model: model)
                }
            }
            .frame(minWidth: 1000, minHeight: 620)
            .environment(\.accent, AppAccent.color(accentHex))
            .tint(AppAccent.color(accentHex))
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, value in value.apply() }
        }
        .defaultSize(width: 1440, height: 880)
        .commands {
            MixCommands(model: model)
            CommandGroup(before: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.label, systemImage: option.systemImage).tag(option)
                    }
                }
                Divider()
            }
        }
        Window("BPM Scanner", id: Self.scannerWindow) {
            ScannerWindow(scanner: model.scanner)
                .environment(\.accent, AppAccent.color(accentHex))
                .tint(AppAccent.color(accentHex))
        }
        .defaultSize(width: 780, height: 520)
        Window("Ultramix Help", id: Self.helpWindow) {
            HelpView()
                .environment(\.accent, AppAccent.color(accentHex))
                .tint(AppAccent.color(accentHex))
        }
        .defaultSize(width: 920, height: 680)
        // A window of its own rather than SwiftUI's Settings scene: that
        // one could not be resized - a resize edge set in AppKit was there,
        // and dragging it still moved nothing. Here the width follows the
        // form and the height is free above its minimum; the form scrolls.
        Window("Ultramix Settings", id: Self.settingsWindow) {
            // The library, because one setting - converting the copies to
            // 32-bit float - is a piece of work on the open working
            // directory and not just a stored value.
            SettingsView(library: model.library)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 560)
    }
}

/// Asks about unsaved changes before quitting; nothing else.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var session: MixSession?
    private var keyWindowObserver: NSObjectProtocol?

    /// No alert sound for keys nobody wants (see SilentResponder): every
    /// window gets the silent end of the chain when it becomes key.
    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows { SilentResponder.install(in: window) }
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { SilentResponder.install(in: window) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = Self.session else { return .terminateNow }
        return FilePanels.confirmDiscard(session) ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The menus. Every clip command carries a Command-key shortcut: a plain
/// letter as a menu key equivalent would fire while typing a tempo into a
/// text field. The plain keys - Space, Tab, B, L, M, + and −, Delete, the arrows - live on
/// the timeline itself, where they only act while it has focus. Everything
/// that needs a mix is disabled while the working-directory picker shows.
struct MixCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// The session in front: what the clip, undo and transport commands
    /// work on.
    private var session: MixSession? { model.activeSession }
    /// The mix's tab is in front: what saving, opening and bouncing need.
    /// They work on the mix, and doing that behind the live tab, on a mix
    /// nobody can see, would be a surprise.
    private var mixMode: Bool { model.session != nil && model.tab == .mix }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: UltramixApp.settingsWindow) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Mix") {
                if let session, FilePanels.confirmDiscard(session) { session.newMix() }
            }
            .keyboardShortcut("n")
            .disabled(!mixMode)
            Button("Open…") {
                if let session { FilePanels.open(session) }
            }
            .keyboardShortcut("o")
            .disabled(!mixMode)
            // The mixes in the working directory's Mixes folder, newest first:
            // where nearly every mix lives, one pick away. A folder's contents
            // rather than a history - a history remembers mixes that were
            // deleted or belong to another working directory.
            Menu("Open Mix") {
                if let session {
                    ForEach(session.mixFiles, id: \.self) { url in
                        Toggle(url.deletingPathExtension().lastPathComponent, isOn: Binding(
                            get: { url.standardizedFileURL == session.fileURL?.standardizedFileURL },
                            set: { _ in FilePanels.open(session, url: url) }))
                    }
                }
            }
            .disabled(!mixMode || session?.mixFiles.isEmpty ?? true)
            Divider()
            Button("Add Tracks to Library…") {
                if let library = model.library { FilePanels.importTracks(library) }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.library == nil)
            // Deliberately not disabled without a working directory: this is
            // what you do before there is one.
            Button("Scan Files for BPM…") { openWindow(id: UltramixApp.scannerWindow) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            // With nothing selected it writes the whole library, the way
            // Auto Crossfade fades every transition.
            Button(model.library?.selection.isEmpty ?? true ? "Write BPM to All Files" : "Write BPM to Selected Files") {
                guard let library = model.library else { return }
                let ids = library.selection.isEmpty ? Set(library.tracks.map(\.id)) : library.selection
                library.writeBPMTags(ids)
            }
            .disabled(model.library?.tracks.isEmpty ?? true || model.library?.writingTags == true)
            Button("Write BPM to Original Files…") {
                if let library = model.library { FilePanels.writeOriginals(library) }
            }
            .disabled(model.library?.tracks.isEmpty ?? true || model.library?.writingTags == true)
            Divider()
            Button("Switch Working Directory…") { model.close() }
                .disabled(session == nil)
        }
        CommandGroup(replacing: .saveItem) {
            // A live set is never saved or bounced.
            Button("Save") { if let session { FilePanels.save(session) } }
                .keyboardShortcut("s")
                .disabled(!mixMode)
            Button("Save As…") { if let session { FilePanels.saveAs(session) } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!mixMode)
            Divider()
            Button("Bounce Mix…") { session?.showBounce = true }
                .keyboardShortcut("b")
                .disabled(!mixMode || session?.document.clips.isEmpty ?? true)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { session?.undo() }
                .keyboardShortcut("z")
                .disabled(!(session?.canUndo ?? false))
            Button("Redo") { session?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(session?.canRedo ?? false))
        }
        CommandMenu("Clip") {
            Group {
                Button("Split at Playhead") {
                    if let session { session.splitSelection(atBeat: session.playheadBeat()) }
                }
                .keyboardShortcut("t")
                Button("Duplicate") { session?.duplicateSelection() }
                    .keyboardShortcut("d")
                Button("Loop") { session?.toggleLoopSelection() }
                    .keyboardShortcut("l")
                Button(session?.selectedPart != nil ? "Mute Stem" : "Mute Clip") { session?.toggleMuteSelection() }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                Divider()
                Button("Delete") { session?.deleteSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                // No ⌥⌫ equivalent here: a menu key fires before any view
                // sees it, so it would take delete-word away from the text
                // fields, and delete clip automation in the Volume tool where
                // ⌥⌫ means the selected points. The timeline handles ⌥⌫.
                Button("Delete Clip Automation") { session?.deleteSelectionAutomation() }
            }
            .disabled(session?.selection.isEmpty ?? true)
            Divider()
            // Outside the group: with nothing selected they write every
            // transition in the mix.
            Button("Apply \(session?.transitionStyle.title ?? "Crossfade")"
                   + (session?.selection.isEmpty ?? true && session?.selectedMark == nil ? " to All Transitions" : "")) {
                session?.autoCrossfade()
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled((session?.document.clips.count ?? 0) < 2)
            Menu("Transition") {
                if let session {
                    ForEach(TransitionStyle.allCases) { style in
                        Toggle(style.title, isOn: Binding(
                            get: { session.transitionStyle == style },
                            set: { _ in session.autoCrossfade(style) }))
                    }
                }
            }
            .disabled((session?.document.clips.count ?? 0) < 2)
        }
        CommandMenu("Transport") {
            Button("Play / Pause") { session?.togglePlay() }
                .disabled(session == nil)
            Button("Go to Start") { session?.seek(toBeat: 0) }
                .disabled(session == nil)
            // A menu key, not a key handler on the timeline: it has to
            // work wherever the focus is, the beatgrid editor included, and
            // ⌘R takes nothing from a text field.
            Toggle("Record Knobs", isOn: Binding(get: { session?.isRecording ?? false },
                                                 set: { session?.isRecording = $0 }))
                .keyboardShortcut("r")
                .disabled(session == nil || session?.isLive == true)
            Divider()
            ForEach(AppTab.allCases) { tab in
                Toggle(tab.title, isOn: Binding(get: { model.tab == tab }, set: { _ in model.tab = tab }))
                    .keyboardShortcut(tab == .mix ? "1" : "2")
                    .disabled(model.session == nil)
            }
        }
        // Replaces the system's item, which only says that no help exists.
        // Never disabled: help is for before there is a mix, too.
        CommandGroup(replacing: .help) {
            Button("Ultramix Help") { openWindow(id: UltramixApp.helpWindow) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
