//
//  LaneKnob.swift
//  Ultramix
//
//  One lane knob in the lane header: an unfilled track over 270°, the accent
//  arc over the part in use, a body disc with the raw value in the middle, and
//  the gap at the bottom so the two ends can be told apart. Pan fills from the
//  middle out.
//
//  The number is set like the lane's name beside it (callout, not bold, one
//  size for every value); the function under the knob like the transport bar's
//  captions (caption2). The knob is 38 points and the disc inside the arc 26,
//  so "127" - 22.7 points in that font - has room either side.
//
//  Drag up or down to turn it, double-click for neutral; the right-click menu
//  has the function and Learn, as Settings › MIDI Controller does.
//

import SwiftUI

struct LaneKnob: View {
    let slot: Int
    var knobs = LaneKnobController.shared
    @Environment(\.accent) private var accent
    @State private var dragStart: Int?

    static let size: CGFloat = 38
    /// The lane name's size without its weight, the same for every value:
    /// 12 and 127 must not be drawn in two sizes.
    static let valueFont = Font.callout.monospacedDigit()

    private var state: KnobState { knobs.state(slot) }
    private var learning: Bool { knobs.learning == slot }
    private var lane: Int { slot / LaneKnobMath.knobsPerLane }
    private var number: Int { slot % LaneKnobMath.knobsPerLane + 1 }

    var body: some View {
        // Read here, in the body, and handed to the Canvas, so the value is
        // what the view observes - not something only its drawing closure
        // happens to read (see TimelineView's children, which froze that way).
        let current = state
        let learning = learning
        VStack(spacing: -1) {
            Canvas { context, size in draw(current, learning: learning, in: &context, size: size) }
                .frame(width: Self.size, height: Self.size)
            Text(current.function.short)
                .font(.caption2)
                .foregroundStyle(learning ? accent : .secondary)
        }
        .frame(width: Self.size + 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let start = dragStart ?? state.value
                    dragStart = start
                    // Two points a step: the full travel is a comfortable
                    // 254-point drag, and one step is still reachable.
                    knobs.set(slot, to: start - Int((drag.translation.height / 2).rounded()))
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { knobs.reset(slot) }
        .contextMenu {
            Picker("Function", selection: Binding(get: { state.function },
                                                  set: { knobs.setFunction(slot, $0) })) {
                ForEach(KnobFunction.allCases) { Text($0.title).tag($0) }
            }
            Button(learning ? "Cancel Learn" : "Learn") { knobs.toggleLearn(slot) }
            Button("Forget CC") { knobs.forget(slot) }
                .disabled(!knobs.setup.slots[slot].isAssigned)
            Divider()
            Button("Reset") { knobs.reset(slot) }
        }
        .help(help)
        // A slider to Accessibility: a plain element with an adjustable
        // action came out as an unlabelled AXUnknown.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(state.value) }, set: { knobs.set(slot, to: Int($0.rounded())) }),
                   in: 0...127, step: 1) {
                Text("Lane \(LaneStyle.names[lane]) knob \(number), \(state.function.title)")
            }
        }
    }

    private var help: String {
        let assignment = knobs.setup.slots[slot]
        let source = learning ? "Learn: move a control on the MIDI controller" : assignment.label
        return "Lane \(LaneStyle.names[lane]) · Knob \(number) · \(state.function.title) · \(source)"
    }

    private func draw(_ state: KnobState, learning: Bool, in context: inout GraphicsContext, size: CGSize) {
        let margin: CGFloat = 1.5
        let arcWidth: CGFloat = 3
        let diameter = min(size.width, size.height) - margin * 2
        guard diameter > 0 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = diameter / 2 - arcWidth / 2
        let fraction = CGFloat(state.value) / 127

        // Degrees clockwise from 3 o'clock, y down: 135 → 405 sweeps from
        // lower left over the top to lower right, the gap at 6 o'clock.
        let trackStart = 135.0
        let trackSweep = 270.0
        context.stroke(arc(center, radius, trackStart, trackStart + trackSweep),
                       with: .color(learning ? accent.opacity(0.5) : .secondary.opacity(0.25)),
                       style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))

        // Pan fills from the middle toward the value; at 64 exactly the span
        // is empty and nothing is drawn.
        let bipolar = state.function.bipolar
        let middle = trackStart + trackSweep * 64 / 127
        let fillStart = bipolar ? middle : trackStart
        let fillEnd = trackStart + trackSweep * fraction
        if abs(fillEnd - fillStart) > 0.01 {
            context.stroke(arc(center, radius, fillStart, fillEnd), with: .color(accent),
                           style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
        }

        let bodyRadius = radius - arcWidth
        guard bodyRadius > 0 else { return }
        let face = Path(ellipseIn: CGRect(x: center.x - bodyRadius, y: center.y - bodyRadius,
                                          width: bodyRadius * 2, height: bodyRadius * 2))
        context.fill(face, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.stroke(face, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

        // Always the same size - the knob is big enough for "127" - so the
        // number does not jump when it goes from two digits to three.
        context.draw(context.resolve(Text("\(state.value)")
                        .font(Self.valueFont)), at: center)
    }

    /// A polyline rather than `Path.addArc`, so the sweep direction does not
    /// depend on that API's clockwise flag in a flipped space.
    private func arc(_ center: CGPoint, _ radius: CGFloat, _ start: Double, _ end: Double) -> Path {
        var path = Path()
        let steps = 36
        for step in 0...steps {
            let degrees = start + (end - start) * Double(step) / Double(steps)
            let radians = degrees * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
