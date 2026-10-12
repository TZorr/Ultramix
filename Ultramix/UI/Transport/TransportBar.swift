//
//  TransportBar.swift
//  Ultramix
//
//  The group in the middle of the window's toolbar: play, where the playhead
//  is and the tempo playing there, in one framed readout, and beside it the
//  output level with its units - the bars at 30 frames a second, the dBFS and LUFS numbers on
//  slower clocks of their own. The editing tool and zoom are the timeline's
//  (TimelineBar).
//
//  The live parts are redrawn by a TimelineView at 30 frames a second from the
//  engine's atomics. None of them is observable state, and none should be: a
//  value that changes every audio block would redraw the whole window every
//  audio block.
//
//  Which means every live value has to be *read inside* the TimelineView's
//  closure and handed to its view as a plain value. A child given only the
//  session reads the atomics in its own body - and SwiftUI, seeing the same
//  session as last frame, never calls that body again. That is how the first
//  meters stood still at zero while the mix played.
//

import SwiftUI

/// The window toolbar's middle: back to the start, play, record, and one
/// framed readout of where the playhead is - bar, time, tempo.
///
/// A toolbar item is laid out by Auto Layout from the size SwiftUI reports.
/// Content that redraws 30 times a second must never change that size, or
/// every frame asks the window for another constraint pass - and during a
/// resize or an animated layout that ran past AppKit's limit and crashed
/// ("more Update Constraints in Window passes than there are views"). So
/// the item has one fixed size, whatever it shows.
struct TransportControls: View {
    let session: MixSession

    static let size = CGSize(width: 330, height: 34)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    Button {
                        session.seek(toBeat: 0)
                    } label: {
                        Image(systemName: "backward.end.fill").frame(width: 22)
                    }
                    .help("Go to Start (Home)")
                    Button {
                        session.togglePlay()
                    } label: {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 26)
                    }
                    .help("Play / Pause (Space)")
                    if !session.isLive {
                        Toggle(isOn: Binding(get: { session.isRecording }, set: { session.isRecording = $0 })) {
                            Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
                                .font(.title3)
                                .foregroundStyle(session.isRecording ? Color.red : Color.secondary)
                                .frame(width: 22)
                        }
                        .toggleStyle(.button)
                        .accessibilityLabel("Record knobs")
                        .help(session.isRecording
                              ? "Recording: a lane knob turned while the mix plays writes into the clip under the playhead. Click or ⌘R to stop recording."
                              : "Record the lane knobs as automation, inside the clips, while the mix plays (⌘R)")
                    }
                }
                .buttonStyle(.borderless)
                PositionReadout(beat: session.playheadBeat(), tempo: session.tempo,
                                master: session.document.masterLocked)
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// The output's level beside the transport: peak meters and the overload
/// lamp, the peak in dBFS, and short-term loudness. Each on its own clock -
/// see the note at the top of the file.
///
/// The bars move at 30 frames a second; the numbers do not. A number that
/// changes 30 times a second cannot be read, so the peak is shown twice a
/// second - as the highest peak since it was last shown, so a short
/// transient between two readings is not lost.
struct OutputMeter: View {
    let session: MixSession

    /// Fixed, like the transport's: see there.
    static let size = CGSize(width: 214, height: 30)

    @State private var hold = PeakHold()

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                // The only reader of the meters: reading clears the
                // overload flag, and a second reader would steal the lamp.
                let levels = session.engine.readMeters()
                let _ = hold.feed(max(levels.left, levels.right))
                MeterView(left: levels.left, right: levels.right,
                          clipped: session.overloadLamp(levels.overload))
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                PeakReadout(peak: hold.take())
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                ShortTermReadout(lufs: session.engine.readShortTermLUFS())
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// The highest peak since it was last taken. A plain object, not observed:
/// feeding it 30 times a second must not redraw anything.
final class PeakHold {
    private var peak: Float = 0

    func feed(_ value: Float) {
        peak = max(peak, value)
    }

    /// The held peak; the next interval starts from nothing.
    func take() -> Float {
        defer { peak = 0 }
        return peak
    }
}

/// The timeline's zoom, kept in one place for the bar and the keys.
enum TimelineZoom {
    static let range: ClosedRange<Double> = 0.25...256

    static func zoomed(_ pixelsPerBeat: Double, by factor: Double) -> Double {
        min(max(pixelsPerBeat * factor, range.lowerBound), range.upperBound)
    }
}

/// Bar and beat, clock time, and the tempo playing at the playhead - one
/// framed box, each value with its name under it.
struct PositionReadout: View {
    let beat: Double
    let tempo: TempoMap
    /// The master tempo is locked: the tempo shown is the master's.
    var master = false

    var body: some View {
        let seconds = max(0, tempo.seconds(atBeat: beat))
        let whole = max(0, beat)
        HStack(spacing: 0) {
            cell("\(Int(whole / 4) + 1).\(Int(whole.truncatingRemainder(dividingBy: 4)) + 1)", "Bar", width: 62)
            Divider()
            cell(String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)), "Time", width: 78)
            Divider()
            cell(String(format: "%.2f", tempo.bpm(atBeat: whole)), master ? "BPM · Master" : "BPM", width: 84)
        }
        .monospacedDigit()
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private func cell(_ value: String, _ name: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            Text(name)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(width: width, alignment: .leading)
    }
}

/// Peak meters for the output and an overload lamp. Given plain values -
/// see the note at the top of the file.
struct MeterView: View {
    let left: Float
    let right: Float
    let clipped: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 3) {
                bar(left)
                bar(right)
            }
            .frame(width: 70)
            Text("OL")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(clipped ? Color.white : Color.secondary.opacity(0.5))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(clipped ? Color.red : Color.secondary.opacity(0.15)))
                .help("Lights when the output had to be clipped")
        }
    }

    /// −48 … 0 dBFS across the width.
    private func bar(_ peak: Float) -> some View {
        let db = 20 * log10(max(Double(peak), 1e-5))
        let fraction = min(max((db + 48) / 48, 0), 1)
        let color: Color = db > -1 ? .red : db > -6 ? .yellow : .green
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color.gradient).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

/// The output's peak in dBFS, held over the last half second (OutputMeter).
struct PeakReadout: View {
    let peak: Float

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(peak < 1e-4 ? "−∞" : String(format: "%.1f", 20 * log10(Double(peak))))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text("dBFS").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .frame(width: 40, alignment: .trailing)
        .help("Peak level of the output in dBFS: the highest peak of the last half second")
    }
}

/// Short-term loudness of the output. Given a plain value, like the meters.
struct ShortTermReadout: View {
    let lufs: Double?

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(lufs.map { String(format: "%.1f", $0) } ?? "−∞")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text("LUFS-S").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .frame(width: 44, alignment: .trailing)
        .help("Short-term loudness of the output: the last 3 seconds, K-weighted, after the limiter. Reads about 4 dB below the inspector's clip loudness, because a lane without drawn volume rests at −4 dB.")
    }
}
