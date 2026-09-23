//
//  MasteringLimiter.swift
//  Ultramix
//
//  The brickwall on the bounce: it raises the mix by threshold minus ceiling,
//  then guarantees no sample leaves above the ceiling without clipping one.
//
//  It can promise that because it looks ahead by `latency` frames (3 ms). Per
//  sample the required gain is ceiling / peak; the limiter takes the smallest
//  requirement in the look-ahead window and averages it over the same window.
//  The minimum alone would drop the gain in one step - a click; averaging
//  makes it a 3 ms ramp. Because every averaged value is a minimum over a
//  window containing the sample about to leave, the average can never exceed
//  what that sample requires: the ceiling holds by construction.
//
//  Release is programme-dependent when `autoRelease` is on - quick after a
//  lone peak, slow through a dense passage.
//

import Foundation

nonisolated struct MasteringSettings: Codable, Sendable, Equatable {
    var enabled = true
    /// Where limiting starts, relative to full scale, before the make-up
    /// gain. Lowering it raises the whole mix.
    var thresholdDB = -3.0
    /// The highest sample level the bounce may contain.
    var ceilingDB = -0.3
    var autoRelease = true
    var releaseMilliseconds = 200.0

    /// Everything below the threshold comes up by this much.
    var makeupDB: Double { max(0, ceilingDB - thresholdDB) }

    init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, thresholdDB, ceilingDB, autoRelease, releaseMilliseconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MasteringSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        thresholdDB = try c.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? defaults.thresholdDB
        ceilingDB = try c.decodeIfPresent(Double.self, forKey: .ceilingDB) ?? defaults.ceilingDB
        autoRelease = try c.decodeIfPresent(Bool.self, forKey: .autoRelease) ?? defaults.autoRelease
        releaseMilliseconds = try c.decodeIfPresent(Double.self, forKey: .releaseMilliseconds) ?? defaults.releaseMilliseconds
    }
}

nonisolated final class MasteringLimiter {
    /// Look-ahead, and therefore delay, in frames.
    let latency: Int

    private let ceiling: Float
    private let makeup: Float
    private let fastRelease: Float
    private let slowRelease: Float
    private let fixedRelease: Float
    private let depthFollow: Float
    private let autoRelease: Bool

    // Delay line, one per channel.
    private var delayLeft: [Float]
    private var delayRight: [Float]
    private var delayIndex = 0

    // Sliding minimum of the required gain: a monotonic queue in a ring.
    private var queueValues: [Float]
    private var queueFrames: [Int]
    private var queueHead = 0
    private var queueCount = 0

    // Running average of the sliding minimum over the same window.
    private var boxValues: [Float]
    private var boxSum: Double
    private var boxIndex = 0

    private var gain: Float = 1
    private var depth: Float = 0
    private var frame = 0
    private var primed = 0

    init(_ settings: MasteringSettings, sampleRate: Double = AudioFrames.sampleRate) {
        latency = max(1, Int((0.003 * sampleRate).rounded()))
        ceiling = Float(pow(10, settings.ceilingDB / 20))
        makeup = Float(pow(10, settings.makeupDB / 20))
        func coefficient(_ seconds: Double) -> Float { Float(1 - exp(-1 / (seconds * sampleRate))) }
        fastRelease = coefficient(0.060)
        slowRelease = coefficient(0.600)
        fixedRelease = coefficient(max(0.001, settings.releaseMilliseconds / 1000))
        depthFollow = coefficient(0.300)
        autoRelease = settings.autoRelease

        let window = latency + 1
        delayLeft = [Float](repeating: 0, count: latency)
        delayRight = [Float](repeating: 0, count: latency)
        queueValues = [Float](repeating: 1, count: window + 1)
        queueFrames = [Int](repeating: 0, count: window + 1)
        boxValues = [Float](repeating: 1, count: window)
        boxSum = Double(window)
    }

    /// Processes `count` input frames and writes the frames that come out -
    /// `count` of them once the look-ahead is primed, fewer at the start.
    /// Returns how many were written.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int,
                 outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) -> Int {
        var produced = 0
        let window = latency + 1
        let capacity = queueValues.count
        for i in 0..<count {
            let l = left[i] * makeup
            let r = right[i] * makeup
            let peak = max(abs(l), abs(r))
            let required: Float = peak > ceiling ? ceiling / peak : 1

            // Sliding minimum over the last `window` requirements.
            while queueCount > 0 {
                let back = (queueHead + queueCount - 1) % capacity
                if queueValues[back] >= required { queueCount -= 1 } else { break }
            }
            let slot = (queueHead + queueCount) % capacity
            queueValues[slot] = required
            queueFrames[slot] = frame
            queueCount += 1
            while queueFrames[queueHead] <= frame - window {
                queueHead = (queueHead + 1) % capacity
                queueCount -= 1
            }
            let minimum = queueValues[queueHead]

            boxSum += Double(minimum) - Double(boxValues[boxIndex])
            boxValues[boxIndex] = minimum
            boxIndex = (boxIndex + 1) % window
            let smoothed = Float(boxSum / Double(window))

            if smoothed < gain {
                gain = smoothed
            } else {
                let release = autoRelease ? fastRelease + (slowRelease - fastRelease) * min(1, depth * 4) : fixedRelease
                gain += (smoothed - gain) * release
            }
            depth += ((1 - smoothed) - depth) * depthFollow

            let delayedL = delayLeft[delayIndex]
            let delayedR = delayRight[delayIndex]
            delayLeft[delayIndex] = l
            delayRight[delayIndex] = r
            delayIndex = (delayIndex + 1) % latency
            frame += 1
            if primed < latency {
                primed += 1
                continue
            }
            // The clamp only catches float rounding of ceiling / peak × peak;
            // the gain already guarantees the ceiling.
            outLeft[produced] = min(max(delayedL * gain, -ceiling), ceiling)
            outRight[produced] = min(max(delayedR * gain, -ceiling), ceiling)
            produced += 1
        }
        return produced
    }

    /// Pushes the look-ahead's worth of silence through, emptying the delay
    /// line. Writes `latency` frames.
    func flush(outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) -> Int {
        let silence = [Float](repeating: 0, count: latency)
        return silence.withUnsafeBufferPointer { zeros in
            process(left: zeros.baseAddress!, right: zeros.baseAddress!, count: latency,
                    outLeft: outLeft, outRight: outRight)
        }
    }
}
