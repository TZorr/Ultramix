//
//  BeatgridStrip.swift
//  Ultramix
//
//  The editor's waveform: cue points along the top, the loop region under
//  them, the song under that - one strip that scrolls as a piece.
//
//  Three rows, one Canvas. Drawing them separately would mean keeping three
//  scroll offsets in step, and a cue flag a pixel off the line it marks is
//  worse than no flag. So the rows are bands of one picture and one gesture
//  dispatches by the y it started at.
//
//  A fixed span - one of four, rather than a free zoom and a Fit that could
//  put the view past the end of the song. The scroll view holds nothing but a
//  spacer of the full width; the drawing is one viewport wide and pushed back
//  by the scroll offset (`TimelinePanel` explains why, and why every pointer
//  modifier has to come before that offset).
//
//  Close in the waveform is drawn from the samples, because the grid is judged
//  to the millisecond; from `pyramidFrom` frames per pixel on, from the
//  overview instead.
//

import SwiftUI
import AppKit

/// Seconds to pixels, and where the three rows sit.
struct StripLayout {
    var pixelsPerSecond: Double
    var scrollX: CGFloat
    var size: CGSize

    /// A little air before the first sample, so a cue on 0 s is grabbable.
    static let pad: CGFloat = 10
    static let cueHeight: CGFloat = 18
    static let loopHeight: CGFloat = 13
    /// How near a region edge counts as grabbing it.
    static let grab: CGFloat = 6

    var waveTop: CGFloat { Self.cueHeight + Self.loopHeight }
    var waveHeight: CGFloat { max(10, size.height - waveTop) }

    func x(_ seconds: Double) -> CGFloat { CGFloat(seconds * pixelsPerSecond) + Self.pad - scrollX }
    func seconds(_ x: CGFloat) -> Double { Double(x - Self.pad + scrollX) / max(pixelsPerSecond, 0.0001) }

    var visible: ClosedRange<Double> { seconds(0)...seconds(size.width) }

    static func contentWidth(duration: Double, pixelsPerSecond: Double, viewport: CGFloat) -> CGFloat {
        max(viewport, CGFloat(duration * pixelsPerSecond) + 2 * pad)
    }
}

struct BeatgridStrip: View {
    let audio: AudioFrames?
    let waveform: Waveform?
    let preview: PreviewPlayer
    let trackID: UUID
    let grid: SourceGrid
    let onsets: [Double]
    let cues: [CuePoint]
    let selectedLine: Int
    let region: LoopRegion?
    let accent: Color
    /// Pixels per second, from the span the editor is set to. Not a binding
    /// any more: nothing in the strip changes the scale.
    let pixelsPerSecond: Double
    /// How wide the strip is, for the editor's Fit button.
    @Binding var viewportWidth: CGFloat
    /// A spot the editor wants on screen - a cue jumped to, a selection
    /// moved with the arrow keys. Cleared once it is shown.
    @Binding var showSeconds: Double?
    /// What is on screen, for the fit bar's outline.
    @Binding var visibleRange: ClosedRange<Double>

    /// A gridline was chosen.
    let onSelect: (Int) -> Void
    /// ⌥-click: bar one goes here.
    let onPick: (Double) -> Void
    /// The marked stretch changed; nil clears it.
    let onRegion: (LoopRegion?) -> Void
    /// A cue was dragged to another spot.
    let onMoveCue: (Int, Double) -> Void
    /// A cue flag was clicked - go there.
    let onGoToCue: (CuePoint) -> Void

    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var drag: Drag?
    @State private var draft: LoopRegion?

    /// What the pointer took hold of when it went down.
    private enum Drag: Equatable {
        case mark(anchor: Double)
        case edge(fixed: Double)
        case move(grab: Double, length: Double)
        case cue(number: Int)
        /// The pointer went down where nothing can be grabbed.
        case ignore
    }

