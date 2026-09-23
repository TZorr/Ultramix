//
//  Bounce.swift
//  Ultramix
//
//  The finished mix rendered to a file faster than real time - the same
//  renderer as playback, fed a plan of its own, from the first sound to the
//  last. The harness compares the two sample for sample.
//
//  The mix reaches the encoder as floating point. For WAV, quantising to 16
//  bits is the last step and is dithered (TPDF, one LSB peak each way), which
//  turns the rounding error into inaudible hiss instead of distortion that
//  follows the music into fade-outs. For MP3 the floats go straight to LAME.
//

import Foundation

nonisolated enum BounceFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case wav, mp3
    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String {
        switch self {
        case .wav: "WAV · 16-bit / 44.1 kHz"
        case .mp3: "MP3 · 320 kbps"
        }
    }
    /// A lossy codec rebuilds peaks slightly higher than the file it was
    /// given, so an MP3 needs more room below full scale.
    var recommendedCeilingDB: Double {
        switch self {
        case .wav: -0.3
        case .mp3: -1.0
        }
    }
}

nonisolated struct BounceSettings: Codable, Sendable, Equatable {
    var format: BounceFormat = .wav
    var mastering = MasteringSettings()

    init() {}

    enum CodingKeys: String, CodingKey { case format, mastering }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(BounceFormat.self, forKey: .format) ?? .wav
        mastering = try c.decodeIfPresent(MasteringSettings.self, forKey: .mastering) ?? MasteringSettings()
    }
}

nonisolated enum BounceError: Error, LocalizedError {
    case cancelled
    case empty
    case unsupported(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "The bounce was cancelled."
        case .empty: "There is nothing to bounce - the mix has no audible clips."
        case .unsupported(let what): what
        case .writeFailed(let why): "The file could not be written: \(why)"
        }
    }
}

/// Where a bounce is written, one block at a time.
nonisolated protocol BounceSink: AnyObject {
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws
    func finish() throws
}

nonisolated enum Bounce {
    static let blockFrames = 8192

    /// The frames a bounce covers: from the first clip's first sound to the
    /// end of the mix. Leading silence before the first clip is left out.
    static func range(of plan: RenderPlan) -> Range<Int> {
        let start = plan.segments.map(\.startFrame).min() ?? 0
        return start..<max(start, plan.endFrame)
    }

    /// Renders `plan` into `sink`.
    ///
    /// - Parameters:
    ///   - progress: 0…1, called once per block.
    ///   - isCancelled: polled once per block; a cancelled bounce throws
    ///     `BounceError.cancelled` without finishing the sink.
    static func render(plan: RenderPlan, laneMask: Int, mastering: MasteringSettings, into sink: BounceSink,
                       progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        let span = range(of: plan)
        guard !span.isEmpty, !plan.segments.isEmpty else { throw BounceError.empty }
        let renderer = MixRenderer()
        renderer.safetyLimiterEnabled = !mastering.enabled
        let limiter = mastering.enabled ? MasteringLimiter(mastering) : nil

        var left = [Float](repeating: 0, count: blockFrames)
        var right = [Float](repeating: 0, count: blockFrames)
        var outLeft = [Float](repeating: 0, count: blockFrames + 1024)
        var outRight = [Float](repeating: 0, count: blockFrames + 1024)
        var frame = span.lowerBound
        while frame < span.upperBound {
            if isCancelled() { throw BounceError.cancelled }
            let count = min(blockFrames, span.upperBound - frame)
            try left.withUnsafeMutableBufferPointer { l in
                try right.withUnsafeMutableBufferPointer { r in
                    renderer.render(plan: plan, laneMask: laneMask, from: frame, count: count,
                                    left: l.baseAddress!, right: r.baseAddress!)
                    if let limiter {
                        try outLeft.withUnsafeMutableBufferPointer { ol in
                            try outRight.withUnsafeMutableBufferPointer { or in
                                let produced = limiter.process(left: l.baseAddress!, right: r.baseAddress!, count: count,
                                                               outLeft: ol.baseAddress!, outRight: or.baseAddress!)
                                try sink.write(left: ol.baseAddress!, right: or.baseAddress!, count: produced)
                            }
                        }
                    } else {
                        try sink.write(left: l.baseAddress!, right: r.baseAddress!, count: count)
                    }
                }
            }
            frame += count
            progress(Double(frame - span.lowerBound) / Double(span.count))
        }
        if let limiter {
            try outLeft.withUnsafeMutableBufferPointer { ol in
                try outRight.withUnsafeMutableBufferPointer { or in
                    let produced = limiter.flush(outLeft: ol.baseAddress!, outRight: or.baseAddress!)
                    try sink.write(left: ol.baseAddress!, right: or.baseAddress!, count: produced)
                }
            }
        }
        try sink.finish()
    }

    /// Bounces to a file, through SafeWrite: a cancelled or failed bounce
    /// never leaves a truncated file under the name the user chose.
    static func run(plan: RenderPlan, laneMask: Int, settings: BounceSettings, to url: URL,
                    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        try SafeWrite.replace(url) { temporary in
            let sink: BounceSink
            switch settings.format {
            case .wav:
                sink = try WAVWriter(url: temporary)
            case .mp3:
                sink = try MP3Encoder(url: temporary)
            }
            try render(plan: plan, laneMask: laneMask, mastering: settings.mastering, into: sink,
                       progress: progress, isCancelled: isCancelled)
        }
    }
}

// MARK: - WAV

/// 16-bit stereo PCM WAV at 44.1 kHz, TPDF-dithered.
nonisolated final class WAVWriter: BounceSink {
    private let handle: FileHandle
    private var dataBytes = 0
    private var random: UInt32 = 0x9E37_79B9
    private var scratch: [Int16] = []

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw BounceError.writeFailed(url.lastPathComponent)
        }
        self.handle = handle
        // Sizes are placeholders until `finish`.
        try handle.write(contentsOf: Self.header(dataBytes: 0))
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) throws {
        guard count > 0 else { return }
        if scratch.count < count * 2 { scratch = [Int16](repeating: 0, count: count * 2) }
        for i in 0..<count {
            scratch[2 * i] = quantise(left[i])
            scratch[2 * i + 1] = quantise(right[i])
        }
        try scratch.withUnsafeBytes { bytes in
            try handle.write(contentsOf: Data(bytes: bytes.baseAddress!, count: count * 4))
        }
        dataBytes += count * 4
    }

    func finish() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try handle.close()
    }

    /// Round to 16 bits with triangular dither: the difference of two
    /// uniform values, spanning ±1 LSB. A deterministic generator, so the
    /// same mix bounces to the same bytes.
    @inline(__always)
    private func quantise(_ x: Float) -> Int16 {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5
        let a = Float(random) / 4_294_967_296
        random ^= random << 13; random ^= random >> 17; random ^= random << 5
        let b = Float(random) / 4_294_967_296
        let value = (x * 32767 + (a - b)).rounded()
        return Int16(max(-32768, min(32767, value)))
    }

    private static func header(dataBytes: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let rate = UInt32(AudioFrames.sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))            // PCM
        append(UInt16(2))            // channels
        append(rate)
        append(rate * 4)             // bytes per second
        append(UInt16(4))            // block align
        append(UInt16(16))           // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        return data
    }
}
