//
//  ShiftSTFT.swift
//  Ultramix
//
//  The short-time Fourier transform the key shifter works in: input goes into
//  a ring buffer, a windowed block of it becomes a spectrum (`analyse`), a
//  spectrum becomes a windowed block that is overlap-added into the output
//  ring (`synthesise`), and the output is read a sample at a time.
//
//  Self-normalising: every synthesis also adds its analysis × synthesis
//  window product into `windowProducts`, and output is read divided by that
//  sum. So the output is right whatever the spacing of the blocks, and the
//  window needs no constant-overlap property of its own.
//
//  A port of Signalsmith Linear's `DynamicSTFT<float, false, MODIFIED>` (MIT,
//  © 2025 Signalsmith Audio), cut down to what Signalsmith
//  Stretch calls: half-bin-shifted spectra (ModifiedRealFFT), one Kaiser
//  window for analysis and synthesis, made to reconstruct exactly, and round-
//  trip normalisation. Because the bins sit half a bin up, rotating the block
//  so its window peak lands on sample 0 turns the wrapped part over: that part
//  of the window is negated, in both directions.
//

import Foundation

nonisolated final class ShiftSTFT {
    let channels: Int
    let blockSamples: Int
    let fftSamples: Int
    let interval: Int
    var bands: Int { fftSamples / 2 }

    /// Where in the block the window peaks; a block is placed by this sample.
    private(set) var analysisOffset = 0
    private(set) var synthesisOffset = 0
    /// How far ahead of the processing position input has to be supplied,
    /// and how far behind it output comes out.
    var analysisLatency: Int { blockSamples - analysisOffset }
    var synthesisLatency: Int { synthesisOffset }

    private let fft: ModifiedRealFFT
    private let inputLength: Int
    private var inputPos = 0
    private var outputPos = 0
    /// `inputLength` per channel.
    private let input: UnsafeMutablePointer<Float>
    /// `blockSamples` per channel.
    private let output: UnsafeMutablePointer<Float>
    private let windowProducts: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>
    private let timeBuffer: UnsafeMutablePointer<Float>
    /// `bands` per channel. Public so the shifter can read and write the
    /// spectra in place.
    let spectrumReal: UnsafeMutablePointer<Float>
    let spectrumImag: UnsafeMutablePointer<Float>

    private static let almostZero: Float = 1e-30

    /// - Parameter extraInputHistory: input kept beyond one block, so a block
    ///   that far in the past can still be analysed.
    init(channels: Int, blockSamples: Int, interval: Int, extraInputHistory: Int) {
        self.channels = channels
        self.blockSamples = blockSamples
        self.interval = interval
        fftSamples = ModifiedRealFFT.fastSize(above: (blockSamples + 1) / 2) * 2
        fft = ModifiedRealFFT(size: fftSamples)
        inputLength = blockSamples + extraInputHistory
        input = .allocate(capacity: inputLength * channels)
        output = .allocate(capacity: blockSamples * channels)
        windowProducts = .allocate(capacity: blockSamples)
        window = .allocate(capacity: blockSamples)
        timeBuffer = .allocate(capacity: max(fftSamples, blockSamples))
        spectrumReal = .allocate(capacity: fftSamples / 2 * channels)
        spectrumImag = .allocate(capacity: fftSamples / 2 * channels)
        spectrumReal.initialize(repeating: 0, count: fftSamples / 2 * channels)
        spectrumImag.initialize(repeating: 0, count: fftSamples / 2 * channels)
        makeWindow()
        reset()
    }

    deinit {
        for buffer in [input, output, windowProducts, window, timeBuffer, spectrumReal, spectrumImag] {
            buffer.deallocate()
        }
    }

    func binToFreq(_ bin: Float) -> Float { (bin + 0.5) / Float(fftSamples) }
    func freqToBin(_ freq: Float) -> Float { freq * Float(fftSamples) - 0.5 }

    /// Clears input and output. `productWeight` scales the window sums the
    /// output starts with: below 1, the first blocks come out at full level
    /// although fewer blocks overlap them.
    func reset(productWeight: Float = 1) {
        inputPos = blockSamples % inputLength
        outputPos = 0
        input.update(repeating: 0, count: inputLength * channels)
        output.update(repeating: 0, count: blockSamples * channels)
        spectrumReal.update(repeating: 0, count: bands * channels)
        spectrumImag.update(repeating: 0, count: bands * channels)
        windowProducts.update(repeating: 0, count: blockSamples)
        addWindowProduct()
        var i = blockSamples - interval - 1
        while i >= 0 {
            windowProducts[i] += windowProducts[i + interval]
            i -= 1
        }
        for i in 0..<blockSamples { windowProducts[i] = windowProducts[i] * productWeight + Self.almostZero }
        moveOutput(interval)
    }

    // MARK: - Input

    func writeInput(channel: Int, length: Int, _ samples: UnsafePointer<Float>) {
        let buffer = input + channel * inputLength
        var pos = inputPos
        for i in 0..<length {
            buffer[pos] = samples[i]
            pos += 1
            if pos == inputLength { pos = 0 }
        }
    }

    func moveInput(_ samples: Int) {
        inputPos = (inputPos + samples) % inputLength
    }

    // MARK: - Output

    /// `length` samples from `offset` past the read position, divided by the
    /// window sums.
    func readOutput(channel: Int, offset: Int = 0, length: Int, into samples: UnsafeMutablePointer<Float>) {
        let buffer = output + channel * blockSamples
        var pos = (outputPos + offset) % blockSamples
        for i in 0..<length {
            samples[i] = buffer[pos] / windowProducts[pos]
            pos += 1
            if pos == blockSamples { pos = 0 }
        }
    }

    /// One sample at the read position - the shifter's hot path.
    func readOutput(channel: Int) -> Float {
        output[channel * blockSamples + outputPos] / windowProducts[outputPos]
    }

    func addOutput(channel: Int, length: Int, _ samples: UnsafePointer<Float>) {
        let buffer = output + channel * blockSamples
        var pos = outputPos
        for i in 0..<min(blockSamples, length) {
            buffer[pos] += samples[i] * windowProducts[pos]
            pos += 1
            if pos == blockSamples { pos = 0 }
        }
    }

    /// Advances the read position, clearing what it passes for the blocks
    /// still to come.
    func moveOutput(_ samples: Int) {
        var pos = outputPos
        for _ in 0..<samples {
            for c in 0..<channels { output[c * blockSamples + pos] = 0 }
            windowProducts[pos] = Self.almostZero
            pos += 1
            if pos == blockSamples { pos = 0 }
        }
        outputPos = pos
    }

    /// No more blocks are coming: the window sums are held at their running
    /// maximum from here on, so the output tapers away with the last windows
    /// instead of being divided up by sums that shrink to nothing.
    func finishOutput(strength: Float = 1) {
        var maxProduct: Float = 0
        var pos = outputPos
        for _ in 0..<blockSamples {
            maxProduct = max(windowProducts[pos], maxProduct)
            windowProducts[pos] += (maxProduct - windowProducts[pos]) * strength
            pos += 1
            if pos == blockSamples { pos = 0 }
        }
    }

    // MARK: - Transforms

    /// The spectrum of the block ending `samplesInPast` before the input
    /// position, into this channel's spectrum.
    func analyse(channel: Int, samplesInPast: Int = 0) {
        let buffer = input + channel * inputLength
        var pos = (inputLength * 2 + inputPos - blockSamples - samplesInPast) % inputLength
        let wrapped = fftSamples - analysisOffset
        for i in 0..<blockSamples {
            let sample = buffer[pos]
            if i < analysisOffset {
                timeBuffer[i + wrapped] = sample * -window[i]
            } else {
                timeBuffer[i - analysisOffset] = sample * window[i]
            }
            pos += 1
            if pos == inputLength { pos = 0 }
        }
        for i in (blockSamples - analysisOffset)..<wrapped { timeBuffer[i] = 0 }
        fft.forward(timeBuffer, real: spectrumReal + channel * bands, imag: spectrumImag + channel * bands)
    }

    /// Turns every channel's spectrum back into a block and adds it in at the
    /// read position, with its window product.
    func synthesise() {
        addWindowProduct()
        let wrapped = fftSamples - synthesisOffset
        for channel in 0..<channels {
            fft.inverse(real: spectrumReal + channel * bands, imag: spectrumImag + channel * bands, timeBuffer)
            let buffer = output + channel * blockSamples
            var pos = outputPos
            for i in 0..<blockSamples {
                if i < synthesisOffset {
                    buffer[pos] += timeBuffer[i + wrapped] * -window[i]
                } else {
                    buffer[pos] += timeBuffer[i - synthesisOffset] * window[i]
                }
                pos += 1
                if pos == blockSamples { pos = 0 }
            }
        }
    }

    private func addWindowProduct() {
        let scaling = Float(fftSamples)
        var pos = outputPos
        for i in 0..<blockSamples {
            windowProducts[pos] += window[i] * window[i] * scaling
            pos += 1
            if pos == blockSamples { pos = 0 }
        }
    }

    // MARK: - Window

    /// Kaiser, its bandwidth from how many blocks overlap, then scaled so
    /// the squares of every `interval`-th sample sum to one: analysis times
    /// synthesis then reconstructs exactly at the default spacing.
    private func makeWindow() {
        let beta = Self.kaiserBeta(bandwidth: Double(blockSamples) / Double(interval))
        let invB0 = 1 / Self.bessel0(beta)
        let size = blockSamples
        let offsetI = size & 1 == 1 ? 1 : 0
        for i in 0..<size {
            let r = Double(2 * i + offsetI) / Double(size) - 1
            window[i] = Float(Self.bessel0(beta * (1 - r * r).squareRoot()) * invB0)
        }
        for i in 0..<interval {
            var sum2 = 0.0
            var index = i
            while index < size {
                sum2 += Double(window[index] * window[index])
                index += interval
            }
            let factor = 1 / sum2.squareRoot()
            index = i
            while index < size {
                window[index] = Float(Double(window[index]) * factor)
                index += interval
            }
        }
        analysisOffset = size / 2
        for i in 0..<size where window[i] > window[analysisOffset] { analysisOffset = i }
        synthesisOffset = analysisOffset
    }

    private static func bessel0(_ x: Double) -> Double {
        var result = 0.0, term = 1.0, m = 0.0
        while term > 1e-4 {
            result += term
            m += 1
            term *= (x * x) / (4 * m * m)
        }
        return result
    }

    /// Linear's heuristic-optimal Kaiser β for a window `bandwidth` bins wide.
    private static func kaiserBeta(bandwidth: Double) -> Double {
        var b = bandwidth + 8 / ((bandwidth + 3) * (bandwidth + 3)) + 0.25 * max(3 - bandwidth, 0)
        b = max(b, 2)
        return (b * b * 0.25 - 1).squareRoot() * Double.pi
    }
}
