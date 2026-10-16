//
//  FilePreview.swift
//  Ultramix
//
//  Songs auditioned before they are in the library - from Apple Music -
//  decoded the way the library decodes (AudioCache) into a temporary folder
//  of their own, so nothing of them reaches the working directory, its
//  library or its cache. Only the last few are kept; the rest are deleted as
//  the next one comes in, and the system clears the folder in any case.
//

import Foundation

nonisolated enum FilePreview {
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Previews", isDirectory: true)
    }

    static func file(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).f32")
    }

    /// Decodes `source` and maps the result. Off the main thread: a song
    /// takes about a second.
    static func decode(_ source: URL, id: UUID) throws -> AudioFrames {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = file(id)
        try AudioCache.decode(source, to: destination)
        return try AudioFrames(mapping: destination)
    }

    /// Deletes every decoded preview but these. One still playing is safe:
    /// its mapping outlives the file.
    static func keepOnly(_ ids: [UUID]) {
        let keep = Set(ids.map { "\($0.uuidString).f32" })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
