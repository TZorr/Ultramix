//
//  DemucsSTFT.swift
//  Ultramix
//
//  The spectrum the Demucs network reads and writes, exactly as htdemucs's
//  own `_spec` and `_ispec` make it (Demucs 4.0.1, MIT, © Meta Platforms -
//  see THIRD_PARTY_NOTICES.md). The network itself is a Core ML model that
//  starts and ends at this spectrum; Tools/convert-demucs.py cut it there.
//
//  Forward: the 343 980-frame segment is reflect-padded by 1536 on the left
//  and 1620 on the right, cut into 336 frames of 4096 samples every 1024
//  (frame t starts at t × 1024 of the padded signal), Hann-windowed
//  (periodic), transformed and scaled by 1/64 (torch's `normalized`), and the
//  Nyquist bin is dropped. torch.stft pads again to centre its frames, and
//  Demucs then throws two frames away at each end - the frames that are
//  kept never reach into that second padding, so it is not done here.
//
//  Inverse: each frame transformed back, scaled by 64, windowed and
//  overlap-added at the same places, and the segment read from 1536 on.
//  torch.istft divides by the sum of the squared windows over every frame,
//  the two empty frames Demucs adds at each end included; for a periodic
//  Hann window at a quarter of its length that sum is exactly 1.5
//  everywhere the segment is read, so it is a division by 1.5.
//
//  The layout is the network's: one channel's spectrum is `bins` rows of
//  `frames`, and a stereo spectrum is four of them - left real, left
//  imaginary, right real, right imaginary. Audio is planar: the left
//  channel's `segment` samples, then the right's.
//
//  Every buffer is allocated once; one instance is for one thread.
//

import Foundation
import Accelerate

nonisolated final class DemucsSTFT {
    static let segment = 343_980
    static let fftSize = 4096
    static let hop = 1024
    static let bins = 2048
    static let frames = 336
    static let padLeft = 1536
    static let padRight = frames * hop + padLeft - segment
    static let paddedLength = segment + padLeft + padRight
    /// One real or imaginary plane: `bins` × `frames`.
    static let planeCount = bins * frames

    private let log2n = vDSP_Length(12)
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    /// One channel, reflect-padded; on the way back, the overlap-add.
    private let padded: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>

    init() {
        precondition(Self.padRight == 1620 && Self.paddedLength == 347_136)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: Self.fftSize)
        padded = .allocate(capacity: Self.paddedLength)
        frame = .allocate(capacity: Self.fftSize)
        real = .allocate(capacity: Self.bins)
        imaginary = .allocate(capacity: Self.bins)
        // torch.hann_window is periodic: the denominator is the length.
        for n in 0..<Self.fftSize {
            window[n] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.fftSize)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        padded.deallocate()
        frame.deallocate()
        real.deallocate()
        imaginary.deallocate()
    }

    /// `audio`: planar stereo, `segment` frames. `spec`: 4 planes.
    func forward(_ audio: UnsafePointer<Float>, into spec: UnsafeMutablePointer<Float>) {
        let n = Self.segment, size = Self.fftSize
        for channel in 0..<2 {
            let x = audio + channel * n
            (padded + Self.padLeft).update(from: x, count: n)
            for i in 0..<Self.padLeft { padded[i] = x[Self.padLeft - i] }
            for i in 0..<Self.padRight { padded[Self.padLeft + n + i] = x[n - 2 - i] }

            let realPlane = spec + 2 * channel * Self.planeCount
            let imaginaryPlane = realPlane + Self.planeCount
            var split = DSPSplitComplex(realp: real, imagp: imaginary)
            // zrip gives twice the DFT; normalised, torch divides by 64.
            var scale = Float(1) / 128
            for t in 0..<Self.frames {
                vDSP_vmul(padded + t * Self.hop, 1, window, 1, frame, 1, vDSP_Length(size))
                frame.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // zrip packs the Nyquist bin, which Demucs drops, into
                // imag[0]; the DC bin's imaginary part is zero.
                imaginary[0] = 0
                vDSP_vsmul(real, 1, &scale, realPlane + t, Self.frames, vDSP_Length(Self.bins))
                vDSP_vsmul(imaginary, 1, &scale, imaginaryPlane + t, Self.frames, vDSP_Length(Self.bins))
            }
        }
    }

    /// `spec`: 4 planes. `audio`: planar stereo, `segment` frames.
    func inverse(_ spec: UnsafePointer<Float>, into audio: UnsafeMutablePointer<Float>) {
        let n = Self.segment, size = Self.fftSize
        for channel in 0..<2 {
            let realPlane = spec + 2 * channel * Self.planeCount
            let imaginaryPlane = realPlane + Self.planeCount
            padded.initialize(repeating: 0, count: Self.paddedLength)
            var split = DSPSplitComplex(realp: real, imagp: imaginary)
            // The inverse zrip of a DFT gives `size` times the signal; times
            // 64 to undo the normalisation: 64 / 4096.
            var scale = Float(1) / 64
            for t in 0..<Self.frames {
                vDSP_vsmul(realPlane + t, Self.frames, &scale, real, 1, vDSP_Length(Self.bins))
                vDSP_vsmul(imaginaryPlane + t, Self.frames, &scale, imaginary, 1, vDSP_Length(Self.bins))
                // imag[0] is where zrip wants the Nyquist bin: zero. The DC
                // bin's imaginary part is ignored, as irfft ignores it.
                imaginary[0] = 0
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                frame.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                    vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(size / 2))
                }
                let at = padded + t * Self.hop
                vDSP_vma(frame, 1, window, 1, at, 1, at, 1, vDSP_Length(size))
            }
            var envelope = Float(1) / 1.5
            vDSP_vsmul(padded + Self.padLeft, 1, &envelope, audio + channel * n, 1, vDSP_Length(n))
        }
    }
}
