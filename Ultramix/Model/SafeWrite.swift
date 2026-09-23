//
//  SafeWrite.swift
//  Ultramix
//
//  Replacing a file without ever leaving it half-written. The new file is
//  written under a temporary name and swapped in with replaceItemAt, which
//  never deletes the old file first. Where the temporary may go depends on the
//  destination:
//
//  1. Beside it. Inside the working directory the app may create files
//     anywhere, and a swap within one folder is the most atomic move there is.
//     It is also the only thing that works on an external drive: the system's
//     temporary folder for that volume sits at the volume's root, outside the
//     folder the user granted.
//  2. The system's item-replacement directory, when the app may not create
//     files beside the destination - a save panel grants access to exactly the
//     one path the user chose.
//  3. The app's own temporary folder, as a last resort.
//

import Foundation

nonisolated enum SafeWrite {
    /// Calls `body` with a temporary URL to write to, then moves the result
    /// over `url`. If `body` throws, `url` is untouched.
    static func replace(_ url: URL, writing body: (URL) throws -> Void) throws {
        let files = FileManager.default
        let name = "\(UUID().uuidString)-\(url.lastPathComponent)"
        let sibling = url.deletingLastPathComponent().appendingPathComponent(".\(name)")
        var replacement: URL?
        let temporary: URL
        if files.createFile(atPath: sibling.path, contents: nil) {
            temporary = sibling
        } else {
            replacement = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: url, create: true)
            temporary = (replacement ?? files.temporaryDirectory).appendingPathComponent(name)
        }
        defer {
            try? files.removeItem(at: temporary)
            // Only the folder made for this save; never the shared temp dir.
            if let replacement { try? files.removeItem(at: replacement) }
        }
        try body(temporary)
        if files.fileExists(atPath: url.path) {
            _ = try files.replaceItemAt(url, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: url)
        }
    }
}
