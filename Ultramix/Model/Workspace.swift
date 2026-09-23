//
//  Workspace.swift
//  Ultramix
//
//  The working directory: one folder - on an external drive, say - holding
//  everything a set of mixes needs.
//
//      Ultramix Library.json   the library: tracks, analysis, corrections
//      Audio/                  copies of the imported songs
//      Mixes/                  .ultramix files
//      Bounces/                WAV and MP3 exports
//      Cache/                  decoded audio and waveforms, rebuilt on demand
//
//  Paths are stored relative to the folder, never absolute: a drive mounts
//  under whatever name it has on the machine it is plugged into. Access to the
//  root covers everything inside it, so no file needs a bookmark of its own.
//

import Foundation

nonisolated struct Workspace: Sendable, Equatable {
    static let libraryFileName = "Ultramix Library.json"

    let root: URL

    var name: String { root.lastPathComponent }
    var libraryFile: URL { root.appendingPathComponent(Self.libraryFileName) }
    var audio: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    var mixes: URL { root.appendingPathComponent("Mixes", isDirectory: true) }
    var bounces: URL { root.appendingPathComponent("Bounces", isDirectory: true) }
    var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }

    /// Makes `root` a working directory: creates whichever of the four
    /// folders are missing. Never deletes or overwrites anything, so opening
    /// an existing working directory again is harmless.
    static func prepare(at root: URL) throws -> Workspace {
        let workspace = Workspace(root: root.standardizedFileURL)
        for folder in [workspace.audio, workspace.mixes, workspace.bounces, workspace.cache] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return workspace
    }

    /// The file a stored path names. Relative paths are inside this working
    /// directory; an absolute one - from a library that predates working
    /// directories - is taken as it is.
    ///
    /// Paths out of a mix are checked with `isStorable` first.
    func url(forStoredPath path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// Whether a stored path is one `storedPath(for:)` could have written:
    /// absolute, or relative and inside this working directory.
    ///
    /// A mix is an ordinary JSON document that is passed around and can be
    /// edited, and its track paths are resolved against the working
    /// directory. Without this, "Audio/../../../.." in one would name any
    /// file the sandbox lets the app reach - which the analyser would then
    /// read and "Write BPM to All Files" would rewrite.
    func isStorable(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        guard !path.isEmpty else { return false }
        let base = root.standardizedFileURL.path
        return root.appendingPathComponent(path).standardizedFileURL.path.hasPrefix(base + "/")
    }

    /// How to store a file's location: relative when it is inside this
    /// working directory, absolute otherwise. Symbolic links are resolved on
    /// both sides first - `/tmp` and `/private/tmp` name the same folder.
    func storedPath(for url: URL) -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        if file.hasPrefix(base + "/") { return String(file.dropFirst(base.count + 1)) }
        return file
    }

    /// A name in `folder` that nothing has yet: `Name.mp3`, then `Name 2.mp3`,
    /// `Name 3.mp3`. Never overwrites. `taken` decides what counts as taken -
    /// by default what is on disk; the library adds the copies it has
    /// planned but not finished, so two songs of the same name imported
    /// together do not get the same destination.
    static func uniqueDestination(for fileName: String, in folder: URL,
                                  taken: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var number = 2
        while taken(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