    /// Where the drawing gives up the samples for the overview: a pixel
    /// covering more than this many frames (about 6 ms) is past what the
    /// finest pyramid level would show anyway.
    static let pyramidFrom = 256.0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let layout = StripLayout(pixelsPerSecond: pixelsPerSecond, scrollX: scrollX, size: geometry.size)
                ScrollView(.horizontal) {
                    Color.clear
                        .frame(width: StripLayout.contentWidth(duration: grid.durationSeconds,
                                                               pixelsPerSecond: pixelsPerSecond,
                                                               viewport: geometry.size.width),
                               height: geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                Canvas { context, size in
                                    draw(&context, StripLayout(pixelsPerSecond: pixelsPerSecond, scrollX: scrollX,
                                                               size: size))
                                }
                                playhead(layout)
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            // Before the offset, always: a modifier after it
                            // works in the un-scrolled frame and every
                            // location arrives shifted by the scroll.
                            .contentShape(Rectangle())
                            .gesture(pointer(layout))
                            .offset(x: scrollX)
                        }
                }
                .scrollIndicators(.never)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                    scrollX = x
                    report(scrollX: x, pixelsPerSecond: pixelsPerSecond, width: geometry.size.width)
                }
                .onAppear {
                    viewportWidth = geometry.size.width
                    report(scrollX: scrollX, pixelsPerSecond: pixelsPerSecond, width: geometry.size.width)
                }
                .onChange(of: geometry.size.width) { _, width in
                    viewportWidth = width
                    report(scrollX: scrollX, pixelsPerSecond: pixelsPerSecond, width: width)
                }
                .onChange(of: pixelsPerSecond) { old, new in
                    keepInPlace(old: old, new: new, width: geometry.size.width)
                    report(scrollX: scrollX, pixelsPerSecond: new, width: geometry.size.width)
                }
                .onChange(of: showSeconds) { _, seconds in
                    guard let seconds else { return }
                    show(seconds, width: geometry.size.width)
                    showSeconds = nil
                }
            }
            .background(Color(white: 0.12))
            .help("Click a gridline to play from it · ⌥-click a kick to put bar one there · drag to mark a stretch")
            TimelineScrollbar(
                scrollX: scrollX,
                contentWidth: StripLayout.contentWidth(duration: grid.durationSeconds,
                                                       pixelsPerSecond: pixelsPerSecond, viewport: viewportWidth),
                viewportWidth: viewportWidth
            ) { x in
                scrollPosition.scrollTo(x: x)
            }
        }
    }

    private func report(scrollX: CGFloat, pixelsPerSecond: Double, width: CGFloat) {
        let layout = StripLayout(pixelsPerSecond: pixelsPerSecond, scrollX: scrollX,
                                 size: CGSize(width: width, height: 1))
        visibleRange = layout.visible
    }

    /// Puts `seconds` on screen when it is not - after a jump to a cue, or a
    /// selection moved with the arrow keys. Already in sight, nothing moves:
    /// a scroll that was not asked for loses the place being worked on.
    private func show(_ seconds: Double, width: CGFloat) {
        let x = CGFloat(seconds * pixelsPerSecond) + StripLayout.pad
        guard width > 0 else { return }
        if x < scrollX + 20 || x > scrollX + width - 20 {
            scrollPosition.scrollTo(x: max(0, x - width / 3))
        }
    }

    // MARK: - Playhead

    private func playhead(_ layout: StripLayout) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let playing = preview.isPlaying && preview.trackID == trackID
            let t = preview.positionSeconds - preview.outputLatency
            let x = layout.x(t)
            let turnPage = playing && (x > layout.size.width * 0.88 || x < 0)
            Canvas { context, size in
                guard preview.trackID == trackID, x >= -2, x <= size.width + 2 else { return }
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white), lineWidth: 1.2)
            }
            .allowsHitTesting(false)
            .onChange(of: turnPage) { _, turn in
                guard turn else { return }
                scrollPosition.scrollTo(x: max(0, CGFloat(t * pixelsPerSecond) + StripLayout.pad
                                               - layout.size.width * 0.1))
            }
        }
    }

    // MARK: - Span

    /// A new span holds the playhead where it is on screen, or the middle of the
    /// view when it is not in sight: the spot being looked at is the spot
    /// being zoomed into.
    private func keepInPlace(old: Double, new: Double, width: CGFloat) {
        let played = preview.trackID == trackID ? preview.positionSeconds - preview.outputLatency : -1
        let playedX = CGFloat(played * old) + StripLayout.pad - scrollX
        let anchorX: CGFloat
        let anchorSeconds: Double
        if played >= 0, playedX >= 0, playedX <= width {
            anchorX = playedX
            anchorSeconds = played
        } else {
            anchorX = width / 2
            anchorSeconds = Double(scrollX + width / 2 - StripLayout.pad) / old
        }
        scrollPosition.scrollTo(x: max(0, CGFloat(anchorSeconds * new) + StripLayout.pad - anchorX))
    }

    // MARK: - Pointer

    private func pointer(_ layout: StripLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil { drag = classify(value.startLocation, layout) }
                let free = NSEvent.modifierFlags.contains(.option)
                let here = snap(layout.seconds(value.location.x), free: free)
                switch drag {
                case .mark(let anchor):
                    draft = LoopRegion(from: anchor, to: here).clamped(to: grid.durationSeconds)
                case .edge(let fixed):
                    draft = LoopRegion(from: fixed, to: here).clamped(to: grid.durationSeconds)
                case .move(let grab, let length):
                    let start = max(0, min(here - grab, grid.durationSeconds - length))
                    draft = LoopRegion(from: start, to: start + length)
                case .cue, .ignore, nil:
                    break
                }
            }
            .onEnded { value in
                let free = NSEvent.modifierFlags.contains(.option)
                let moved = abs(value.translation.width) + abs(value.translation.height)
                let here = layout.seconds(value.location.x)
                defer { drag = nil; draft = nil }
                if moved < 3 {
                    click(value.startLocation, at: here, free: free, layout)
                    return
                }
                switch drag {
                case .cue(let number):
                    onMoveCue(number, max(0, min(snap(here, free: free), grid.durationSeconds)))
                case .mark, .edge, .move:
                    if let draft, draft.lengthSeconds > 1e-6 { onRegion(draft) }
                case .ignore, nil:
                    break
                }
            }
    }

    private func classify(_ start: CGPoint, _ layout: StripLayout) -> Drag {
        if start.y < StripLayout.cueHeight {
            if let cue = cue(near: start.x, layout) { return .cue(number: cue.number) }
            return .ignore
        }
        if let region {
            let startX = layout.x(region.startSeconds)
            let endX = layout.x(region.endSeconds)
            if abs(start.x - startX) <= StripLayout.grab { return .edge(fixed: region.endSeconds) }
            if abs(start.x - endX) <= StripLayout.grab { return .edge(fixed: region.startSeconds) }
            if start.y < layout.waveTop, start.x > startX, start.x < endX {
                return .move(grab: layout.seconds(start.x) - region.startSeconds, length: region.lengthSeconds)
            }
        }
        return .mark(anchor: snap(layout.seconds(start.x), free: NSEvent.modifierFlags.contains(.option)))
    }

    private func click(_ start: CGPoint, at seconds: Double, free: Bool, _ layout: StripLayout) {
        if start.y < StripLayout.cueHeight {
            if let cue = cue(near: start.x, layout) { onGoToCue(cue) }
            return
        }
        if start.y < layout.waveTop {
            // A click on the empty loop bar takes the mark away; there is
            // nothing else it could mean, and a stray mark blocks the loop
            // buttons.
            onRegion(nil)
            return
        }
        if free {
            onPick(seconds)
        } else {
            onSelect(BeatLines.nearestLine(to: seconds, bpm: grid.bpm, firstBeat: grid.firstBeatSeconds))
        }
    }

    private func cue(near x: CGFloat, _ layout: StripLayout) -> CuePoint? {
        cues.min { abs(layout.x($0.seconds) - x) < abs(layout.x($1.seconds) - x) }
            .flatMap { abs(layout.x($0.seconds) - x) <= 10 ? $0 : nil }
    }

    /// On the nearest gridline, unless ⌥ asks for the spot itself. A loop
    /// becomes a clip in whole beats anyway; snapping is what makes the
    /// picture agree with what will be heard.
    private func snap(_ seconds: Double, free: Bool) -> Double {
        guard !free else { return max(0, min(seconds, grid.durationSeconds)) }
        let beat = 60 / max(grid.bpm, 1)
        let line = grid.firstBeatSeconds + ((seconds - grid.firstBeatSeconds) / beat).rounded() * beat
        return max(0, min(line, grid.durationSeconds))
    }

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, _ layout: StripLayout) {
        let shown = draft ?? region
        context.fill(Path(CGRect(x: 0, y: 0, width: layout.size.width, height: StripLayout.cueHeight)),
                     with: .color(Color(white: 0.17)))
        context.fill(Path(CGRect(x: 0, y: StripLayout.cueHeight, width: layout.size.width,
                                 height: StripLayout.loopHeight)),
                     with: .color(Color(white: 0.22)))
        wave(&context, layout)
        lines(&context, layout)
        ticks(&context, layout)
        if let shown { mark(&context, layout, shown) }
        selection(&context, layout)
        flags(&context, layout)
    }

    private func wave(_ context: inout GraphicsContext, _ layout: StripLayout) {
        let rate = AudioFrames.sampleRate
        let framesPerPixel = rate / max(layout.pixelsPerSecond, 0.0001)
        let middle = layout.waveTop + layout.waveHeight / 2
        let half = layout.waveHeight / 2 * 0.95
        let color = Color(red: 0.45, green: 0.75, blue: 1.0)
        if let waveform, framesPerPixel >= Self.pyramidFrom || Double(waveform.framesPerBucket) <= framesPerPixel {
            var levelIndex = 0
            while levelIndex + 1 < waveform.levels.count,
                  Double(waveform.framesPerBucket << (levelIndex + 1)) <= framesPerPixel {
                levelIndex += 1
            }
            let level = waveform.levels[levelIndex]
            let bucketFrames = Double(waveform.framesPerBucket << levelIndex)
            var peaks = Path()
            var body = Path()
            var x: CGFloat = 0
            while x < layout.size.width {
                let i0 = max(0, Int(layout.seconds(x) * rate / bucketFrames))
                let i1 = min(level.count - 1, Int(layout.seconds(x + 1) * rate / bucketFrames))
                if i0 <= i1 {
                    var high: Float = 0, low: Float = 0, rms: Float = 0
                    for i in i0...i1 {
                        high = max(high, level.maxL[i], level.maxR[i])
                        low = min(low, level.minL[i], level.minR[i])
                        rms = max(rms, level.rmsL[i], level.rmsR[i])
                    }
                    peaks.addRect(CGRect(x: x, y: middle - CGFloat(high) * half, width: 1,
                                         height: max(1, CGFloat(high - low) * half)))
                    body.addRect(CGRect(x: x, y: middle - CGFloat(rms) * half, width: 1,
                                        height: max(1, CGFloat(2 * rms) * half)))
                }
                x += 1
            }
            context.fill(peaks, with: .color(color.opacity(0.5)))
            context.fill(body, with: .color(color))
            return
        }
        guard let audio else { return }
        var shape = Path()
        var x: CGFloat = 0
        while x < layout.size.width {
            let f0 = Int((layout.seconds(x) * rate).rounded(.down))
            let f1 = min(audio.frameCount, Int((layout.seconds(x + 1) * rate).rounded(.down)) + 1)
            if f0 >= 0, f0 < f1 {
                var high: Float = 0, low: Float = 0
                for f in f0..<f1 {
                    let v = (audio.samples[2 * f] + audio.samples[2 * f + 1]) * 0.5
                    high = max(high, v)
                    low = min(low, v)
                }
                shape.addRect(CGRect(x: x, y: middle - CGFloat(high) * half, width: 1,
                                     height: max(1, CGFloat(high - low) * half)))
            }
            x += 1
        }
        context.fill(shape, with: .color(color))
    }

    /// The grid. Beat lines are left out once they are closer together than
    /// three pixels - at a whole song on one screen they would be a wash of
    /// grey over the waveform - and the bar lines thin out the same way.
    private func lines(_ context: inout GraphicsContext, _ layout: StripLayout) {
        let beat = 60 / max(grid.bpm, 1)
        let spacing = beat * layout.pixelsPerSecond
        // Only over the song: past its end a grid marks nothing. The
        // clamping and the emptiness are BeatLines' business (see there:
        // doing it here cost four crashes).
        guard let indices = BeatLines.indices(from: layout.visible.lowerBound, to: layout.visible.upperBound,
                                              bpm: grid.bpm, firstBeat: grid.firstBeatSeconds,
                                              duration: grid.durationSeconds) else { return }
        let (firstIndex, lastIndex) = (indices.lowerBound, indices.upperBound)
        // Beat lines go first as the song is zoomed out: at a dozen pixels
        // apart they stop telling the beats apart and start striping the
        // waveform. The bar lines hold on to four pixels, because the bar
        // numbers are what a whole song is read by.
        let showBeats = spacing >= 12
        let showBars = spacing * 4 >= 4
        guard showBars else { return }
        for k in firstIndex...lastIndex {
            let downbeat = ((k % 4) + 4) % 4 == 0
            guard downbeat || showBeats else { continue }
            let x = layout.x(BeatLines.time(ofLine: k, bpm: grid.bpm, firstBeat: grid.firstBeatSeconds))
            var line = Path()
            line.move(to: CGPoint(x: x, y: layout.waveTop))
            line.addLine(to: CGPoint(x: x, y: layout.size.height))
            let color: Color = k == 0 ? .orange : downbeat ? .white.opacity(0.8) : .white.opacity(0.3)
            context.stroke(line, with: .color(color), lineWidth: downbeat ? 1.6 : 1)
            if downbeat, spacing * 4 >= 26 {
                let bar = k / 4 + (k < 0 ? 0 : 1)
                context.draw(Text("\(bar)").font(.system(size: 10, weight: .semibold)).foregroundStyle(color),
                             at: CGPoint(x: x + 3, y: layout.waveTop + 2), anchor: .topLeading)
            }
        }
    }

    private func ticks(_ context: inout GraphicsContext, _ layout: StripLayout) {
        let visible = layout.visible
        var ticks = Path()
        for t in onsets where visible.contains(t) {
            ticks.addRect(CGRect(x: layout.x(t) - 0.75, y: layout.size.height - 11, width: 1.5, height: 9))
        }
        context.fill(ticks, with: .color(Color(red: 1.0, green: 0.4, blue: 0.5)))
    }

    private func mark(_ context: inout GraphicsContext, _ layout: StripLayout, _ region: LoopRegion) {
        let x0 = layout.x(region.startSeconds)
        let x1 = layout.x(region.endSeconds)
        guard x1 > x0 - 1 else { return }
        let whole = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: layout.size.height)
        context.fill(Path(whole), with: .color(accent.opacity(0.16)))
        let bar = CGRect(x: x0, y: StripLayout.cueHeight, width: max(2, x1 - x0), height: StripLayout.loopHeight)
        context.fill(Path(bar), with: .color(accent.opacity(0.75)))
        for x in [x0, x1] {
            context.fill(Path(CGRect(x: x - 1.5, y: StripLayout.cueHeight - 1, width: 3,
                                     height: StripLayout.loopHeight + 2)), with: .color(accent))
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: layout.size.height))
            context.stroke(line, with: .color(accent), lineWidth: 1)
        }
    }

    private func selection(_ context: inout GraphicsContext, _ layout: StripLayout) {
        let x = layout.x(BeatLines.time(ofLine: selectedLine, bpm: grid.bpm, firstBeat: grid.firstBeatSeconds))
        guard x >= -6, x <= layout.size.width + 6 else { return }
        var line = Path()
        line.move(to: CGPoint(x: x, y: layout.waveTop))
        line.addLine(to: CGPoint(x: x, y: layout.size.height))
        context.stroke(line, with: .color(.yellow), lineWidth: 2)
        var flag = Path()
        flag.move(to: CGPoint(x: x - 6, y: layout.waveTop))
        flag.addLine(to: CGPoint(x: x + 6, y: layout.waveTop))
        flag.addLine(to: CGPoint(x: x, y: layout.waveTop + 8))
        flag.closeSubpath()
        context.fill(flag, with: .color(.yellow))
    }

    /// The cue flags: a numbered tab in the top band and a thin line down
    /// through the song, so a cue can be read against the waveform.
    private func flags(_ context: inout GraphicsContext, _ layout: StripLayout) {
        for cue in cues {
            let x = layout.x(cue.seconds)
            guard x >= -14, x <= layout.size.width + 14 else { continue }
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: layout.size.height))
            context.stroke(line, with: .color(Color(red: 0.35, green: 0.95, blue: 0.65).opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let tab = CGRect(x: x, y: 1, width: 15, height: StripLayout.cueHeight - 3)
            context.fill(Path(roundedRect: tab, cornerRadius: 3),
                         with: .color(Color(red: 0.2, green: 0.75, blue: 0.5)))
            context.draw(Text("\(cue.number)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white),
                         at: CGPoint(x: tab.midX, y: tab.midY), anchor: .center)
        }
    }
}
