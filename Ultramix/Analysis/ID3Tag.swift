//
//  ID3Tag.swift
//  Ultramix
//
//  Writes a BPM into an MP3's ID3v2 tag and leaves every other byte alone:
//  only TBPM is ours, all other frames are copied verbatim, unknown ones
//  included (cue points live in GEOB frames).
//
//  Both v2.3 (plain 32-bit frame sizes) and v2.4 (synchsafe) are written; a
//  file keeps the version it had, one with no tag gets v2.3. Refused rather
//  than half-understood: v2.2, and any unsynchronised tag or one with an
//  extended header or footer.
//

import Foundation

nonisolated enum ID3Tag {
    static let frameID = "TBPM"

    private struct Frame {
        var id: String
        var flags: (UInt8, UInt8)
        var body: [UInt8]
    }

    /// The file with `text` as its BPM frame, or nil when it already says
    /// that. Throws `TagError.unsupported` for a tag this code will not
    /// touch.
    static func writingBPM(_ text: String, into data: Data) throws -> Data? {
        let bytes = [UInt8](data)
        var frames: [Frame] = []
        var version: UInt8 = 3
        var audioStart = 0
        var tagSize = 0

        if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            version = bytes[3]
            let flags = bytes[5]
            guard version == 3 || version == 4 else {
                throw TagError.unsupported("ID3v2.\(version) tags are not written by Ultramix")
            }
            guard flags & 0xF0 == 0 else {
                throw TagError.unsupported("the tag is unsynchronised or has an extended header")
            }
            guard let size = synchsafe(bytes, 6) else {
                throw TagError.unsupported("the tag's length is not readable")
            }
            tagSize = Int(size)
            audioStart = 10 + tagSize
            guard audioStart <= bytes.count else {
                throw TagError.unsupported("the tag reaches past the end of the file")
            }
            frames = try readFrames(bytes, from: 10, to: audioStart, version: version)
        }

        let body: [UInt8] = [0] + Array(text.unicodeScalars.map { UInt8($0.value & 0xFF) })
        if let existing = frames.first(where: { $0.id == frameID }), existing.body == body { return nil }
        if let i = frames.firstIndex(where: { $0.id == frameID }) {
            frames[i].body = body
        } else {
            frames.append(Frame(id: frameID, flags: (0, 0), body: body))
        }

        var payload: [UInt8] = []
        for frame in frames {
            payload += Array(frame.id.utf8)
            payload += version == 4 ? synchsafeBytes(frame.body.count) : bigEndian(frame.body.count)
            payload += [frame.flags.0, frame.flags.1]
            payload += frame.body
        }
        // The tag keeps the length it had whenever the frames still fit: the
        // audio then starts where it started, and the padding another tagger
        // left stays available.
        let length = max(payload.count, tagSize)
        payload += [UInt8](repeating: 0, count: length - payload.count)

        var result: [UInt8] = [0x49, 0x44, 0x33, version, 0, 0]
        result += synchsafeBytes(length)
        result += payload
        result += bytes[audioStart...]
        return Data(result)
    }

    /// What the file's BPM frame says, for checking a write. Nil when there
    /// is no tag or no frame - never throws, it is only ever a report.
    static func readBPM(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
              bytes[3] == 3 || bytes[3] == 4, bytes[5] & 0xF0 == 0,
              let size = synchsafe(bytes, 6), 10 + Int(size) <= bytes.count,
              let frames = try? readFrames(bytes, from: 10, to: 10 + Int(size), version: bytes[3]),
              let frame = frames.first(where: { $0.id == frameID }), frame.body.count > 1 else { return nil }
        return String(decoding: frame.body.dropFirst(), as: UTF8.self)
    }

    // MARK: - Reading

    private static func readFrames(_ bytes: [UInt8], from start: Int, to end: Int,
                                   version: UInt8) throws -> [Frame] {
        var frames: [Frame] = []
        var offset = start
        while offset + 10 <= end {
            // Four zero bytes are the start of the padding, not a frame.
            if bytes[offset] == 0 { break }
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            guard id.count == 4, id.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
                throw TagError.unsupported("the tag holds a frame Ultramix cannot read")
            }
            let size: Int
            if version == 4 {
                guard let value = synchsafe(bytes, offset + 4) else {
                    throw TagError.unsupported("a frame's length is not readable")
                }
                size = Int(value)
            } else {
                size = Int(bytes[offset + 4]) << 24 | Int(bytes[offset + 5]) << 16
                     | Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
            }
            let bodyStart = offset + 10
            guard size >= 0, bodyStart + size <= end else {
                throw TagError.unsupported("a frame reaches past the end of the tag")
            }
            frames.append(Frame(id: id, flags: (bytes[offset + 8], bytes[offset + 9]),
                                body: Array(bytes[bodyStart..<bodyStart + size])))
            offset = bodyStart + size
        }
        return frames
    }

    // MARK: - Numbers

    /// Seven bits per byte, so that a length can never look like an MPEG
    /// frame's sync word. A byte with its top bit set is not synchsafe.
    private static func synchsafe(_ bytes: [UInt8], _ at: Int) -> UInt32? {
        guard at + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 {
            guard bytes[at + i] & 0x80 == 0 else { return nil }
            value = value << 7 | UInt32(bytes[at + i])
        }
        return value
    }

    private static func synchsafeBytes(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    private static func bigEndian(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
