//
//  DemucsModel.swift
//  Ultramix
//
//  The htdemucs network (Demucs v4) as the stem separator calls it: one 7.8 s
//  segment in - its audio and its spectrum, each normalised - and drums, bass
//  and vocals out, as a time-domain part and a spectrum to be transformed
//  back (DemucsSTFT) and added to it. Third-party model - see
//  THIRD_PARTY_NOTICES.md; Tools/convert-demucs.py made it and says what
//  was cut where.
//
//  It runs on the CPU and GPU only. The Neural Engine computes in half
//  precision whatever the model asks for, and the network's group norms
//  overflow there; the result is noise.
//
//  Not kept between runs, unlike Beat This!: it holds about 90 MB of weights
//  and the GPU's working memory, and stems are separated now and then.
//
//  Shipped compiled (Xcode turns the .mlpackage into a .mlmodelc), so nothing
//  is compiled at run time or written outside the bundle.
//

import Foundation
import CoreML

nonisolated final class DemucsModel: @unchecked Sendable {
    /// The stems the network gives, in this order. "Other" is the mix less
    /// these three.
    static let stems = 3
    static let segment = DemucsSTFT.segment
    static let audioCount = 2 * segment
    static let specCount = 4 * DemucsSTFT.planeCount
    static let timeCount = stems * audioCount
    static let freqCount = stems * specCount

    nonisolated enum Failure: Error, LocalizedError {
        case missing
        case unusable(String)

        var errorDescription: String? {
            switch self {
            case .missing: "The Demucs model is missing from the app."
            case .unusable(let reason): "The Demucs model could not be used: \(reason)"
            }
        }
    }

    private let model: MLModel
    private let lock = NSLock()

    init(compiledURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw Failure.unusable(error.localizedDescription)
        }
    }

    /// The model in the app bundle, loaded anew for each run.
    static func bundled() throws -> DemucsModel {
        guard let url = Bundle.main.url(forResource: "Demucs_htdemucs", withExtension: "mlmodelc") else {
            throw Failure.missing
        }
        return try DemucsModel(compiledURL: url)
    }

    /// Normalises `count` values in place as HTDemucs.forward does - minus
    /// the mean, over 1e-5 plus the (unbiased) standard deviation - and
    /// returns the two, which undo it on the network's output.
    static func normalise(_ values: UnsafeMutablePointer<Float>, count: Int) -> (mean: Double, std: Double) {
        var sum = 0.0
        for i in 0..<count { sum += Double(values[i]) }
        let mean = sum / Double(count)
        var squares = 0.0
        for i in 0..<count {
            let d = Double(values[i]) - mean
            squares += d * d
        }
        let std = (squares / Double(count - 1)).squareRoot()
        let scale = 1 / (1e-5 + std)
        for i in 0..<count { values[i] = Float((Double(values[i]) - mean) * scale) }
        return (mean, std)
    }

    /// One segment through the network. `audio` (planar stereo) and `spec`
    /// (DemucsSTFT's four planes) are normalised; `time` gets the three stems'
    /// planar stereo audio, `freq` their four planes each - both still in the
    /// normalised scale of their input.
    func predict(audio: UnsafeMutablePointer<Float>, spec: UnsafeMutablePointer<Float>,
                 time: UnsafeMutablePointer<Float>, freq: UnsafeMutablePointer<Float>) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            let bins = DemucsSTFT.bins, frames = DemucsSTFT.frames, l = Self.segment
            let inputs = try MLDictionaryFeatureProvider(dictionary: [
                "mix": try Self.wrap(audio, shape: [1, 2, l]),
                "spec": try Self.wrap(spec, shape: [1, 4, bins, frames]),
            ])
            let timeArray = try Self.wrap(time, shape: [1, Self.stems, 2, l])
            let freqArray = try Self.wrap(freq, shape: [1, 4 * Self.stems, bins, frames])
            // Core ML writes straight into these when it can; when it would
            // rather pad the rows, it hands back its own arrays instead.
            let options = MLPredictionOptions()
            options.outputBackings = ["time": timeArray, "freq": freqArray]
            let output = try model.prediction(from: inputs, options: options)
            guard let timeOut = output.featureValue(for: "time")?.multiArrayValue,
                  let freqOut = output.featureValue(for: "freq")?.multiArrayValue else {
                throw Failure.unusable("it gave no time or frequency output.")
            }
            try Self.copy(timeOut, into: time, count: Self.timeCount)
            try Self.copy(freqOut, into: freq, count: Self.freqCount)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unusable(error.localizedDescription)
        }
    }

    private static func wrap(_ pointer: UnsafeMutablePointer<Float>, shape: [Int]) throws -> MLMultiArray {
        var strides = [Int](repeating: 1, count: shape.count)
        for i in stride(from: shape.count - 2, through: 0, by: -1) { strides[i] = strides[i + 1] * shape[i + 1] }
        return try MLMultiArray(dataPointer: pointer, shape: shape.map { NSNumber(value: $0) }, dataType: .float32,
                                strides: strides.map { NSNumber(value: $0) })
    }

    /// `array` into `destination`, contiguous; nothing to do when Core ML
    /// used the backing.
    private static func copy(_ array: MLMultiArray, into destination: UnsafeMutablePointer<Float>, count: Int) throws {
        guard array.count == count else { throw Failure.unusable("an output has \(array.count) values, not \(count).") }
        let backed = array.withUnsafeBytes { $0.baseAddress == UnsafeRawPointer(destination) }
        if array.dataType == .float32 && backed { return }
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let rank = shape.count, row = shape[rank - 1], rows = count / row
        func each(_ body: (_ source: Int, _ target: Int) -> Void) {
            for r in 0..<rows {
                var rest = r, source = 0
                for d in stride(from: rank - 2, through: 0, by: -1) {
                    source += (rest % shape[d]) * strides[d]
                    rest /= shape[d]
                }
                body(source, r * row)
            }
        }
        let step = strides[rank - 1]
        // The bytes, not a typed buffer: with padded rows the storage is
        // longer than `count`.
        switch array.dataType {
        case .float32:
            array.withUnsafeBytes { raw in
                let values = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                each { source, target in for i in 0..<row { destination[target + i] = values[source + i * step] } }
            }
        case .float16:
            array.withUnsafeBytes { raw in
                let values = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                each { source, target in for i in 0..<row { destination[target + i] = Float(values[source + i * step]) } }
            }
        default:
            throw Failure.unusable("an output is neither float32 nor float16.")
        }
    }
}
