//
//  FilePanels.swift
//  Ultramix
//
//  Open, save and import panels, and the "save changes?" question. AppKit
//  panels rather than SwiftUI's file importers: they run modally from a menu
//  command without a view to hang them on, and the sandbox grants access to
//  whatever the user picks in them.
//

import AppKit
import UniformTypeIdentifiers

enum FilePanels {
    static let mixType = UTType(exportedAs: "TZorr.Ultramix.mix", conformingTo: .json)

    static func open(_ session: MixSession) {
        guard confirmDiscard(session) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [mixType]
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.library.workspace.mixes
        if panel.runModal() == .OK, let url = panel.url {
            session.open(url)
        }
    }

    /// Opens a mix picked from File › Open Mix - one of the working
    /// directory's own, so no panel and no extra permission.
    static func open(_ session: MixSession, url: URL) {
        guard url.standardizedFileURL != session.fileURL?.standardizedFileURL || session.isDirty else { return }
        guard confirmDiscard(session) else { return }
        session.open(url)
    }

    static func save(_ session: MixSession) {
        if let url = session.fileURL {
            session.save(to: url)
        } else {
            saveAs(session)
        }
    }

    static func saveAs(_ session: MixSession) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [mixType]
        panel.nameFieldStringValue = session.fileURL?.lastPathComponent ?? "\(session.title).\(MixDocument.fileExtension)"
        panel.directoryURL = session.fileURL?.deletingLastPathComponent() ?? session.library.workspace.mixes
        if panel.runModal() == .OK, let url = panel.url {
            session.save(to: url)
        }
    }

    /// Remembered between imports, because the answer is usually the same
    /// every time and re-ticking it is a chore.
    private static let tagOriginalsKey = "writeBPMToOriginalsOnImport"

    static func importTracks(_ library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.message = "Choose audio files, or folders to add everything in them."
        // Whether to copy, preset from Settings and changeable for this
        // import only - the Settings choice stays as it was.
        let copyBox = NSButton(checkboxWithTitle: "Copy into the working directory's Audio folder", target: nil, action: nil)
        copyBox.state = ImportCopy.current() ? .on : .off
        copyBox.toolTip = "Off: the songs are read where they lie, and must stay there. Saves the second copy when they are on the same drive already. The default is set in Settings."
        // The one question worth asking at import: the copy always gets the
        // measured tempo on command, but the original can only be written
        // while the panel's permission for it lasts.
        let box = NSButton(checkboxWithTitle: "Also write the measured BPM into the original files", target: nil, action: nil)
        box.state = UserDefaults.standard.bool(forKey: tagOriginalsKey) ? .on : .off
        box.toolTip = "As each track is analysed, its tempo is written into the file it was imported from - not only into Ultramix's copy."
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 56))
        copyBox.frame = NSRect(x: 16, y: 30, width: 430, height: 20)
        box.frame = NSRect(x: 16, y: 6, width: 430, height: 20)
        holder.addSubview(copyBox)
        holder.addSubview(box)
        panel.accessoryView = holder
        panel.isAccessoryViewDisclosed = true
        if panel.runModal() == .OK {
            let tagOriginals = box.state == .on
            UserDefaults.standard.set(tagOriginals, forKey: tagOriginalsKey)
            library.importItems(panel.urls, tagOriginals: tagOriginals, copy: copyBox.state == .on)
        }
    }

    /// Asks for the folder the originals live in - choosing it is what lets
    /// a sandboxed app write in there - and writes every track's tempo into
    /// the file it came from.
    static func writeOriginals(_ library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Write BPM"
        panel.message = "Choose the folder your original songs live in. Ultramix writes each track's measured tempo into the file it was imported from, and touches nothing else in there."
        panel.directoryURL = library.commonSourceFolder
        if panel.runModal() == .OK, let url = panel.url {
            library.writeBPMTagsToOriginals(in: url)
        }
    }

    static func bounceDestination(for format: BounceFormat, name: String, in directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// True when it is fine to throw the current mix away: nothing unsaved,
    /// saved now, or the user said so.
    static func confirmDiscard(_ session: MixSession) -> Bool {
        guard session.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(session.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(session)
            return !session.isDirty
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}
