//
//  AudioFiles.swift
//  Ultramix
//
//  Which files count as songs, and what a folder holds. The library and the
//  BPM scanner ask the same question and must answer it the same way, or a
//  folder would scan differently from the way it imports.
//
//  By extension rather than by asking AVFoundation: the answer is needed for
//  hundreds of files while a drag is still on screen.
//

import Foundation

nonisolated enum AudioFiles {
    /// What Ultramix accepts: whatever AVAudioFile can decode.
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "wav", "wave", "aif", "aiff", "aifc", "flac", "caf"]

    static func isAudio(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// The songs at `url`: the file itself, or everything inside a folder
    /// and the folders in it, in the order a person would read them.
    static func at(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return isAudio(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var result: [URL] = []
        while let item = walker?.nextObject() as? URL {
            if isAudio(item) { result.append(item) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
