//
//  TimelineBar.swift
//  Ultramix
//
//  The strip right above the ruler: what a drag on the timeline edits, how a
//  dragged clip moves, whether the view follows the playhead, and zoom. All of
//  it is about the timeline below, so it sits there and not in the window's
//  toolbar, where it read like a switch for the whole window.
//

import SwiftUI

struct TimelineBar: View {
    let session: MixSession
    @Binding var pixelsPerBeat: Double
    @Binding var follow: Bool
    @Binding var tool: TimelineTool
    @Binding var drawStyle: DrawStyle
    @Binding var period: Double

    static let height: CGFloat = 36

    /// Full words where there is room; where the column is narrow - library
    /// and inspector both open - "Move" goes, Follow Playhead becomes its
    /// symbol and the zoom slider shorter, rather than every label being cut.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .barSurface()
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Picker("Edit", selection: $tool) {
                ForEach(TimelineTool.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Edit clips, or draw volume, pan, low-pass or high-pass automation (Tab)")

            if tool != .clips {
                Picker("Draw", selection: $drawStyle) {
                    ForEach(DrawStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Nodes: click to place a point, drag across empty space to select points. Step, sine, triangle: drag to draw a repeating movement, ⇧-drag to select. Delete removes the selection; ⌥-click removes a single point; double-click resets a point to its resting value.")
                if drawStyle != .nodes {
                    Picker("Period", selection: $period) {
                        ForEach([0.25, 0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { value in
                            Text(Self.periodTitle(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Length of one cycle of the movement")
                }
            }

            Divider().frame(height: 16)

            // For every clip, so it shows whatever is selected. "Move" and
            // not "Snap": Off does not let a clip be dragged at all.
            HStack(spacing: 6) {
                if !compact {
                    Text("Move").foregroundStyle(.secondary).fixedSize()
                }
                Picker("Move", selection: Binding(get: { session.moveMode }, set: { session.moveMode = $0 })) {
                    ForEach(MoveMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .help("What a dragged clip snaps to: Off does not move clips, Free any beat, Half every half bar, Full bar lines. ⌥← ⌥→ still move a beat.")

            Spacer(minLength: 8)

            Toggle(isOn: $follow) {
                if compact {
                    Image(systemName: "arrow.right.to.line")
                } else {
                    Text("Follow Playhead").fixedSize()
                }
            }
            .toggleStyle(.button)
            .help("Follow Playhead: keep the playhead in view while the mix plays")
            .accessibilityLabel("Follow Playhead")

            HStack(spacing: 4) {
                Button { pixelsPerBeat = TimelineZoom.zoomed(pixelsPerBeat, by: 1 / 1.5) } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("Zoom out")
                Slider(value: Binding(get: { log2(pixelsPerBeat) },
                                      set: { pixelsPerBeat = pow(2, $0) }),
                       in: log2(TimelineZoom.range.lowerBound)...log2(TimelineZoom.range.upperBound))
                    .frame(width: compact ? 64 : 100)
                    .accessibilityLabel("Zoom")
                Button { pixelsPerBeat = TimelineZoom.zoomed(pixelsPerBeat, by: 1.5) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Zoom in")
            }
            .buttonStyle(.borderless)
            .help("Zoom (+ / − on the timeline, the mouse wheel, or pinch)")
        }
    }

    static func periodTitle(_ beats: Double) -> String {
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

/// The line along the bottom of the window: how much there is in the mix on
/// the left, what is selected on the right.
struct StatusLine: View {
    let session: MixSession
    let library: Library

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Text(selection)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .barSurface()
    }

    private var summary: String {
        let clips = session.document.clips.count
        // A dropped song stays invisible until it is analysed; this says
        // that something is on its way.
        let waiting = session.awaitingPlacement.count
        let prefix = waiting == 0 ? "" : "Analysing \(waiting) song\(waiting == 1 ? "" : "s") for the mix · "
        guard clips > 0 else { return prefix + "No clips · drag tracks from the library onto a lane" }
        let seconds = max(0, session.tempo.seconds(atBeat: session.endBeat))
        return prefix + "\(clips) clip\(clips == 1 ? "" : "s") · \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }

    private var selection: String {
        if let ref = session.selectedMark {
            let grids = session.grids
            guard let mark = session.document.placedMarks(grids).first(where: { $0.ref == ref }),
                  let transition = session.document.transition(over: mark.start, mark.end, grids: grids)
            else { return "Transition selected" }
            return "\(mark.title) · Lane \(LaneStyle.number(transition.outgoingLane)) → Lane \(LaneStyle.number(transition.incomingLane))"
        }
        let count = session.selection.count
        guard count == 1, let id = session.selection.first,
              let clip = session.document.clips.first(where: { $0.id == id }) else {
            return count == 0 ? "Nothing selected" : "\(count) clips selected"
        }
        let lane = "Lane \(LaneStyle.number(clip.lane))"
        if let part = session.selectedPart { return "\(lane) · \(part.name.capitalized) of the clip selected" }
        return "\(lane) · \(library.track(clip.trackID)?.displayName ?? "clip") selected"
    }
}
