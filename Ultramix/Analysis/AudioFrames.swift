//
//  AudioFrames.swift
//  Ultramix
//
//  Every track decoded once into interleaved stereo Float32 at 44.1 kHz and
//  memory-mapped from the cache, so analysis, waveform, preview, playback and
//  bounce all read the same samples: no I/O on the render callback, one sample
//  rate for the stretcher, and one decoder, so the grid cannot shift against
//  the music. Costs 10 MB a stereo minute; see AudioCacheLimit.
//

import Foundation
// The converter's input block runs synchronously inside `convert`, on this
// thread; AVFAudio's buffers simply predate Sendable annotations.
@preconcurrency import AVFoundation
import Accelerate

/// Memory-mapped (or, for tests, owned) interleaved stereo Float32 frames at
/// `AudioFrames.sampleRate`.
///
/// A class, not a struct: it owns a mapping that must be unmapped exactly
/// once. Immutable after init, so sharing it across threads is safe.
nonisolated final class AudioFrames: @unchecked Sendable {
    static let sampleRate = 44_100.0
    static let channels = 2

    let frameCount: Int
    /// `frameCount * 2` samples, L R L R …
    let samples: UnsafePointer<Float>

    private let mapping: (base: UnsafeMutableRawPointer, length: Int)?
    private let owned: UnsafeMutablePointer<Float>?

    var duration: Double { Double(frameCount) / Self.sampleRate }

    /// Maps a cache file. The mapping is private and read-only; the file can
    /// be replaced on disk while mapped without affecting this instance.
    init(mapping url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw AudioCacheError.unreadable(url.lastPathComponent) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AudioCacheError.unreadable(url.lastPathComponent) }
        let length = Int(info.st_size)
        let frameBytes = MemoryLayout<Float>.size * Self.channels
        guard length >= frameBytes, length % frameBytes == 0 else {
            throw AudioCacheError.corrupt(url.lastPathComponent)
        }
        guard let base = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), base != MAP_FAILED else {
            throw AudioCacheError.unreadable(url.lastPathComponent)
        }
        mapping = (base, length)
        owned = nil
        frameCount = length / frameBytes
        samples = UnsafePointer(base.assumingMemoryBound(to: Float.self))
    }

    /// Copies interleaved stereo samples. For the harness and for short
    /// generated sounds (the metronome click).
    init(interleaved: [Float]) {
        precondition(interleaved.count % Self.channels == 0)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(interleaved.count, 2))
        interleaved.withUnsafeBufferPointer { source in
            buffer.update(from: source.baseAddress!, count: interleaved.count)
        }
        owned = buffer
        mapping = nil
        frameCount = interleaved.count / Self.channels
        samples = UnsafePointer(buffer)
    }

    deinit {
        if let mapping { munmap(mapping.base, mapping.length) }
        owned?.deallocate()
    }

    /// Brings `frames` into memory, so the audio thread finds them there.
    ///
    /// A mapped page that is not resident is read from the drive the moment
    /// it is touched - on the audio thread, if that is where it is first
    /// touched. From an external SSD that costs 0.5 to 1.5 ms per miss
    /// (measured, drive idle), out of the 11.6 ms a 512-frame buffer lasts,
    /// and more while the same drive is copying or decoding. `madvise` asks
    /// the kernel to read ahead without waiting; reading one value per page
    /// makes sure, and returns it so the reads cannot be optimised away.
    /// Owned buffers are already in memory and return at once.
    @discardableResult
    func prefetch(_ frames: Range<Int>) -> Float {
        guard let mapping else { return 0 }
        let frameBytes = MemoryLayout<Float>.size * Self.channels
        let page = Int(getpagesize())
        let from = max(0, frames.lowerBound) * frameBytes / page * page
        let to = min(mapping.length, max(0, frames.upperBound) * frameBytes)
        guard from < to else { return 0 }
        madvise(mapping.base + from, to - from, MADV_WILLNEED)
        var sum: Float = 0
        for offset in Swift.stride(from: from, to: to, by: page) {
            sum += mapping.base.load(fromByteOffset: offset, as: Float.self)
        }
        return sum
    }

    /// (L + R) / 2 as a new array - what the analysers listen to.
    func monoMix() -> [Float] {
        var mono = [Float](repeating: 0, count: frameCount)
        guard frameCount > 0 else { return mono }
        mono.withUnsafeMutableBufferPointer { out in
            vDSP_vadd(samples, 2, samples + 1, 2, out.baseAddress!, 1, vDSP_Length(frameCount))
            var half: Float = 0.5
            vDSP_vsmul(out.baseAddress!, 1, &half, out.baseAddress!, 1, vDSP_Length(frameCount))
        }
        return mono
    }
}

nonisolated enum AudioCacheError: Error, LocalizedError {
    case unreadable(String)
    case corrupt(String)
    case undecodable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) could not be opened."
        case .corrupt(let name): "The cached audio for \(name) is damaged."
        case .undecodable(let name): "\(name) is not an audio file Ultramix can read."
        }
    }
}

