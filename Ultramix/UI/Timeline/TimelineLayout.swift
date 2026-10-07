//
//  TimelineLayout.swift
//  Ultramix
//
//  Where things are on the timeline: beats to pixels and back, which lane a
//  point is in, where an automation value sits in its lane. One struct for the
//  drawing and the hit-testing both, so what is drawn at a place is what a
//  click at that place finds.
//

import SwiftUI

enum TimelineTool: String, CaseIterable, Identifiable {
    case clips, volume, pan, lowPass, highPass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clips: "Clips"
        case .volume: "Volume"
        case .pan: "Pan"
        case .lowPass: "LPF"
        case .highPass: "HPF"
        }
    }

    var kind: AutomationKind? {
        switch self {
        case .clips: nil
        case .volume: .volume
        case .pan: .pan
        case .lowPass: .lowPass
        case .highPass: .highPass
        }
    }
}

enum DrawStyle: String, CaseIterable, Identifiable {
    case nodes, step, sine, triangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nodes: "Nodes"
        case .step: "Step"
        case .sine: "Sine"
        case .triangle: "Triangle"
        }
    }

    var shape: GestureShape? {
        switch self {
        case .nodes: nil
        case .step: .step
        case .sine: .sine
        case .triangle: .triangle
        }
    }
}

enum LaneStyle {
    static let names = ["A", "B", "C"]

    /// The colour a lane draws in: the one chosen in the mix, or the lane's
    /// own. Every place that colours something by its lane asks here, with
    /// the document's lanes, so a chosen colour reaches all of them at once.
    static func color(_ lane: Int, _ lanes: [LaneSettings]) -> Color {
        color(hex: hex(lane, lanes))
    }

    /// The hex behind `color(_:_:)`.
    static func hex(_ lane: Int, _ lanes: [LaneSettings]) -> String {
        (lanes.indices.contains(lane) ? lanes[lane].color : nil)
            ?? LaneSettings.defaultColors[lane % LaneSettings.defaultColors.count]
    }

