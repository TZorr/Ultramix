//
//  TagReader.swift
//  Ultramix
//
//  Artist and title from whatever tags the file carries. AVFoundation maps
//  ID3, iTunes atoms and Vorbis comments onto the same common keys, so there
//  is no tag parser to keep.
//

import Foundation
import AVFoundation

nonisolated enum TagReader {
    struct Tags: Sendable {
        var title: String?
        var artist: String?
    }

    static func read(_ url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return Tags() }
        async let title = string(items, .commonIdentifierTitle)
        async let artist = string(items, .commonIdentifierArtist)
        return await Tags(title: title, artist: artist)
    }

    private static func string(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
