//
//  ModifiedRealFFT.swift
//  Ultramix
//
//  The FFT under the key shifter (KeyShifter.swift): a real FFT whose bins
//  sit half a bin up, at (k + ½)/N of the sample rate, k = 0 … N/2 − 1.
//
//      X[k] = Σ x[n] · e^(−2πi·n·(k + ½)/N)
//
//  Shifted bins have no DC and no Nyquist bin, so a real signal's N/2 bins
//  are all ordinary complex numbers and none needs the packing a plain real
//  FFT does - the phase vocoder treats every bin the same.
//
//  Computed as a complex FFT of half the length: even and odd samples become
//  the real and imaginary parts, each sample turned by e^(−2πi·m/N) first,
//  and the two halves of the result separated with one twiddle pass. That is
//  Signalsmith Linear's `RealFFT<…, halfBinShift = true>` (MIT, © 2025
//  Signalsmith Audio), ported with vDSP's DFT in place of its own split FFT.
//  vDSP takes lengths of 1, 3, 5 or 15 times a power of two, which covers
//  every size `fastSize(above:)` picks.
//
//  Unscaled both ways, as Linear is: inverse(forward(x)) = N · x. The STFT
//  divides that back out together with its window sums.
//

import Foundation
import Accelerate

nonisolated final class ModifiedRealFFT {
    let size: Int
    /// N/2: the bin count, and the length of the inner complex FFT.
    var binCount: Int { size / 2 }

    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    /// e^(−2πi·m/N), turning the samples before the forward FFT.
    private let twistReal: UnsafeMutablePointer<Float>
    private let twistImag: UnsafeMutablePointer<Float>
    /// e^(i·((k + ½)·(−2π/N) − π/2)), separating the even and odd halves.
    private let twiddleReal: UnsafeMutablePointer<Float>
    private let twiddleImag: UnsafeMutablePointer<Float>
    private let timeReal: UnsafeMutablePointer<Float>
    private let timeImag: UnsafeMutablePointer<Float>
    private let freqReal: UnsafeMutablePointer<Float>
    private let freqImag: UnsafeMutablePointer<Float>

    /// The smallest size at or above `size` that the FFT runs fast at: up to
    /// 8 times a power of two (never 7), i.e. 1, 3 or 5 times one. Linear's
    /// `SplitFFT::fastSizeAbove`, so the STFT has the same block as the original.
    static func fastComplexSize(above size: Int) -> Int {
        var pow2 = 1
        while pow2 < 16 && pow2 < size { pow2 *= 2 }
        while pow2 * 8 < size { pow2 *= 2 }
        var multiple = (size + pow2 - 1) / pow2
        if multiple == 7 { multiple += 1 }
        return multiple * pow2
    }

    /// The real FFT size Linear's `RealFFT::fastSizeAbove` picks.
    static func fastSize(above size: Int) -> Int {
        fastComplexSize(above: (size + 1) / 2) * 2
    }

    init(size: Int) {
        precondition(size >= 32 && size % 4 == 0, "size must be a multiple of 4")
        self.size = size
        let half = size / 2
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(half), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(half), .INVERSE) else {
            preconditionFailure("vDSP has no DFT of length \(half)")
        }
        forwardSetup = forward
        inverseSetup = inverse
        twistReal = .allocate(capacity: half)
        twistImag = .allocate(capacity: half)
        twiddleReal = .allocate(capacity: half / 2)
        twiddleImag = .allocate(capacity: half / 2)
        timeReal = .allocate(capacity: half)
        timeImag = .allocate(capacity: half)
        freqReal = .allocate(capacity: half)
        freqImag = .allocate(capacity: half)
        for m in 0..<half {
            let phase = -2 * Double.pi * Double(m) / Double(size)
            twistReal[m] = Float(cos(phase))
            twistImag[m] = Float(sin(phase))
        }
        for k in 0..<half / 2 {
            let phase = (Double(k) + 0.5) * (-2 * Double.pi / Double(size)) - Double.pi / 2
            twiddleReal[k] = Float(cos(phase))
            twiddleImag[k] = Float(sin(phase))
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
        for buffer in [twistReal, twistImag, twiddleReal, twiddleImag, timeReal, timeImag, freqReal, freqImag] {
            buffer.deallocate()
        }
    }

    /// `size` real samples in, `binCount` bins out.
    func forward(_ time: UnsafePointer<Float>, real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        let half = binCount
        for m in 0..<half {
            let tr = time[2 * m], ti = time[2 * m + 1]
            let wr = twistReal[m], wi = twistImag[m]
            timeReal[m] = tr * wr - ti * wi
            timeImag[m] = ti * wr + tr * wi
        }
        vDSP_DFT_Execute(forwardSetup, timeReal, timeImag, freqReal, freqImag)
        for k in 0..<half / 2 {
            let c = half - 1 - k
            let oddR = (freqReal[k] + freqReal[c]) * 0.5
            let oddI = (freqImag[k] - freqImag[c]) * 0.5
            let evenR = (freqReal[k] - freqReal[c]) * 0.5
            let evenI = (freqImag[k] + freqImag[c]) * 0.5
            let tr = twiddleReal[k], ti = twiddleImag[k]
            let rotR = evenR * tr - evenI * ti
            let rotI = evenI * tr + evenR * ti
            real[k] = oddR + rotR
            imag[k] = oddI + rotI
            real[c] = oddR - rotR
            imag[c] = rotI - oddI
        }
    }

    /// `binCount` bins in, `size` real samples out, scaled by `size`.
    func inverse(real: UnsafePointer<Float>, imag: UnsafePointer<Float>, _ time: UnsafeMutablePointer<Float>) {
        let half = binCount
        for k in 0..<half / 2 {
            let c = half - 1 - k
            let oddR = real[k] + real[c]
            let oddI = imag[k] - imag[c]
            let rotR = real[k] - real[c]
            let rotI = imag[k] + imag[c]
            let tr = twiddleReal[k], ti = twiddleImag[k]
            let evenR = rotR * tr + rotI * ti
            let evenI = rotI * tr - rotR * ti
            freqReal[k] = oddR + evenR
            freqImag[k] = oddI + evenI
            freqReal[c] = oddR - evenR
            freqImag[c] = evenI - oddI
        }
        vDSP_DFT_Execute(inverseSetup, freqReal, freqImag, timeReal, timeImag)
        for m in 0..<half {
            let tr = timeReal[m], ti = timeImag[m]
            let wr = twistReal[m], wi = twistImag[m]
            time[2 * m] = tr * wr + ti * wi
            time[2 * m + 1] = ti * wr - tr * wi
        }
    }
}
