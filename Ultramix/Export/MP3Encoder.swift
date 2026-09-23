//
//  MP3Encoder.swift
//  Ultramix
//
//  MP3 export through LAME, compiled in from LAME/ - Core Audio can decode
//  MP3 but has no encoder. LAME is LGPL-2.0; see THIRD_PARTY_NOTICES.md.
//
//  320 kbps CBR, joint stereo, quality 2. Joint stereo at this rate is not the
//  lossy "intensity" kind: LAME decides mid/side per frame. Quality 2 is
//  LAME's own recommendation; 0 and 1 cost several times the time for
//  differences listening tests do not find.
//
//  The mix reaches LAME as floating point (`lame_encode_buffer_ieee_float`),
//  so an MP3 is never built from an already quantised file, and there is no
//  dither - dither is for 16-bit PCM.
//
//  Gapless: LAME records its encoder delay and padding in an Info tag in the
//  first frame, which it can only write once encoding is finished. That frame
//  is reserved at the start and overwritten at the end, which is why the file
//  is opened for update.
//

import Foundation

nonisolated final class MP3Encoder: BounceSink {
    static let bitrate: Int32 = 320
    static let quality: Int32 = 2

    private let flags: lame_t
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var closed = false

    init(url: URL) throws {
        guard let flags = lame_init() else {
            throw BounceError.writeFailed("the MP3 encoder could not be started")
        }
        let rate = Int32(AudioFrames.sampleRate)
        lame_set_in_samplerate(flags, rate)
        lame_set_out_samplerate(flags, rate)
        lame_set_num_channels(flags, 2)
        lame_set_mode(flags, JOINT_STEREO)
        lame_set_VBR(flags, vbr_off)
        lame_set_brate(flags, Self.bitrate)
        lame_set_quality(flags, Self.quality)
        lame_set_bWriteVbrTag(flags, 1)
        guard lame_init_params(flags) >= 0 else {
            lame_close(flags)
            throw BounceError.writeFailed("the MP3 encoder rejected its settings")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forUpdating: url) else {
            lame_close(flags)
            throw BounceError.writeFailed(url.lastPathComponent)
        }
        self.flags = flags
        self.handle = handle
    }

    deinit {
        lame_close(flags)
        if !closed { try? handle.close() }
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws {
        guard count > 0 else { return }
        // LAME's documented worst case for one call: 1.25 × samples + 7200.
        let capacity = count * 5 / 4 + 7200
        if buffer.count < capacity { buffer = [UInt8](repeating: 0, count: capacity) }
        let written = buffer.withUnsafeMutableBufferPointer { out in
            lame_encode_buffer_ieee_float(flags, left, right, Int32(count), out.baseAddress, Int32(out.count))
        }
        guard written >= 0 else { throw BounceError.writeFailed("MP3 encoding failed (LAME error \(written))") }
        if written > 0 {
            try handle.write(contentsOf: Data(buffer[0..<Int(written)]))
        }
    }

    func finish() throws {
        if buffer.count < 7200 { buffer = [UInt8](repeating: 0, count: 7200) }
        let tail = buffer.withUnsafeMutableBufferPointer { out in
            lame_encode_flush(flags, out.baseAddress, Int32(out.count))
        }
        guard tail >= 0 else { throw BounceError.writeFailed("MP3 encoding failed at the end (LAME error \(tail))") }
        if tail > 0 {
            try handle.write(contentsOf: Data(buffer[0..<Int(tail)]))
        }
        // The Info tag, now that delay and padding are known, over the
        // frame LAME left free for it.
        let size = lame_get_lametag_frame(flags, nil, 0)
        if size > 0 {
            var tag = [UInt8](repeating: 0, count: size)
            let filled = tag.withUnsafeMutableBufferPointer { lame_get_lametag_frame(flags, $0.baseAddress, size) }
            if filled > 0 {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data(tag[0..<filled]))
            }
        }
        try handle.close()
        closed = true
    }
}
