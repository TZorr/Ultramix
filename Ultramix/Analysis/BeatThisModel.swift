//
//  BeatThisModel.swift
//  Ultramix
//
//  The Beat This! network (small0) as the analyser calls it: 1500 frames of
//  log-mel spectrum in, a beat and a downbeat logit per frame out. Third-party
//  model - see THIRD_PARTY_NOTICES.md.
//
//  Shipped compiled (Xcode turns the .mlpackage into a .mlmodelc), so nothing
//  is compiled at run time or written outside the bundle.
//

import Foundation
import CoreML

nonisolated final class BeatThisModel: @unchecked Sendable {
    static let frames = 1500
    static let bands = 128

    nonisolated enum Failure: Error, LocalizedError {
        case missing
        case unusable(String)

        var errorDescription: String? {
            switch self {
            case .missing: "The Beat This! model is missing from the app."
            case .unusable(let reason): "The Beat This! model could not be used: \(reason)"
            }
        }
    }

    private let model: MLModel
    /// Two library workers analyse at once; one prediction at a time keeps
    /// Core ML from holding two sets of activations for nothing.
    private let lock = NSLock()

    init(compiledURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw Failure.unusable(error.localizedDescription)
        }
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedModel: BeatThisModel?

    /// The model in the app bundle, loaded on first use and kept.
    static func bundled() throws -> BeatThisModel {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let sharedModel { return sharedModel }
        guard let url = Bundle.main.url(forResource: "BeatThis_small0", withExtension: "mlmodelc") else {
            throw Failure.missing
        }
        let loaded = try BeatThisModel(compiledURL: url)
        sharedModel = loaded
        return loaded
    }

    /// Beat and downbeat logits for one chunk of `frames` × `bands` values,
    /// frame-major.
    func predict(_ chunk: [Float]) throws -> (beat: [Float], downbeat: [Float]) {
        precondition(chunk.count == Self.frames * Self.bands)
        lock.lock()
        defer { lock.unlock() }
        do {
            let input = try MLMultiArray(shape: [1, NSNumber(value: Self.frames), NSNumber(value: Self.bands)],
                                         dataType: .float32)
            input.withUnsafeMutableBytes { raw, strides in
                // Contiguous and frame-major: strides are [frames·bands, bands, 1].
                precondition(strides == [Self.frames * Self.bands, Self.bands, 1])
                chunk.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            let features = try MLDictionaryFeatureProvider(dictionary: ["mel_spectrogram": input])
            let output = try model.prediction(from: features)
            guard let beat = output.featureValue(for: "beat_logits")?.multiArrayValue,
                  let downbeat = output.featureValue(for: "downbeat_logits")?.multiArrayValue else {
                throw Failure.unusable("it gave no beat or downbeat output.")
            }
            return (Self.values(beat), Self.values(downbeat))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unusable(error.localizedDescription)
        }
    }

    private static func values(_ array: MLMultiArray) -> [Float] {
        let count = min(array.count, frames)
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(count)) }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.prefix(count).map { Float($0) } }
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }
}
