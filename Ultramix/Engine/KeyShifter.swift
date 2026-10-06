//
//  KeyShifter.swift
//  Ultramix
//
//  Changes a track's key by whole semitones without changing its length:
//  every sample stays where it was, so the beatgrid, the cue points and the
//  stretcher downstream see the same file, only higher or lower. Rendered
//  once per track and shift into the audio cache (Library) and played from
//  there like any decoded track - nothing of this runs on the audio thread,
//  and the WSOLA stretcher is untouched.
//
//  The method is Signalsmith Stretch 1.3.2 (MIT, © 2022 Geraint Luff /
//  Signalsmith Audio Ltd), ported from its C++ header: a phase vocoder whose frequency
//  map moves each spectral peak to its shifted frequency and stretches the
//  bins between peaks smoothly, and whose phases are predicted both from the
//  previous block (time) and from neighbouring bins (frequency), the louder
//  channel leading and the others locked to it. That is what keeps tonal
//  material from smearing the way a plain phase vocoder smears it.
//
//  Ported is only what a pitch shift at an unchanged tempo uses. Left out:
//  the computation split across calls (a real-time concern), formant
//  correction, custom frequency maps and the tonality limit. The random phase
//  spread that the original applies beyond a 2× time stretch is kept for
//  fidelity, with a seeded generator instead of `random_device`, but a key
//  shift never reaches it - so a render is a pure function of its input.
//
//  The structure follows the original closely, names included, so the two
//  can be read side by side. One block of input is analysed every `interval`
//  output samples; `outputSeek` primes the output so the first sample out is
//  aligned with the first sample in, and `flush` folds the last block's tail
//  back in, which together make the output exactly as long as the input.
//

import Foundation

nonisolated struct ShiftComplex {
    var re: Float
    var im: Float

    static let zero = ShiftComplex(re: 0, im: 0)

    static func + (a: ShiftComplex, b: ShiftComplex) -> ShiftComplex { ShiftComplex(re: a.re + b.re, im: a.im + b.im) }
    static func - (a: ShiftComplex, b: ShiftComplex) -> ShiftComplex { ShiftComplex(re: a.re - b.re, im: a.im - b.im) }
    static func * (a: ShiftComplex, s: Float) -> ShiftComplex { ShiftComplex(re: a.re * s, im: a.im * s) }
    static func / (a: ShiftComplex, s: Float) -> ShiftComplex { ShiftComplex(re: a.re / s, im: a.im / s) }
    static func += (a: inout ShiftComplex, b: ShiftComplex) { a = a + b }

    /// a · b
    @inline(__always) static func mul(_ a: ShiftComplex, _ b: ShiftComplex) -> ShiftComplex {
        ShiftComplex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re)
    }
    /// a · conj(b)
    @inline(__always) static func mulConj(_ a: ShiftComplex, _ b: ShiftComplex) -> ShiftComplex {
        ShiftComplex(re: b.re * a.re + b.im * a.im, im: b.re * a.im - b.im * a.re)
    }
    var norm: Float { re * re + im * im }

    static func polar(_ phase: Float) -> ShiftComplex { ShiftComplex(re: cos(phase), im: sin(phase)) }
}

