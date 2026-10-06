//
//  TimelineDrawing.swift
//  Ultramix
//
//  Everything static on the timeline in one Canvas: grid, ruler, the tempo
//  curve with its points, the clips with their waveforms, the automation
//  curves. The playhead is not here - it moves sixty times a second and lives
//  in its own overlay, so moving it never redraws any of this.
//
//  Only what is visible is drawn: waveforms column by column from the pyramid
//  level with about a bucket per pixel, curves sampled every two pixels. A
//  redraw costs by the window's width, not the length of the mix.
//

import SwiftUI

struct ClipDrawItem {
    let id: UUID
    let lane: Int
    let geometry: ClipGeometry
    let segments: [ClipSegment]
    let title: String
    let sourceBPM: Double
    let targetBPM: Double?
    let tempoAnchorBeat: Int
    let rampStartBeat: Int?
    let waveform: Waveform?
    let selected: Bool
    let muted: Bool
    let locked: Bool
    let looping: Bool
    let outOfRange: Bool
    let gainDB: Double
    let pitch: PitchShift
    let anchorBeat: Int
    /// In the clip's own beats; add `anchorBeat` for the timeline.
    let automation: ClipAutomation
}

/// A step, sine or triangle being dragged out, before it is committed.
struct DraftGesture {
    var clip: UUID
    var lane: Int
    /// As dragged, in timeline beats - what is committed.
    var drawn: AutomationGesture
    /// In the clip's own beats and cut to the clip - what is drawn.
    var gesture: AutomationGesture
}

/// What the Canvas draws, gathered once per update.
struct TimelineSnapshot {
    var clips: [ClipDrawItem] = []
    var tempo: TempoMap
    var curves: [LanePlan]
    var laneMask: Int
    var tool: TimelineTool
    var draft: DraftGesture?
    var selection: AutomationSelection?
    var marquee: CGRect?
    /// The accent colour to draw with - a Canvas cannot read the
    /// environment, so it is carried in here (see AppAccent).
    var accent: Color
    /// Each lane's colour, from the mix - worked out once here, since the
    /// Canvas cannot reach the session.
    var laneColors: [Color]
    /// The transition bars, the one picked, and one being drawn (timeline
    /// beats).
    var marks: [PlacedMark]
    var selectedMark: MarkRef?
    var draftMark: ClosedRange<Double>?

    init(session: MixSession, library: Library, tool: TimelineTool, draft: DraftGesture?,
         selection: AutomationSelection? = nil, marquee: CGRect? = nil, accent: Color = .accentColor,
         draftMark: ClosedRange<Double>? = nil) {
        self.selection = selection
        self.marquee = marquee
        self.accent = accent
        self.draftMark = draftMark
        selectedMark = session.selectedMark
        marks = session.document.placedMarks(session.grids)
        let document = session.document
        tempo = session.tempo
        laneColors = (0..<Clip.laneCount).map { LaneStyle.color($0, document.lanes) }
        laneMask = session.laneMask
        self.tool = tool
        self.draft = draft
        let grids = session.grids
        var curves = session.plan?.lanes
            ?? (0..<Clip.laneCount).map { LanePlan(document: document, lane: $0, grids: grids) }
        if let draft {
            curves[draft.lane] = LanePlan(document: document, lane: draft.lane, grids: grids) { clip in
                guard clip.id == draft.clip else { return clip.automation }
                var drawn = clip.automation
                drawn.gestures.append(draft.gesture)
                return drawn
            }
        }
        self.curves = curves
        let outOfRange = session.plan?.outOfRange ?? []
        for clip in document.clips {
            guard let track = library.track(clip.trackID), let grid = track.grid else { continue }
            let geometry = ClipGeometry(clip: clip, grid: grid)
            clips.append(ClipDrawItem(
                id: clip.id, lane: clip.lane, geometry: geometry, segments: geometry.segments(),
                title: track.displayName, sourceBPM: grid.bpm, targetBPM: clip.targetBPM,
                tempoAnchorBeat: clip.tempoAnchorBeat, rampStartBeat: clip.rampStartBeat,
                waveform: library.waveforms[clip.trackID],
                selected: session.selection.contains(clip.id), muted: clip.muted,
                locked: clip.locked, looping: clip.looping, outOfRange: outOfRange.contains(clip.id), gainDB: clip.gainDB,
                pitch: clip.pitch, anchorBeat: clip.anchorBeat, automation: clip.automation))
        }
    }
}

