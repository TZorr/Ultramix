//
//  TransportBar.swift
//  Ultramix
//
//  Play, where the playhead is, the tempo playing there, the output level, the
//  editing tool, and zoom.
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

struct TransportBar: View {
    let session: MixSession
    @Binding var pixelsPerBeat: Double
    @Binding var follow: Bool
    @Binding var tool: TimelineTool
    @Binding var drawStyle: DrawStyle
    @Binding var period: Double

    static let zoomRange: ClosedRange<Double> = 0.25...256

    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                let levels = session.engine.readMeters()
                HStack(spacing: 10) {
                    Button {
                        session.seek(toBeat: 0)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .help("Go to Start (Home)")
                    Button {
                        session.togglePlay()
                    } label: {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 22)
                    }
                    .help("Play / Pause (Space)")
                    if !session.isLive {
                        Toggle(isOn: Binding(get: { session.isRecording }, set: { session.isRecording = $0 })) {
                            Image(systemName: session.isRecording ? "record.circle.fill" : "record.circle")
                                .font(.title3)
                                .foregroundStyle(session.isRecording ? Color.red : Color.secondary)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Record knobs")
                        .help(session.isRecording
                              ? "Recording: a lane knob turned while the mix plays writes into the clip under the playhead. Click or ⌘R to stop recording."
                              : "Record the lane knobs as automation, inside the clips, while the mix plays (⌘R)")
                    }
                    PositionReadout(beat: session.playheadBeat(), tempo: session.tempo)
                    Divider().frame(height: 26)
                    MeterView(left: levels.left, right: levels.right,
                              clipped: session.overloadLamp(levels.overload))
                }
            }
            .buttonStyle(.borderless)
            // Its own, slower clock: a number that changes 30 times a second
            // cannot be read, and four times is enough to follow.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                ShortTermReadout(lufs: session.engine.readShortTermLUFS())
            }

            Spacer(minLength: 12)

            Picker("Tool", selection: $tool) {
                ForEach(TimelineTool.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .help("Edit clips, or draw volume, pan, low-pass or high-pass automation (Tab)")

            if tool != .clips {
                Picker("Draw", selection: $drawStyle) {
                    ForEach(DrawStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                .help("Nodes: click to place a point, drag across empty space to select points. Step, sine, triangle: drag to draw a repeating movement, ⇧-drag to select. Delete removes the selection; ⌥-click removes a single point; double-click resets a point to its resting value.")
                if drawStyle != .nodes {
                    Picker("Period", selection: $period) {
                        ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { value in
                            Text(periodTitle(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Length of one cycle of the movement")
                }
            }

            Spacer(minLength: 12)

            Toggle(isOn: $follow) {
                Image(systemName: "arrow.right.to.line")
            }
            .toggleStyle(.button)
            .help("Follow the playhead")

            HStack(spacing: 4) {
                Button { zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.borderless)
                Slider(value: Binding(get: { log2(pixelsPerBeat) },
                                      set: { pixelsPerBeat = pow(2, $0) }),
                       in: log2(Self.zoomRange.lowerBound)...log2(Self.zoomRange.upperBound))
                    .frame(width: 110)
                Button { zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.borderless)
            }
            .help("Zoom (+ / − on the timeline, or pinch)")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.bar)
    }

    private func zoom(by factor: Double) {
        pixelsPerBeat = min(max(pixelsPerBeat * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func periodTitle(_ beats: Double) -> String {
        switch beats {
        case 0.25: "1/16"
        case 0.5: "1/8"
        case 1: "1 beat"
        case 2: "2 beats"
        case 4: "1 bar"
        default: "\(Int(beats / 4)) bars"
        }
    }
}

/// Bar and beat, clock time, and the tempo playing at the playhead.
struct PositionReadout: View {
    let beat: Double
    let tempo: TempoMap

    var body: some View {
        let seconds = max(0, tempo.seconds(atBeat: beat))
        let whole = max(0, beat)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(whole / 4) + 1).\(Int(whole.truncatingRemainder(dividingBy: 4)) + 1)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("bar.beat").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)))
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                Text("time").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%.2f", tempo.bpm(atBeat: whole)))
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                Text("BPM").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)
        }
        .monospacedDigit()
    }
}

/// Peak meters for the output, the louder channel's peak in dBFS, and an
/// overload lamp. Given plain values - see the note at the top of the file.
struct MeterView: View {
    let left: Float
    let right: Float
    let clipped: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 3) {
                bar(left)
                bar(right)
            }
            .frame(width: 120)
            Text(readout)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .help("Peak level in dBFS")
            Text("OL")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(clipped ? Color.white : Color.secondary.opacity(0.5))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(clipped ? Color.red : Color.secondary.opacity(0.15)))
                .help("Lights when the output had to be clipped")
        }
    }

    private var readout: String {
        let peak = max(left, right)
        return peak < 1e-4 ? "−∞" : String(format: "%.1f", 20 * log10(Double(peak)))
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
        .frame(height: 5)
    }
}

/// Short-term loudness of the output. Given a plain value, like the meters.
struct ShortTermReadout: View {
    let lufs: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(lufs.map { String(format: "%.1f", $0) } ?? "−∞")
                .font(.system(size: 13, weight: .medium, design: .rounded))
            Text("LUFS S").font(.caption2).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .frame(width: 48, alignment: .leading)
        .help("Short-term loudness of the output: the last 3 seconds, K-weighted, after the limiter. Reads about 4 dB below the clip bar's LUFS, because a lane without drawn volume rests at −4 dB.")
    }
}