nonisolated final class KeyShifter {
    /// How far a clip's key may be moved, in semitones.
    static let range = -6...6

    let channels: Int
    let stft: ShiftSTFT
    var inputLatency: Int { stft.analysisLatency }
    var outputLatency: Int { stft.synthesisLatency }

    private struct Band {
        var input = ShiftComplex.zero
        var prevInput = ShiftComplex.zero
        var output = ShiftComplex.zero
        var inputEnergy: Float = 0
    }
    private struct Peak {
        var input: Float
        var output: Float
    }
    private struct PitchMapPoint {
        var inputBin: Float
        var freqGrad: Float
    }
    private struct Prediction {
        var energy: Float = 0
        var input = ShiftComplex.zero

        func makeOutput(_ phase: ShiftComplex) -> ShiftComplex {
            var phase = phase
            var phaseNorm = phase.norm
            if phaseNorm <= KeyShifter.noiseFloor {
                // The prediction is too weak to trust: fall back to the input.
                phase = input
                phaseNorm = input.norm + KeyShifter.noiseFloor
            }
            return phase * (energy / phaseNorm).squareRoot()
        }
    }

    private static let noiseFloor: Float = 1e-15
    /// Time-stretch ratio beyond which phases are spread at random.
    private static let maxCleanStretch: Float = 2

    private let bands: Int
    private var freqMultiplier: Float = 1
    private var silenceCounter = 0
    private var silenceFirst = true
    private var prevInputOffset = -1
    private var didSeek = false
    private var seekTimeFactor: Float = 1
    /// Output samples since the last block; starts high so the first sample
    /// begins one.
    private var samplesSinceLast = Int.max / 2

    // Per block.
    private var newSpectrum = false
    private var reanalysePrev = false
    private var mappedFrequencies = false
    private var timeFactor: Float = 1

    private let channelBands: UnsafeMutablePointer<Band>
    private let predictions: UnsafeMutablePointer<Prediction>
    private let energy: UnsafeMutablePointer<Float>
    private let smoothedEnergy: UnsafeMutablePointer<Float>
    private let outputMap: UnsafeMutablePointer<PitchMapPoint>
    private var peaks: [Peak] = []
    private let tmpProcess: UnsafeMutablePointer<Float>
    private let tmpProcessCapacity: Int
    private var random = SplitMix(seed: 0x5157_7265_7463_68)

    /// Signalsmith's default preset: 120 ms blocks every 30 ms.
    convenience init(channels: Int, sampleRate: Double) {
        self.init(channels: channels, blockSamples: Int(sampleRate * 0.12), interval: Int(sampleRate * 0.03))
    }

    init(channels: Int, blockSamples: Int, interval: Int) {
        self.channels = channels
        stft = ShiftSTFT(channels: channels, blockSamples: blockSamples, interval: interval,
                         extraInputHistory: interval + 1)
        stft.reset(productWeight: 0.1)
        bands = stft.bands
        channelBands = .allocate(capacity: bands * channels)
        channelBands.initialize(repeating: Band(), count: bands * channels)
        predictions = .allocate(capacity: bands * channels)
        predictions.initialize(repeating: Prediction(), count: bands * channels)
        energy = .allocate(capacity: bands)
        energy.initialize(repeating: 0, count: bands)
        smoothedEnergy = .allocate(capacity: bands)
        smoothedEnergy.initialize(repeating: 0, count: bands)
        outputMap = .allocate(capacity: bands)
        outputMap.initialize(repeating: PitchMapPoint(inputBin: 0, freqGrad: 1), count: bands)
        peaks.reserveCapacity(bands / 2)
        tmpProcessCapacity = blockSamples + interval
        tmpProcess = .allocate(capacity: tmpProcessCapacity)
        tmpProcess.initialize(repeating: 0, count: tmpProcessCapacity)
    }

    deinit {
        channelBands.deinitialize(count: bands * channels)
        channelBands.deallocate()
        predictions.deinitialize(count: bands * channels)
        predictions.deallocate()
        energy.deallocate()
        smoothedEnergy.deallocate()
        outputMap.deallocate()
        tmpProcess.deallocate()
    }

    func setTransposeSemitones(_ semitones: Float) {
        freqMultiplier = Float(pow(2.0, Double(semitones / 12)))
    }

    func reset() {
        stft.reset(productWeight: 0.1)
        prevInputOffset = -1
        channelBands.update(repeating: Band(), count: bands * channels)
        silenceCounter = 0
        didSeek = false
        samplesSinceLast = Int.max / 2
    }

    // MARK: - Rendering a whole track

    /// Frames handed to `process` at a time when rendering a file. A power
    /// of two, so the input position of each block - computed in Float as
    /// in the original - comes out exact.
    static let chunkFrames = 1 << 16

    /// Writes `source`, shifted by `semitones`, to `destination` as the
    /// audio cache's interleaved Float32. Written beside it and renamed into
    /// place, so an interrupted render leaves nothing that would map.
    static func render(_ source: AudioFrames, semitones: Int, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temporary) else {
            throw AudioCacheError.unreadable(temporary.lastPathComponent)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            defer { try? handle.close() }
            try shift(source.samples, frames: source.frameCount, channels: AudioFrames.channels,
                      semitones: semitones, sampleRate: AudioFrames.sampleRate) { block, count in
                try handle.write(contentsOf: UnsafeRawBufferPointer(start: block, count: count * MemoryLayout<Float>.size))
            }
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    /// Shifts interleaved audio and hands the result out in order, in
    /// interleaved blocks (`write(samples, sampleCount)`), exactly `frames`
    /// frames in all. Signalsmith's `exact()`, cut into chunks so a whole
    /// track never has to be held twice in memory. Throws CancellationError
    /// between chunks when the task it runs in is cancelled.
    static func shift(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, semitones: Int,
                      sampleRate: Double,
                      write: (UnsafePointer<Float>, Int) throws -> Void) throws {
        let shifter = KeyShifter(channels: channels, sampleRate: sampleRate)
        shifter.setTransposeSemitones(Float(semitones))
        let seekLength = shifter.inputLatency + shifter.outputLatency
        let chunk = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames * channels)
        defer { chunk.deallocate() }
        guard semitones != 0, frames >= seekLength else {
            // Nothing to shift, or too short for one block: the input as it is.
            try write(samples, frames * channels)
            return
        }
        shifter.outputSeek(Source(base: samples, channels: channels, offset: 0), length: seekLength)
        var done = 0
        let main = frames - seekLength
        while done < main {
            // A render nobody wants any more stops within a chunk.
            try Task.checkCancellation()
            let count = min(chunkFrames, main - done)
            shifter.process(Source(base: samples, channels: channels, offset: seekLength + done), count,
                            Sink(base: chunk, frameStride: channels, channelStride: 1, offset: 0), count)
            try write(chunk, count * channels)
            done += count
        }
        chunk.update(repeating: 0, count: seekLength * channels)
        shifter.flush(Sink(base: chunk, frameStride: channels, channelStride: 1, offset: 0), seekLength, playbackRate: 1)
        try write(chunk, seekLength * channels)
    }

    // MARK: - Input and output views

    /// Input frames from `offset` on; no base reads as silence.
    struct Source {
        var base: UnsafePointer<Float>?
        var channels: Int
        var offset: Int

        @inline(__always) func sample(_ channel: Int, _ index: Int) -> Float {
            guard let base else { return 0 }
            return base[(offset + index) * channels + channel]
        }
        func advanced(by frames: Int) -> Source { Source(base: base, channels: channels, offset: offset + frames) }
    }

    /// Output frames from `offset` on, interleaved or one channel after the
    /// other depending on the strides.
    struct Sink {
        var base: UnsafeMutablePointer<Float>
        var frameStride: Int
        var channelStride: Int
        var offset: Int

        @inline(__always) func pointer(_ channel: Int, _ index: Int) -> UnsafeMutablePointer<Float> {
            base + (offset + index) * frameStride + channel * channelStride
        }
        func advanced(by frames: Int) -> Sink {
            Sink(base: base, frameStride: frameStride, channelStride: channelStride, offset: offset + frames)
        }
    }

    // MARK: - Signalsmith Stretch, pitch only

    /// Moves the input position without producing output: copies up to one
    /// block and interval of input into the STFT's history.
    func seek(_ inputs: Source, _ inputSamples: Int, playbackRate: Double) {
        let size = tmpProcessCapacity
        tmpProcess.update(repeating: 0, count: size)
        let startIndex = max(0, inputSamples - size)
        let padStart = size + startIndex - inputSamples
        var totalEnergy: Float = 0
        for c in 0..<channels {
            for i in startIndex..<max(startIndex, inputSamples) {
                let s = inputs.sample(c, i)
                totalEnergy += s * s
                tmpProcess[i - startIndex + padStart] = s
            }
            stft.writeInput(channel: c, length: size, tmpProcess)
        }
        stft.moveInput(size)
        if totalEnergy >= Self.noiseFloor {
            silenceCounter = 0
            silenceFirst = true
        }
        didSeek = true
        seekTimeFactor = playbackRate * Double(stft.interval) > 1 ? Float(1 / playbackRate) : Float(stft.interval)
    }

    /// Resets, then uses the input beyond `inputLatency` to work out the
    /// output that would have come before the first sample, and takes it
    /// back out time-reversed - so the next `process` starts aligned with
    /// the start of the input.
    func outputSeek(_ inputs: Source, length inputLength: Int) {
        reset()
        let surplusInput = max(inputLength - inputLatency, 0)
        let playbackRate = Float(surplusInput) / Float(outputLatency)
        let seekSamples = inputLength - surplusInput
        seek(inputs, seekSamples, playbackRate: Double(playbackRate))

        let length = outputLatency
        let preRoll = UnsafeMutablePointer<Float>.allocate(capacity: length * channels)
        defer { preRoll.deallocate() }
        preRoll.initialize(repeating: 0, count: length * channels)
        process(inputs.advanced(by: seekSamples), surplusInput,
                Sink(base: preRoll, frameStride: 1, channelStride: length, offset: 0), length)
        // Put the thing down, flip it and reverse it.
        for i in 0..<(length * channels) { preRoll[i] = -preRoll[i] }
        for c in 0..<channels {
            let channel = preRoll + c * length
            var low = 0, high = length - 1
            while low < high {
                (channel[low], channel[high]) = (channel[high], channel[low])
                low += 1
                high -= 1
            }
            stft.addOutput(channel: c, length: length, channel)
        }
    }

    func process(_ inputs: Source, _ inputSamples: Int, _ outputs: Sink, _ outputSamples: Int) {
        var prevCopiedInput = 0
        func copyInput(_ toIndex: Int) {
            let length = min(tmpProcessCapacity, toIndex - prevCopiedInput)
            let offset = toIndex - length
            for c in 0..<channels {
                for i in 0..<max(0, length) { tmpProcess[i] = inputs.sample(c, i + offset) }
                stft.writeInput(channel: c, length: max(0, length), tmpProcess)
            }
            stft.moveInput(max(0, length))
            prevCopiedInput = toIndex
        }

        var totalEnergy: Float = 0
        for c in 0..<channels {
            for i in 0..<inputSamples {
                let s = inputs.sample(c, i)
                totalEnergy += s * s
            }
        }

        if totalEnergy < Self.noiseFloor {
            if silenceCounter >= 2 * stft.blockSamples {
                if silenceFirst {
                    silenceFirst = false
                    samplesSinceLast = Int.max / 2
                    for b in 0..<(bands * channels) {
                        channelBands[b].input = .zero
                        channelBands[b].prevInput = .zero
                        channelBands[b].output = .zero
                        channelBands[b].inputEnergy = 0
                    }
                }
                // Silence in, silence out - wrapping round the input if the
                // output is longer.
                for outputIndex in 0..<outputSamples {
                    for c in 0..<channels {
                        outputs.pointer(c, outputIndex).pointee =
                            inputSamples > 0 ? inputs.sample(c, outputIndex % inputSamples) : 0
                    }
                }
                copyInput(inputSamples)
                return
            } else {
                silenceCounter += inputSamples
            }
        } else {
            silenceCounter = 0
            silenceFirst = true
        }

        let interval = stft.interval
        for outputIndex in 0..<outputSamples {
            if samplesSinceLast >= interval {
                samplesSinceLast = 0
                // Time to process a spectrum! Where should it come from in the input?
                let inputOffset = Int((Float(outputIndex) * Float(inputSamples) / Float(outputSamples)).rounded())
                let inputInterval = inputOffset - prevInputOffset
                prevInputOffset = inputOffset
                copyInput(inputOffset)

                newSpectrum = didSeek || inputInterval > 0
                mappedFrequencies = freqMultiplier != 1
                if newSpectrum {
                    // Make sure the previous input is the right distance in the past.
                    reanalysePrev = didSeek || abs(inputInterval - interval) > 1
                }
                timeFactor = didSeek ? seekTimeFactor : Float(interval) / Float(max(1, inputInterval))
                didSeek = false
                processBlock()
            }
            samplesSinceLast += 1
            for c in 0..<channels {
                outputs.pointer(c, outputIndex).pointee = stft.readOutput(channel: c)
            }
            stft.moveOutput(1)
        }
        copyInput(inputSamples)
        prevInputOffset -= inputSamples
    }

    /// The remaining output, with no more input. More than one interval is
    /// computed from silence; the last interval folds the final block's
    /// tail back in so the end does not click.
    func flush(_ outputs: Sink, _ outputSamples: Int, playbackRate: Float = 0) {
        let outputBlock = max(0, outputSamples - stft.interval)
        if outputBlock > 0 {
            process(Source(base: nil, channels: channels, offset: 0), Int(Float(outputBlock) * playbackRate),
                    outputs, outputBlock)
        }
        let tailSamples = outputSamples - outputBlock
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: max(1, tailSamples))
        defer { tmp.deallocate() }
        stft.finishOutput(strength: 1)
        for c in 0..<channels {
            stft.readOutput(channel: c, length: tailSamples, into: tmp)
            for i in 0..<tailSamples { outputs.pointer(c, outputBlock + i).pointee = tmp[i] }
            stft.readOutput(channel: c, offset: tailSamples, length: tailSamples, into: tmp)
            for i in 0..<tailSamples { outputs.pointer(c, outputBlock + tailSamples - 1 - i).pointee -= tmp[i] }
        }
        stft.reset(productWeight: 0.1)
        // A fresh start for whatever comes next.
        for b in 0..<(bands * channels) {
            channelBands[b].prevInput = .zero
            channelBands[b].output = .zero
        }
    }

    // MARK: - One block

    private func processBlock() {
        let interval = stft.interval
        if newSpectrum {
            if reanalysePrev {
                for c in 0..<channels {
                    stft.analyse(channel: c, samplesInPast: interval)
                    copySpectrum(channel: c) { $0.prevInput = $1 }
                }
            }
            for c in 0..<channels {
                stft.analyse(channel: c)
                copySpectrum(channel: c) { $0.input = $1 }
            }
        }
        processSpectrum()
        for c in 0..<channels {
            let bins = channelBands + c * bands
            let real = stft.spectrumReal + c * bands, imag = stft.spectrumImag + c * bands
            for b in 0..<bands {
                real[b] = bins[b].output.re
                imag[b] = bins[b].output.im
            }
        }
        stft.synthesise()
    }

    private func copySpectrum(channel c: Int, _ assign: (inout Band, ShiftComplex) -> Void) {
        let bins = channelBands + c * bands
        let real = stft.spectrumReal + c * bands, imag = stft.spectrumImag + c * bands
        for b in 0..<bands { assign(&bins[b], ShiftComplex(re: real[b], im: imag[b])) }
    }

    private func bandToFreq(_ b: Float) -> Float { stft.binToFreq(b) }
    private func freqToBand(_ f: Float) -> Float { stft.freqToBin(f) }

    @inline(__always) private func bandInput(_ channel: Int, _ index: Int) -> ShiftComplex {
        index < 0 || index >= bands ? .zero : channelBands[index + channel * bands].input
    }
    @inline(__always) private func bandPrevInput(_ channel: Int, _ index: Int) -> ShiftComplex {
        index < 0 || index >= bands ? .zero : channelBands[index + channel * bands].prevInput
    }
    @inline(__always) private func bandEnergy(_ channel: Int, _ index: Int) -> Float {
        index < 0 || index >= bands ? 0 : channelBands[index + channel * bands].inputEnergy
    }
    /// A band's input between two bins, linearly interpolated.
    @inline(__always) private func fractionalInput(_ channel: Int, _ inputIndex: Float) -> ShiftComplex {
        let low = Int(inputIndex.rounded(.down))
        let fraction = inputIndex - Float(low)
        let a = bandInput(channel, low), b = bandInput(channel, low + 1)
        return a + (b - a) * fraction
    }

    private func processSpectrum() {
        let interval = stft.interval
        let smoothingBins = Float(stft.fftSamples) / Float(interval)
        let longVerticalStep = Int(smoothingBins.rounded())
        let timeFactor = max(self.timeFactor, 1 / Self.maxCleanStretch)
        let randomTimeFactor = timeFactor > Self.maxCleanStretch
        let randomLow = Self.maxCleanStretch * 2 * (randomTimeFactor ? 1 : 0) - timeFactor

        if newSpectrum {
            // The previous block's phases, moved on by one interval.
            for c in 0..<channels {
                let bins = channelBands + c * bands
                var rot = ShiftComplex.polar(bandToFreq(0) * Float(interval) * Float(2 * Double.pi))
                let freqStep = bandToFreq(1) - bandToFreq(0)
                let rotStep = ShiftComplex.polar(freqStep * Float(interval) * Float(2 * Double.pi))
                for b in 0..<bands {
                    bins[b].output = ShiftComplex.mul(bins[b].output, rot)
                    bins[b].prevInput = ShiftComplex.mul(bins[b].prevInput, rot)
                    rot = ShiftComplex.mul(rot, rotStep)
                }
            }
        }
        if mappedFrequencies {
            smoothEnergy(smoothingBins: smoothingBins)
            findPeaks()
            updateOutputMap()
        } else {
            for c in 0..<channels {
                let bins = channelBands + c * bands
                for b in 0..<bands { bins[b].inputEnergy = bins[b].input.norm }
            }
            for b in 0..<bands { outputMap[b] = PitchMapPoint(inputBin: Float(b), freqGrad: 1) }
        }

        // Preliminary output prediction from the phase vocoder.
        for c in 0..<channels {
            let bins = channelBands + c * bands
            let channelPredictions = predictions + c * bands
            for b in 0..<bands {
                let mapPoint = outputMap[b]
                let lowIndex = Int(mapPoint.inputBin.rounded(.down))
                let fracIndex = mapPoint.inputBin - Float(lowIndex)

                let prevEnergy = channelPredictions[b].energy
                let lowE = bandEnergy(c, lowIndex), highE = bandEnergy(c, lowIndex + 1)
                var predictionEnergy = lowE + (highE - lowE) * fracIndex
                // Scaled by the local stretch of the frequency map.
                predictionEnergy *= max(0, mapPoint.freqGrad)
                channelPredictions[b].energy = predictionEnergy
                let lowIn = bandInput(c, lowIndex), highIn = bandInput(c, lowIndex + 1)
                let predictionInput = lowIn + (highIn - lowIn) * fracIndex
                channelPredictions[b].input = predictionInput

                let lowPrev = bandPrevInput(c, lowIndex), highPrev = bandPrevInput(c, lowIndex + 1)
                let prevInput = lowPrev + (highPrev - lowPrev) * fracIndex
                let freqTwist = ShiftComplex.mulConj(predictionInput, prevInput)
                let phase = ShiftComplex.mul(bins[b].output, freqTwist)
                bins[b].output = phase / (max(prevEnergy, predictionEnergy) + Self.noiseFloor)
            }
        }

        // Re-predict using phase differences between frequencies.
        for b in 0..<bands {
            // The loudest channel leads.
            var maxChannel = 0
            var maxEnergy = predictions[b].energy
            for c in 1..<max(1, channels) {
                let e = predictions[c * bands + b].energy
                if e > maxEnergy {
                    maxChannel = c
                    maxEnergy = e
                }
            }
            let channelPredictions = predictions + maxChannel * bands
            let prediction = channelPredictions[b]
            let bins = channelBands + maxChannel * bands

            var phase = ShiftComplex.zero
            let mapPoint = outputMap[b]

            // Upwards vertical steps.
            if b > 0 {
                let binTimeFactor = randomTimeFactor ? random.uniform(randomLow, timeFactor) : timeFactor
                let downInput = fractionalInput(maxChannel, mapPoint.inputBin - binTimeFactor)
                let shortVerticalTwist = ShiftComplex.mulConj(prediction.input, downInput)
                phase += ShiftComplex.mul(bins[b - 1].output, shortVerticalTwist)

                if b >= longVerticalStep {
                    let longDownInput = fractionalInput(maxChannel, mapPoint.inputBin - Float(longVerticalStep) * binTimeFactor)
                    let longVerticalTwist = ShiftComplex.mulConj(prediction.input, longDownInput)
                    phase += ShiftComplex.mul(bins[b - longVerticalStep].output, longVerticalTwist)
                }
            }
            // Downwards vertical steps.
            if b < bands - 1 {
                let upPrediction = channelPredictions[b + 1]
                let upMapPoint = outputMap[b + 1]

                let binTimeFactor = randomTimeFactor ? random.uniform(randomLow, timeFactor) : timeFactor
                let downInput = fractionalInput(maxChannel, upMapPoint.inputBin - binTimeFactor)
                let shortVerticalTwist = ShiftComplex.mulConj(upPrediction.input, downInput)
                phase += ShiftComplex.mulConj(bins[b + 1].output, shortVerticalTwist)

                if b < bands - longVerticalStep {
                    let longUpPrediction = channelPredictions[b + longVerticalStep]
                    let longUpMapPoint = outputMap[b + longVerticalStep]
                    let longDownInput = fractionalInput(maxChannel, longUpMapPoint.inputBin - Float(longVerticalStep) * binTimeFactor)
                    let longVerticalTwist = ShiftComplex.mulConj(longUpPrediction.input, longDownInput)
                    phase += ShiftComplex.mulConj(bins[b + longVerticalStep].output, longVerticalTwist)
                }
            }

            let output = prediction.makeOutput(phase)
            bins[b].output = output

            // All other channels are locked in phase to it.
            for c in 0..<channels where c != maxChannel {
                let channelPrediction = predictions[c * bands + b]
                let channelTwist = ShiftComplex.mulConj(channelPrediction.input, prediction.input)
                let channelPhase = ShiftComplex.mul(output, channelTwist)
                channelBands[c * bands + b].output = channelPrediction.makeOutput(channelPhase)
            }
        }

        if newSpectrum {
            for i in 0..<(bands * channels) { channelBands[i].prevInput = channelBands[i].input }
        }
    }

    /// Energy summed across channels, and a copy of it smoothed across
    /// frequency: two passes down and up with a one-pole filter.
    private func smoothEnergy(smoothingBins: Float) {
        let smoothingSlew = 1 / (1 + smoothingBins * 0.5)
        for b in 0..<bands { energy[b] = 0 }
        for c in 0..<channels {
            let bins = channelBands + c * bands
            for b in 0..<bands {
                let e = bins[b].input.norm
                bins[b].inputEnergy = e // used for interpolating prediction energy
                energy[b] += e
            }
        }
        for b in 0..<bands { smoothedEnergy[b] = energy[b] }
        var e: Float = 0
        for _ in 0..<2 {
            for b in stride(from: bands - 1, through: 0, by: -1) {
                e += (smoothedEnergy[b] - e) * smoothingSlew
                smoothedEnergy[b] = e
            }
            for b in 0..<bands {
                e += (smoothedEnergy[b] - e) * smoothingSlew
                smoothedEnergy[b] = e
            }
        }
    }

    private func mapFreq(_ freq: Float) -> Float { freq * freqMultiplier }

    /// Spectral peaks: each run of bins louder than the smoothed energy,
    /// at its energy-weighted centre, and where the shift moves it.
    private func findPeaks() {
        peaks.removeAll(keepingCapacity: true)
        var start = 0
        while start < bands {
            if energy[start] > smoothedEnergy[start] {
                var end = start
                var bandSum: Float = 0, energySum: Float = 0
                while end < bands && energy[end] > smoothedEnergy[end] {
                    bandSum += Float(end) * energy[end]
                    energySum += energy[end]
                    end += 1
                }
                let avgBand = bandSum / energySum
                let avgFreq = bandToFreq(avgBand)
                peaks.append(Peak(input: avgBand, output: freqToBand(mapFreq(avgFreq))))
                start = end
            }
            start += 1
        }
    }

    /// For each output bin, the input bin it takes from: the peaks map
    /// exactly, the bins between follow a smoothstep from one peak's offset
    /// to the next, and the gradient records the local stretch.
    private func updateOutputMap() {
        guard let first = peaks.first, let last = peaks.last else {
            for b in 0..<bands { outputMap[b] = PitchMapPoint(inputBin: Float(b), freqGrad: 1) }
            return
        }
        let bottomOffset = first.input - first.output
        for b in 0..<max(0, min(bands, Int(first.output.rounded(.up)))) {
            outputMap[b] = PitchMapPoint(inputBin: Float(b) + bottomOffset, freqGrad: 1)
        }
        // Interpolate between points.
        for p in peaks.indices.dropFirst() {
            let prev = peaks[p - 1], next = peaks[p]
            let rangeScale = 1 / (next.output - prev.output)
            let outOffset = prev.input - prev.output
            let outScale = next.input - next.output - prev.input + prev.output
            let gradScale = outScale * rangeScale
            let startBin = max(0, Int(prev.output.rounded(.up)))
            let endBin = min(bands, Int(next.output.rounded(.up)))
            guard startBin < endBin else { continue }
            for b in startBin..<endBin {
                let r = (Float(b) - prev.output) * rangeScale
                let h = r * r * (3 - 2 * r)
                let outB = Float(b) + outOffset + h * outScale

                let gradH = 6 * r * (1 - r)
                let gradB = 1 + gradH * gradScale

                outputMap[b] = PitchMapPoint(inputBin: outB, freqGrad: gradB)
            }
        }
        let topOffset = last.input - last.output
        let topStart = max(0, Int(last.output))
        if topStart < bands {
            for b in topStart..<bands { outputMap[b] = PitchMapPoint(inputBin: Float(b) + topOffset, freqGrad: 1) }
        }
    }
}

/// A small seeded generator (SplitMix64), for the random phase spread.
nonisolated struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [low, high).
    mutating func uniform(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * Float(next() >> 40) / Float(1 << 24)
    }
}
