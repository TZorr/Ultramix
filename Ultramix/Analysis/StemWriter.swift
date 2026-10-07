//
//  StemWriter.swift
//  Ultramix
//
//  One stored stem as it is written: 16-bit Apple Lossless at 44.1 kHz in a
//  CAF file, at Stem.storedScale. Written beside its destination and moved
//  into place by `finish`, as the cache's files are, so a separation that is
//  cancelled or interrupted never leaves a stem that looks whole. The
//  temporary file ends in .partial.caf - AVAudioFile picks the file type by
//  the extension.
//
//  AudioCache.decode reads it back like any song.
//

import Foundation
@preconcurrency import AVFoundation
import Accelerate

nonisolated final class StemWriter {
    let destination: URL
    private let temporary: URL
    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer
    private static let blockFrames: AVAudioFrameCount = 32_768

    init(to destination: URL) throws {
        self.destination = destination
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial.caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: AudioFrames.sampleRate,
            AVNumberOfChannelsKey: AudioFrames.channels,
            AVEncoderBitDepthHintKey: 16,
        ]
        let opened = try AVAudioFile(forWriting: temporary, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: opened.processingFormat, frameCapacity: Self.blockFrames) else {
            try? FileManager.default.removeItem(at: temporary)
            throw AudioCacheError.unreadable(temporary.lastPathComponent)
        }
        file = opened
        self.buffer = buffer
    }

    deinit {
        if file != nil { cancel() }
    }

    /// Appends `count` frames, at their true level.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws {
        guard let file, let channels = buffer.floatChannelData else { return }
        var scale = Stem.storedScale
        var done = 0
        while done < count {
            let frames = min(Int(Self.blockFrames), count - done)
            vDSP_vsmul(left + done, 1, &scale, channels[0], 1, vDSP_Length(frames))
            vDSP_vsmul(right + done, 1, &scale, channels[1], 1, vDSP_Length(frames))
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            done += frames
        }
    }

    /// Closes the file and moves it into place.
    func finish() throws {
        // AVAudioFile writes its last packets and header when it is released.
        file = nil
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    /// Closes the file and throws it away.
    func cancel() {
        file = nil
        try? FileManager.default.removeItem(at: temporary)
    }
}
