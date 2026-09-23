//
//  TagWriter.swift
//  Ultramix
//
//  Writes the measured tempo into the song file itself. MP3 gets a TBPM frame
//  (text, so two decimals - 124.50 and 124 are a bar apart after four minutes);
//  M4A gets a `tmpo` atom, a whole number, which is the format's limit.
//
//  Nothing is written unless the value would change, and nothing in place: the
//  new file is built in memory and swapped in by SafeWrite.
//

import Foundation

nonisolated enum TagError: Error, LocalizedError {
    /// The file parses, or does not, in a way this code will not edit. The
    /// file is left exactly as it was.
    case unsupported(String)

    var message: String {
        switch self {
        case .unsupported(let reason): reason
        }
    }

    var errorDescription: String? { message }
}

nonisolated enum TagWriter {
    enum Outcome: Sendable, Equatable {
        case written
        /// The file already says this.
        case unchanged
        case unsupported(String)
    }

    /// Which extensions can take a tempo at all. WAV, AIFF, FLAC and CAF
    /// cannot, here: each would need its own container surgery, and none of
    /// them has a BPM field every program agrees on.
    static let taggable: Set<String> = ["mp3", "m4a", "m4b", "mp4"]

    /// Throws only when the file cannot be read or written; a file this code
    /// will not edit comes back as `.unsupported`, untouched.
    @discardableResult
    static func writeBPM(_ bpm: Double, to url: URL) throws -> Outcome {
        let kind = url.pathExtension.lowercased()
        guard taggable.contains(kind) else {
            return .unsupported("\(kind.isEmpty ? "this format" : kind.uppercased()) takes no BPM tag")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let updated: Data?
        do {
            switch kind {
            case "mp3": updated = try ID3Tag.writingBPM(text(bpm), into: data)
            default: updated = try MP4Tag.writingBPM(Int(bpm.rounded()), into: data)
            }
        } catch let error as TagError {
            return .unsupported(error.message)
        }
        guard let updated else { return .unchanged }
        try SafeWrite.replace(url) { try updated.write(to: $0) }
        return .written
    }

    /// What the file says now, as text - for checking a write from outside.
    static func readBPM(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        switch url.pathExtension.lowercased() {
        case "mp3": return ID3Tag.readBPM(data)
        case "m4a", "m4b", "mp4": return MP4Tag.readBPM(data).map(String.init)
        default: return nil
        }
    }

    /// Two decimals, with a full stop wherever the app is running: this is a
    /// tag another program parses, not a number shown to anybody.
    static func text(_ bpm: Double) -> String {
        String(format: "%.2f", bpm)
    }
}