    static func color(hex: String) -> Color {
        guard let rgb = HexColor.components(hex) else { return .gray }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

struct TimelineLayout {
    static let rulerHeight: CGFloat = 26
    /// The strip of transition bars, between the ruler and the tempo lane.
    static let transitionHeight: CGFloat = 18
    static let tempoHeight: CGFloat = 110
    /// Where the clip lanes begin.
    static let lanesTop = rulerHeight + transitionHeight + tempoHeight
    /// Room before beat 0, so the first clip's edge can be grabbed.
    static let leadingPad: CGFloat = 12

    var pixelsPerBeat: Double
    var scrollX: CGFloat
    var size: CGSize
    /// Which lane each row shows, top to bottom. A, B, C in a mix; the live
    /// set reorders them (see LiveSet.compacted). Everything that places a
    /// lane or finds one under the pointer goes through here, so drawing,
    /// hits and drops follow the order together.
    var laneOrder: [Int] = Array(0..<Clip.laneCount)
    /// The lanes shown with a row per stem under each clip (LaneGeometry).
    var expanded: Set<Int> = []

    /// Each row's height, top to bottom.
    private var heights: [CGFloat] {
        LaneGeometry.heights(total: Double(size.height - Self.lanesTop), expanded: laneOrder.map { expanded.contains($0) })
            .map { CGFloat($0) }
    }

    var transitionRect: CGRect {
        CGRect(x: 0, y: Self.rulerHeight, width: size.width, height: Self.transitionHeight)
    }

    var tempoRect: CGRect {
        CGRect(x: 0, y: Self.rulerHeight + Self.transitionHeight, width: size.width, height: Self.tempoHeight)
    }

    /// A transition bar's box in the strip.
    func rect(for mark: PlacedMark) -> CGRect {
        let strip = transitionRect.insetBy(dx: 0, dy: 3)
        return CGRect(x: x(mark.start), y: strip.minY, width: CGFloat((mark.end - mark.start) * pixelsPerBeat),
                      height: strip.height)
    }

    func laneRect(_ lane: Int) -> CGRect {
        let row = laneOrder.firstIndex(of: lane) ?? lane
        let heights = heights
        let top = heights.prefix(row).reduce(Self.lanesTop, +)
        return CGRect(x: 0, y: top, width: size.width, height: row < heights.count ? heights[row] : 0)
    }

    func lane(atY y: CGFloat) -> Int? {
        guard y >= Self.lanesTop else { return nil }
        var top = Self.lanesTop
        for (row, height) in heights.enumerated() {
            if y < top + height { return laneOrder[row] }
            top += height
        }
        return nil
    }

    /// One row of a lane: the clip's own (`part` nil) - the whole lane when
    /// it is not expanded - or a stem's under it.
    func rowRect(_ lane: Int, part: Stem?) -> CGRect {
        let rect = laneRect(lane)
        guard expanded.contains(lane) else { return rect }
        let rows = LaneGeometry.rows(laneHeight: Double(rect.height))
        let clip = CGFloat(rows.clip), stem = CGFloat(rows.stem)
        guard let part else { return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: clip) }
        return CGRect(x: rect.minX, y: rect.minY + clip + CGFloat(part.rawValue) * stem, width: rect.width, height: stem)
    }

    /// The stem whose row holds `y` in an expanded lane; nil in the clip's
    /// row, or in a lane that is not expanded.
    func part(atY y: CGFloat, lane: Int) -> Stem? {
        guard expanded.contains(lane) else { return nil }
        return Stem.allCases.first { rowRect(lane, part: $0).minY <= y && y < rowRect(lane, part: $0).maxY }
    }

    func x(_ beat: Double) -> CGFloat {
        CGFloat(beat * pixelsPerBeat) + Self.leadingPad - scrollX
    }

    func beat(_ x: CGFloat) -> Double {
        Double(x + scrollX - Self.leadingPad) / pixelsPerBeat
    }

    var visibleBeats: ClosedRange<Double> {
        beat(0)...beat(size.width)
    }

    static func contentWidth(endBeat: Double, pixelsPerBeat: Double, viewport: CGFloat) -> CGFloat {
        max(viewport, CGFloat((endBeat + 64) * pixelsPerBeat) + leadingPad + viewport * 0.5)
    }

    /// A clip's box in its lane.
    func rect(for geometry: ClipGeometry, lane: Int) -> CGRect {
        let box = laneRect(lane).insetBy(dx: 0, dy: 5)
        return CGRect(x: x(geometry.start), y: box.minY,
                      width: CGFloat(geometry.length * pixelsPerBeat), height: box.height)
    }

    // MARK: - Automation values

    /// Where a row's automation values run: the row, less a margin - a
    /// smaller one in a stem's thin row.
    private func valueBox(_ lane: Int, _ part: Stem?) -> CGRect {
        rowRect(lane, part: part).insetBy(dx: 0, dy: part == nil ? 10 : 3)
    }

    func y(value: Double, kind: AutomationKind, lane: Int, part: Stem? = nil) -> CGFloat {
        let box = valueBox(lane, part)
        let unit: Double
        switch kind {
        case .volume: unit = Automation.faderTravel(dB: value)
        case .pan: unit = (value + 1) / 2
        case .lowPass, .highPass: unit = min(max(value, 0), 1)
        }
        return box.maxY - CGFloat(unit) * box.height
    }

    /// The value at height `y`, with a small detent at the natural resting
    /// place of each kind - unity volume, centre pan, a filter out (the top
    /// of a low-pass lane, the bottom of a high-pass one) - so the
    /// hand can find it without aiming.
    func value(atY y: CGFloat, kind: AutomationKind, lane: Int, part: Stem? = nil) -> Double {
        let box = valueBox(lane, part)
        let unit = Double(min(max((box.maxY - y) / box.height, 0), 1))
        switch kind {
        case .volume:
            return abs(unit - 0.5) < 0.012 ? 0 : (Automation.dB(faderTravel: unit) * 10).rounded() / 10
        case .pan:
            let value = unit * 2 - 1
            return abs(value) < 0.04 ? 0 : (value * 100).rounded() / 100
        case .lowPass:
            return unit > 0.98 ? 1 : (unit * 100).rounded() / 100
        case .highPass:
            return unit < 0.02 ? 0 : (unit * 100).rounded() / 100
        }
    }

    /// The values between two heights in a lane, lowest first - exactly,
    /// without the detents and rounding of `value(atY:)`, which would move
    /// a selection rectangle's edges. The bottom of a volume lane is silence.
    func valueRange(fromY a: CGFloat, toY b: CGFloat, kind: AutomationKind, lane: Int,
                    part: Stem? = nil) -> ClosedRange<Double> {
        let box = valueBox(lane, part)
        func value(_ y: CGFloat) -> Double {
            let unit = Double(min(max((box.maxY - y) / box.height, 0), 1))
            switch kind {
            case .volume: return Automation.dB(faderTravel: unit)
            case .pan: return unit * 2 - 1
            case .lowPass, .highPass: return unit
            }
        }
        let low = value(max(a, b))
        let high = value(min(a, b))
        return min(low, high)...max(low, high)
    }
}