enum TimelineDrawing {

    static func draw(_ context: inout GraphicsContext, size: CGSize, snapshot: TimelineSnapshot, layout: TimelineLayout) {
        background(&context, size, snapshot, layout)
        grid(&context, size, layout)
        ruler(&context, size, layout)
        transitionStrip(&context, size, snapshot, layout)
        tempoLane(&context, size, snapshot, layout)
        for clip in snapshot.clips {
            self.clip(&context, clip, snapshot.laneColors[clip.lane], size, layout)
        }
        automation(&context, size, snapshot, layout)
        markSpan(&context, size, snapshot, layout)
    }

    // MARK: - Background and grid

    private static func background(_ context: inout GraphicsContext, _ size: CGSize,
                                   _ snapshot: TimelineSnapshot, _ layout: TimelineLayout) {
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: TimelineLayout.rulerHeight)),
                     with: .color(Color.primary.opacity(0.05)))
        context.fill(Path(layout.tempoRect), with: .color(Color.primary.opacity(0.025)))
        var separators = Path()
        for lane in 0..<Clip.laneCount {
            let rect = layout.laneRect(lane)
            let audible = snapshot.laneMask & (1 << lane) != 0
            context.fill(Path(rect), with: .color(audible ? snapshot.laneColors[lane].opacity(0.035) : Color.black.opacity(0.14)))
            separators.move(to: CGPoint(x: 0, y: rect.minY))
            separators.addLine(to: CGPoint(x: size.width, y: rect.minY))
        }
        for y in [TimelineLayout.rulerHeight, layout.tempoRect.minY] {
            separators.move(to: CGPoint(x: 0, y: y))
            separators.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(separators, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
    }

    /// Every how many bars a line (or label) goes, so that they are at least
    /// `minimum` pixels apart.
    static func barStep(barWidth: Double, minimum: Double) -> Int {
        for step in [1, 2, 4, 8, 16, 32, 64, 128, 256] where Double(step) * barWidth >= minimum { return step }
        return 512
    }

    private static func barRange(_ layout: TimelineLayout) -> ClosedRange<Int> {
        let visible = layout.visibleBeats
        let first = max(0, Int((visible.lowerBound / 4).rounded(.down)))
        let last = max(first, Int((visible.upperBound / 4).rounded(.up)))
        return first...last
    }

    private static func grid(_ context: inout GraphicsContext, _ size: CGSize, _ layout: TimelineLayout) {
        let barWidth = layout.pixelsPerBeat * 4
        let lineStep = barStep(barWidth: barWidth, minimum: 7)
        let strongStep = barStep(barWidth: barWidth, minimum: 56)
        let bars = barRange(layout)
        let top = TimelineLayout.rulerHeight
        var faint = Path()
        var strong = Path()
        var bar = bars.lowerBound - bars.lowerBound % lineStep
        while bar <= bars.upperBound {
            let x = layout.x(Double(bar * 4))
            if bar % strongStep == 0 {
                strong.move(to: CGPoint(x: x, y: top))
                strong.addLine(to: CGPoint(x: x, y: size.height))
            } else {
                faint.move(to: CGPoint(x: x, y: top))
                faint.addLine(to: CGPoint(x: x, y: size.height))
            }
            bar += lineStep
        }
        if layout.pixelsPerBeat >= 12 {
            let visible = layout.visibleBeats
            for beat in max(0, Int(visible.lowerBound))...max(0, Int(visible.upperBound)) where beat % 4 != 0 {
                let x = layout.x(Double(beat))
                faint.move(to: CGPoint(x: x, y: TimelineLayout.lanesTop))
                faint.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        context.stroke(faint, with: .color(Color.primary.opacity(0.05)), lineWidth: 1)
        context.stroke(strong, with: .color(Color.primary.opacity(0.13)), lineWidth: 1)
    }

    private static func ruler(_ context: inout GraphicsContext, _ size: CGSize, _ layout: TimelineLayout) {
        let barWidth = layout.pixelsPerBeat * 4
        let labelStep = barStep(barWidth: barWidth, minimum: 56)
        let bars = barRange(layout)
        var ticks = Path()
        var bar = bars.lowerBound - bars.lowerBound % labelStep
        while bar <= bars.upperBound {
            let x = layout.x(Double(bar * 4))
            ticks.move(to: CGPoint(x: x, y: 14))
            ticks.addLine(to: CGPoint(x: x, y: TimelineLayout.rulerHeight))
            context.draw(Text("\(bar + 1)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
            bar += labelStep
        }
        if layout.pixelsPerBeat >= 5 {
            let visible = layout.visibleBeats
            for beat in max(0, Int(visible.lowerBound))...max(0, Int(visible.upperBound)) where beat % 4 != 0 {
                let x = layout.x(Double(beat))
                ticks.move(to: CGPoint(x: x, y: 21))
                ticks.addLine(to: CGPoint(x: x, y: TimelineLayout.rulerHeight))
            }
        }
        context.stroke(ticks, with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
    }

    // MARK: - Transition bars

    /// The strip under the ruler: a bar per transition, named by its style
    /// where there is room, the picked one stronger, grips at both ends.
    private static func transitionStrip(_ context: inout GraphicsContext, _ size: CGSize,
                                        _ snapshot: TimelineSnapshot, _ layout: TimelineLayout) {
        let accent = snapshot.accent
        for mark in snapshot.marks {
            let rect = layout.rect(for: mark)
            guard rect.maxX >= 0, rect.minX <= size.width else { continue }
            let picked = mark.ref == snapshot.selectedMark
            let shape = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(shape, with: .color(accent.opacity(mark.locked ? 0.12 : picked ? 0.55 : 0.28)))
            context.stroke(shape, with: .color(accent.opacity(mark.locked ? 0.3 : picked ? 1 : 0.6)),
                           lineWidth: picked ? 1.5 : 1)
            if !mark.locked && rect.width > 14 {
                var grips = Path()
                for x in [rect.minX + 3, rect.maxX - 3] {
                    grips.move(to: CGPoint(x: x, y: rect.minY + 3))
                    grips.addLine(to: CGPoint(x: x, y: rect.maxY - 3))
                }
                context.stroke(grips, with: .color(Color.primary.opacity(0.5)), lineWidth: 1)
            }
            let title = context.resolve((mark.locked ? Text("\(Image(systemName: "lock.fill")) \(mark.title)") : Text(mark.title))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.primary.opacity(0.85)))
            let titleSize = title.measure(in: CGSize(width: 400, height: rect.height))
            let left = max(rect.minX, 0) + 8
            if min(rect.maxX, size.width) - left - 8 >= titleSize.width {
                context.draw(title, at: CGPoint(x: left, y: rect.midY), anchor: .leading)
            }
        }
        if let draft = snapshot.draftMark {
            let strip = layout.transitionRect.insetBy(dx: 0, dy: 3)
            let rect = CGRect(x: layout.x(draft.lowerBound), y: strip.minY,
                              width: CGFloat((draft.upperBound - draft.lowerBound) * layout.pixelsPerBeat),
                              height: strip.height)
            let shape = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(shape, with: .color(accent.opacity(0.2)))
            context.stroke(shape, with: .color(accent), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }

    /// The picked bar's range down through the lanes, so what it covers -
    /// and what deleting it would clear - is in sight.
    private static func markSpan(_ context: inout GraphicsContext, _ size: CGSize,
                                 _ snapshot: TimelineSnapshot, _ layout: TimelineLayout) {
        let range = snapshot.draftMark
            ?? snapshot.marks.first { $0.ref == snapshot.selectedMark }.map { $0.start...$0.end }
        guard let range else { return }
        let (x0, x1) = (layout.x(range.lowerBound), layout.x(range.upperBound))
        guard x1 >= 0, x0 <= size.width else { return }
        let top = TimelineLayout.lanesTop
        context.fill(Path(CGRect(x: x0, y: top, width: x1 - x0, height: size.height - top)),
                     with: .color(snapshot.accent.opacity(0.07)))
        var edges = Path()
        for x in [x0, x1] {
            edges.move(to: CGPoint(x: x, y: layout.transitionRect.maxY))
            edges.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(edges, with: .color(snapshot.accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    // MARK: - Tempo

    /// The tempo range the lane shows: what plays in view, the visible
    /// clips' targets, and at least ±2 BPM so a flat mix is not a line
    /// glued to an edge.
    static func tempoScale(_ snapshot: TimelineSnapshot, _ layout: TimelineLayout) -> ClosedRange<Double> {
        var low = Double.infinity
        var high = -Double.infinity
        var x: CGFloat = 0
        while x <= layout.size.width {
            let bpm = snapshot.tempo.bpm(atBeat: max(0, layout.beat(x)))
            low = min(low, bpm)
            high = max(high, bpm)
            x += 6
        }
        for clip in snapshot.clips {
            let px = layout.x(Double(clip.tempoAnchorBeat))
            guard px > -20, px < layout.size.width + 20 else { continue }
            let bpm = clip.targetBPM ?? clip.sourceBPM
            low = min(low, bpm)
            high = max(high, bpm)
        }
        if !low.isFinite { low = 120; high = 120 }
        let middle = (low + high) / 2
        let half = max(high - low, 4) / 2 + 1
        return (middle - half)...(middle + half)
    }

    static func tempoY(_ bpm: Double, scale: ClosedRange<Double>, layout: TimelineLayout) -> CGFloat {
        let rect = layout.tempoRect.insetBy(dx: 0, dy: 10)
        let unit = (bpm - scale.lowerBound) / (scale.upperBound - scale.lowerBound)
        return rect.maxY - CGFloat(unit) * rect.height
    }

    private static func tempoLane(_ context: inout GraphicsContext, _ size: CGSize,
                                  _ snapshot: TimelineSnapshot, _ layout: TimelineLayout) {
        let scale = tempoScale(snapshot, layout)
        let bottom = layout.tempoRect.maxY
        var line = Path()
        var x: CGFloat = 0
        while x <= size.width + 2 {
            let y = tempoY(snapshot.tempo.bpm(atBeat: max(0, layout.beat(x))), scale: scale, layout: layout)
            if x == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            x += 2
        }
        var area = line
        area.addLine(to: CGPoint(x: size.width + 2, y: bottom))
        area.addLine(to: CGPoint(x: 0, y: bottom))
        area.closeSubpath()
        context.fill(area, with: .color(snapshot.accent.opacity(0.08)))
        context.stroke(line, with: .color(snapshot.accent.opacity(0.9)), lineWidth: 1.4)

        // Ramp starts first, under the points: a diamond on the line where the
        // climb to a clip's tempo point begins, in the clip's lane colour.
        for clip in snapshot.clips {
            guard let start = clip.rampStartBeat else { continue }
            let sx = layout.x(Double(start))
            guard sx > -8, sx < size.width + 8 else { continue }
            let sy = tempoY(snapshot.tempo.bpm(atBeat: Double(start)), scale: scale, layout: layout)
            var diamond = Path()
            diamond.move(to: CGPoint(x: sx, y: sy - 5))
            diamond.addLine(to: CGPoint(x: sx + 5, y: sy))
            diamond.addLine(to: CGPoint(x: sx, y: sy + 5))
            diamond.addLine(to: CGPoint(x: sx - 5, y: sy))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(diamond, with: .color(snapshot.laneColors[clip.lane]), lineWidth: clip.selected ? 2.2 : 1.4)
        }

        // The scale first: its two numbers are in the corners, and the
        // point labels keep clear of them.
        let top = context.resolve(Text(String(format: "%.0f", scale.upperBound)).font(.system(size: 9)).foregroundStyle(.tertiary))
        let low = context.resolve(Text(String(format: "%.0f", scale.lowerBound)).font(.system(size: 9)).foregroundStyle(.tertiary))
        let topSize = top.measure(in: size)
        let lowSize = low.measure(in: size)
        context.draw(top, at: CGPoint(x: 4, y: layout.tempoRect.minY + 2), anchor: .topLeading)
        context.draw(low, at: CGPoint(x: 4, y: layout.tempoRect.maxY - 2), anchor: .bottomLeading)
        let corners = [
            CGRect(x: 4, y: layout.tempoRect.minY + 2, width: topSize.width, height: topSize.height),
            CGRect(x: 4, y: layout.tempoRect.maxY - 2 - lowSize.height, width: lowSize.width, height: lowSize.height),
        ]

        var points: [(clip: ClipDrawItem, bpm: Double, label: GraphicsContext.ResolvedText, point: TempoLabels.Point)] = []
        for clip in snapshot.clips {
            let px = layout.x(Double(clip.tempoAnchorBeat))
            guard px > -12, px < size.width + 12 else { continue }
            let bpm = clip.targetBPM ?? clip.sourceBPM
            let label = context.resolve(Text(String(format: "%.2f", bpm)).font(.system(size: 9.5, weight: .medium)).monospacedDigit())
            let point = TempoLabels.Point(x: px, y: tempoY(bpm, scale: scale, layout: layout), size: label.measure(in: size))
            points.append((clip, bpm, label, point))
        }
        let slots = TempoLabels.place(points.map(\.point), in: layout.tempoRect, blocked: corners)
        for (item, slot) in zip(points, slots) {
            let point = CGPoint(x: item.point.x, y: item.point.y)
            let color = snapshot.laneColors[item.clip.lane]
            let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(item.clip.targetBPM == nil ? Color(nsColor: .windowBackgroundColor) : color))
            context.stroke(dot, with: .color(color), lineWidth: item.clip.selected ? 2.2 : 1.4)
            guard slot != .hidden else { continue }
            let rect = TempoLabels.rect(slot, for: item.point)
            context.draw(item.label, at: CGPoint(x: rect.minX, y: rect.midY), anchor: .leading)
        }
    }

    // MARK: - Clips

    private static func clip(_ context: inout GraphicsContext, _ clip: ClipDrawItem, _ laneColor: Color,
                             _ size: CGSize, _ layout: TimelineLayout) {
        let rect = layout.rect(for: clip.geometry, lane: clip.lane)
        guard rect.maxX > -4, rect.minX < size.width + 4, rect.width > 0.5 else { return }
        let color = clip.outOfRange ? Color.red : laneColor
        let shape = Path(roundedRect: rect, cornerRadius: 5)

        var inner = context
        inner.clip(to: shape)
        if clip.muted { inner.opacity = 0.35 }
        inner.fill(shape, with: .color(color.opacity(0.16)))
        let waveRect = CGRect(x: rect.minX, y: rect.minY + 17, width: rect.width, height: max(8, rect.height - 21))
        for segment in clip.segments {
            waveform(&inner, segment, clip, waveRect, color, size, layout)
        }
        if clip.segments.count > 1 {
            var seams = Path()
            for segment in clip.segments.dropFirst() {
                let x = layout.x(segment.start)
                seams.move(to: CGPoint(x: x, y: rect.minY))
                seams.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            inner.stroke(seams, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        var title = clip.title
        // A gain is invisible in the waveform, which is drawn from the file;
        // the title is where a clip that plays quieter says so.
        if clip.gainDB != 0 { title = String(format: "%+.0f dB · ", clip.gainDB) + title }
        // So is a key shift.
        if !clip.pitch.isNone { title = "Key \(clip.pitch.label) · " + title }
        if clip.looping { title = "∞  " + title }
        if clip.muted { title = "Muted · " + title }
        // Not red alone: a lane can now be red itself, and the warning would
        // vanish into it.
        if clip.outOfRange { title = "⚠︎ " + title }
        let label = clip.locked ? Text("\(Image(systemName: "lock.fill")) \(title)") : Text(title)
        inner.draw(label.font(.system(size: 11, weight: .semibold)),
                   at: CGPoint(x: max(rect.minX, 0) + 6, y: rect.minY + 2), anchor: .topLeading)

        context.stroke(shape, with: .color(color.opacity(clip.selected ? 1 : 0.55)), lineWidth: clip.selected ? 2 : 1)
    }

    private static func waveform(_ context: inout GraphicsContext, _ segment: ClipSegment, _ clip: ClipDrawItem,
                                 _ rect: CGRect, _ color: Color, _ size: CGSize, _ layout: TimelineLayout) {
        guard let waveform = clip.waveform else { return }
        let framesPerBeat = 60 / clip.sourceBPM * AudioFrames.sampleRate
        let framesPerPixel = framesPerBeat / layout.pixelsPerBeat
        var levelIndex = 0
        while levelIndex + 1 < waveform.levels.count,
              Double(waveform.framesPerBucket << (levelIndex + 1)) <= framesPerPixel {
            levelIndex += 1
        }
        let level = waveform.levels[levelIndex]
        let bucketFrames = Double(waveform.framesPerBucket << levelIndex)
        let x0 = max(layout.x(segment.start), 0, rect.minX)
        let x1 = min(layout.x(segment.end), size.width, rect.maxX)
        guard x1 > x0 else { return }
        let middle = rect.midY
        let half = rect.height / 2
        let count = level.count
        var peaks = Path()
        var body = Path()
        var px = x0.rounded(.down)
        while px < x1 {
            let f0 = (layout.beat(px) - segment.fileStart) * framesPerBeat
            let f1 = (layout.beat(px + 1) - segment.fileStart) * framesPerBeat
            let i0 = max(0, Int((f0 / bucketFrames).rounded(.down)))
            let i1 = min(count - 1, Int((f1 / bucketFrames).rounded(.down)))
            if i0 <= i1 {
                var high: Float = 0, low: Float = 0, rms: Float = 0
                for i in i0...i1 {
                    high = max(high, level.maxL[i], level.maxR[i])
                    low = min(low, level.minL[i], level.minR[i])
                    rms = max(rms, level.rmsL[i], level.rmsR[i])
                }
                peaks.addRect(CGRect(x: px, y: middle - CGFloat(high) * half, width: 1,
                                     height: max(1, CGFloat(high - low) * half)))
                body.addRect(CGRect(x: px, y: middle - CGFloat(rms) * half, width: 1,
                                    height: max(1, CGFloat(2 * rms) * half)))
            }
            px += 1
        }
        context.fill(peaks, with: .color(color.opacity(0.45)))
        context.fill(body, with: .color(color.opacity(0.9)))
    }

    // MARK: - Automation

    private static func automation(_ context: inout GraphicsContext, _ size: CGSize,
                                   _ snapshot: TimelineSnapshot, _ layout: TimelineLayout) {
        for kind in AutomationKind.allCases {
            let active = snapshot.tool.kind == kind
            // In the clip tool only a drawn volume curve is shown, faintly:
            // enough to see that a fade is there without cluttering.
            guard active || (snapshot.tool == .clips && kind == .volume) else { continue }
            for clip in snapshot.clips {
                guard active || !clip.automation.volume.isEmpty
                        || clip.automation.gestures.contains(where: { $0.kind == kind }) else { continue }
                clipAutomation(&context, clip, kind: kind, active: active, size, snapshot, layout)
            }
        }
        if let marquee = snapshot.marquee {
            context.fill(Path(marquee), with: .color(snapshot.accent.opacity(0.08)))
            context.stroke(Path(marquee), with: .color(snapshot.accent.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// One clip's curve of one kind. Automation exists only inside clips, so
    /// everything here is cut to the clip: the curve, the guide and the bands
    /// to its width, the nodes to its visible span. What a trim hid stays
    /// stored, but it is neither heard nor shown.
    private static func clipAutomation(_ context: inout GraphicsContext, _ clip: ClipDrawItem, kind: AutomationKind,
                                       active: Bool, _ size: CGSize, _ snapshot: TimelineSnapshot,
                                       _ layout: TimelineLayout) {
        let lane = clip.lane
        let rect = layout.rect(for: clip.geometry, lane: lane)
        let x0 = max(rect.minX, 0)
        let x1 = min(rect.maxX, size.width)
        guard x1 > x0 else { return }
        let anchor = Double(clip.anchorBeat)
        let span = clip.geometry.start...clip.geometry.end
        let color = snapshot.laneColors[lane]
        let curve = snapshot.curves[lane].curve(kind)
        let laneRect = layout.laneRect(lane)
        // The full lane height, so a curve at +12 dB or silence is not cut
        // off at the clip's inset.
        var inner = context
        inner.clip(to: Path(CGRect(x: x0, y: laneRect.minY, width: x1 - x0, height: laneRect.height)))

        if active {
            let rest = layout.y(value: kind == .volume ? 0 : kind.restValue, kind: kind, lane: lane)
            var guide = Path()
            guide.move(to: CGPoint(x: x0, y: rest))
            guide.addLine(to: CGPoint(x: x1, y: rest))
            inner.stroke(guide, with: .color(Color.primary.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            let bandTop = laneRect.minY + 3
            let bandHeight = layout.laneHeight - 6
            func band(_ gesture: AutomationGesture) -> Path? {
                let start = max(gesture.start + anchor, span.lowerBound)
                let end = min(gesture.end + anchor, span.upperBound)
                guard end > start else { return nil }
                return Path(roundedRect: CGRect(x: layout.x(start), y: bandTop,
                                                width: CGFloat((end - start) * layout.pixelsPerBeat), height: bandHeight),
                            cornerRadius: 3)
            }
            for gesture in clip.automation.gestures where gesture.kind == kind {
                guard let shape = band(gesture) else { continue }
                let picked = snapshot.selection?.contains(gesture: gesture.id, clip: clip.id) == true
                inner.fill(shape, with: .color(picked ? snapshot.accent.opacity(0.22) : Color.primary.opacity(0.07)))
            }
            if let draft = snapshot.draft, draft.clip == clip.id, draft.gesture.kind == kind, let shape = band(draft.gesture) {
                inner.fill(shape, with: .color(snapshot.accent.opacity(0.14)))
            }
        }

        // The lane curve holds this clip's curve over its span; the last
        // sample is taken just inside the end, where the lane already rests.
        var path = Path()
        var x = x0
        while true {
            let beat = min(layout.beat(x), span.upperBound - 1e-9)
            let point = CGPoint(x: x, y: layout.y(value: curve.value(at: beat), kind: kind, lane: lane))
            if x == x0 { path.move(to: point) } else { path.addLine(to: point) }
            if x >= x1 { break }
            x = min(x + 2, x1)
        }
        inner.stroke(path, with: .color(active ? Color.primary.opacity(0.85) : color.opacity(0.55)),
                     lineWidth: active ? 1.6 : 1)

        guard active else { return }
        for node in clip.automation.nodes(kind) where span.contains(node.beat + anchor) {
            let point = CGPoint(x: layout.x(node.beat + anchor), y: layout.y(value: node.value, kind: kind, lane: lane))
            guard point.x > -6, point.x < size.width + 6 else { continue }
            let dot = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(color))
            context.stroke(dot, with: .color(Color.white.opacity(0.9)), lineWidth: 1)
            if snapshot.selection?.contains(node, clip: clip.id) == true {
                let ring = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                context.stroke(ring, with: .color(snapshot.accent), lineWidth: 2)
            }
        }
    }
}