nonisolated enum AudioCache {

    /// Decodes `source` into the cache file at `destination` and returns the
    /// number of frames written.
    ///
    /// The file is written beside its destination and renamed into place at
    /// the end, so a decode interrupted by quitting never leaves a truncated
    /// cache file that would later map without complaint.
    @discardableResult
    static func decode(_ source: URL, to destination: URL) throws -> Int {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var frames = 0
        do {
            frames = try convert(source, into: temporary)
        } catch {
            // Some MP3s the packet reader will not touch - it refuses the
            // very first read with 'dta?', and afconvert refuses them the
            // same way - come through the asset pipeline without a
            // complaint. Half a percent of a real library, and they are
            // records like any other, so they get the second way in.
            try? FileManager.default.removeItem(at: temporary)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            frames = try convertWithReader(source, into: temporary)
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        return frames
    }

    /// The way round for files ExtAudioFile refuses: AVAssetReader, asked
    /// for exactly the format the cache holds. It resamples with its own
    /// converter rather than the mastering one, which only shows on a file
    /// that is not at 44.1 kHz already - and this is the path that would
    /// otherwise be no path at all.
    static func convertWithReader(_ source: URL, into output: URL) throws -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = Result<Int, Error>
            .failure(AudioCacheError.undecodable(source.lastPathComponent))
        Task.detached {
            do {
                outcome = .success(try await read(source, into: output))
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }

    private static func read(_ source: URL, into output: URL) async throws -> Int {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            throw AudioCacheError.undecodable(name)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: AudioFrames.sampleRate,
            AVNumberOfChannelsKey: AudioFrames.channels,
        ]
        let tap = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(tap) else { throw AudioCacheError.undecodable(name) }
        reader.add(tap)
        guard reader.startReading() else { throw AudioCacheError.undecodable(name) }
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var frames = 0
        while let sample = tap.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: bytes.baseAddress!)
            }
            guard copied == noErr else { throw AudioCacheError.undecodable(name) }
            handle.write(data)
            frames += length / (MemoryLayout<Float>.size * AudioFrames.channels)
        }
        guard reader.status == .completed, frames > 0 else { throw AudioCacheError.undecodable(name) }
        return frames
    }

    /// The conversion itself, in its own function: an AVAudioFile finishes
    /// its work when it is released, and Swift only releases at the end of a
    /// scope, not at last use.
    private static func convert(_ source: URL, into output: URL) throws -> Int {
        let name = source.lastPathComponent
        let file: AVAudioFile
        do {
            // An explicit processing format: the default is deinterleaved
            // float, but saying so means a change of default can never make
            // `read(into:)` fail with a bare −50.
            file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioCacheError.undecodable(name)
        }
        let inFormat = file.processingFormat
        guard inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFrames.sampleRate,
                                            channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioCacheError.undecodable(name)
        }
        if inFormat.channelCount == 1 {
            // Mono goes to both sides at full level, not −3 dB each: a mono
            // record should sound as loud as a stereo one in the mix.
            converter.channelMap = [0, 0]
        } else if inFormat.channelCount > 2 {
            converter.downmix = true
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let chunk: AVAudioFrameCount = 32_768
        let ratio = AudioFrames.sampleRate / inFormat.sampleRate
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                               frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 4096) else {
            throw AudioCacheError.undecodable(name)
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var framesRead: AVAudioFramePosition = 0
        var framesWritten = 0
        var finished = false
        var interleaved = [Float](repeating: 0, count: Int(outBuffer.frameCapacity) * 2)

        while true {
            outBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                // `read` throws at the end of the file rather than returning
                // zero frames, so the throw is the normal way out. `length`
                // cannot gate the loop either: a file whose writer never
                // flushed its header reports 0 and still decodes.
                do {
                    try file.read(into: inBuffer, frameCount: chunk)
                } catch {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                framesRead += AVAudioFramePosition(inBuffer.frameLength)
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error {
                throw AudioCacheError.undecodable(name)
            }
            let count = Int(outBuffer.frameLength)
            if count > 0, let channels = outBuffer.floatChannelData {
                let left = channels[0], right = channels[1]
                for i in 0..<count {
                    interleaved[2 * i] = left[i]
                    interleaved[2 * i + 1] = right[i]
                }
                interleaved.withUnsafeBytes { bytes in
                    handle.write(Data(bytes: bytes.baseAddress!, count: count * 2 * MemoryLayout<Float>.size))
                }
                framesWritten += count
            }
            if status == .endOfStream || (finished && count == 0) { break }
        }
        // A throw on the very first read is an unreadable file, not an empty
        // one that happens to end immediately.
        guard framesRead > 0, framesWritten > 0 else { throw AudioCacheError.undecodable(name) }
        return framesWritten
    }
}
