//
//  RealFFT.swift
//  Ultramix
//
//  A windowed magnitude spectrum of a real signal, on vDSP, with every buffer
//  allocated once - the tempo analyser takes tens of thousands per track.
//

import Foundation
import Accelerate

nonisolated final class RealFFT {
    let size: Int
    /// Bins 0 ..< size/2 (DC up to one below Nyquist).
    var binCount: Int { size / 2 }

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>

    init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "size must be a power of two")
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: size)
        frame = .allocate(capacity: size)
        real = .allocate(capacity: size / 2)
        imaginary = .allocate(capacity: size / 2)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        frame.deallocate()
        real.deallocate()
        imaginary.deallocate()
    }

    /// Writes `binCount` magnitudes of the Hann-windowed `size` samples at
    /// `input` into `magnitudes`, scaled so a full-scale sine peaks near 1.
    func magnitudes(of input: UnsafePointer<Float>, into magnitudes: UnsafeMutablePointer<Float>) {
        vDSP_vmul(input, 1, window, 1, frame, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        // zrip packs the Nyquist bin into imag[0]; bin 0 is DC alone.
        imaginary[0] = 0
        vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(size / 2))
        // zrip returns twice the true DFT; the Hann window halves a sine's
        // peak again. 4/size brings a full-scale sine back to about 1.
        var scale = Float(4) / Float(size)
        vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(size / 2))
    }
}
