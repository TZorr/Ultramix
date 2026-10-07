//
//  TimelinePanel.swift
//  Ultramix
//
//  The timeline view: lane headers on the left, and the scrolling timeline - a
//  Canvas pinned to the viewport inside a horizontal ScrollView, so the system
//  provides the scrolling while the drawing only covers what is on screen.
//
//  Every pointer interaction is one DragGesture that decides, when it starts,
//  what it has hold of: the ruler (scrub), a transition bar (an end, or the
//  whole; in empty strip a new one), a tempo point (up and down for the
//  tempo, ⌥ for its position), a clip edge (trim, or extend a loop), a clip
//  body (move, with everything else selected, across lanes too), an automation
//  node, or empty lane. The decision is made once, from where the pointer went
//  down, so a drag cannot change its mind half way.
//
//  The playhead moves only when it is put somewhere on purpose: a click in
//  empty lane, the ruler, Home.
//
//  The mouse wheel zooms around the pointer (WheelZoom). A horizontal
//  ScrollView has no use for vertical wheel deltas, so they are taken from
//  the event stream before it sees them - only while the pointer is over the
//  timeline and no drag is under way; ⇧ (scroll sideways) and ⌃ (the
//  system's zoom) pass through, and so does a sideways trackpad swipe.
//
//
//  A drag is one undo step, recorded when it actually starts moving something,
//  not on mouse-down: a click that selects a clip must not leave an empty step
//  on the undo stack.
//

import SwiftUI
import AppKit

struct TimelinePanel: View {
    let session: MixSession
    let library: Library
    @Binding var pixelsPerBeat: Double
    let follow: Bool
    let tool: TimelineTool
    let drawStyle: DrawStyle
    let period: Double

    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    /// The live set's lane order as it was when a drag began, held until
    /// it ends: dragging a clip past another would otherwise reorder the
    /// rows under the pointer, and the clip would jump lanes.
    @State private var heldOrder: [Int]?
    @State private var viewportWidth: CGFloat = 800
    @State private var drag: DragState?
    @State private var draft: DraftGesture?
    @State private var automationSelection: AutomationSelection?
    @State private var marquee: CGRect?
    /// A transition bar being drawn in the strip, in timeline beats.
    @State private var draftMark: ClosedRange<Double>?
    /// The bar under the pointer, for the right-click menu.
    @State private var hoveredMark: MarkRef?
    /// The clip under the pointer, for the context menu.
    @State private var hoveredClip: UUID?
    @State private var zoomBase: Double?
    /// The wheel's state - a reference, so that tracking the pointer does not
    /// redraw the timeline on every move.
    @State private var wheel = WheelState()
    @FocusState private var focused: Bool
    @Environment(\.accent) private var accent

    /// Wide enough for the lane's name, M/S and its two knobs side by side -
    /// under each other they would need twice the lowest lane height.
    static let headerWidth: CGFloat = 180

    private final class WheelState {
        /// Where the pointer is over the timeline, in view coordinates; nil
        /// when it is elsewhere.
        var pointer: CGPoint?
        var monitor: Any?
        /// The beat under the pointer, held between quick wheel events.
        var anchor: (beat: Double, point: CGPoint, time: Date)?
        /// Set just before a wheel zoom, taken by the zoom's onChange.
        var pending: (beat: Double, x: CGFloat)?
    }

    private enum DragState {
        case scrub
        case pendingClip(id: UUID, grab: Double)
        case moveClip(id: UUID, grab: Double)
        case trim(id: UUID, edge: ClipEdge, started: Bool)
        case tempo(id: UUID, origin: Double, startY: CGFloat, started: Bool)
        case tempoAnchor(id: UUID)
        /// Dragging any tempo point while the master tempo is locked: they
        /// all sit on the master, so the drag moves the master.
        case master(origin: Double, startY: CGFloat, started: Bool)
        /// Dragging the diamond where a clip's tempo ramp begins. `started`
        /// once the drag has recorded its undo step.
        case rampStart(id: UUID, started: Bool)
        /// Automation states carry the row they are in: the clip's own
        /// (`part` nil) or a stem's, in an expanded lane.
        case node(clip: UUID, lane: Int, part: Stem?, kind: AutomationKind, node: AutomationNode)
        /// Dragging out a gesture on `clip`, from timeline beat `start`.
        case draw(clip: UUID, lane: Int, part: Stem?, kind: AutomationKind, start: Double, startValue: Double)
        /// Pressed in empty space: a click places a node at `beat` on `clip`
        /// - outside every clip, nil, and a click does nothing - and a drag
        /// becomes a selection rectangle.
        case pendingNode(clip: UUID?, lane: Int, part: Stem?, kind: AutomationKind, beat: Double, value: Double)
        /// A rectangle stays in the row it began in; in a stem's, in its lane.
        case marquee(kind: AutomationKind, lane: Int, part: Stem?, origin: CGPoint)
        /// Pressed in empty transition strip: a drag draws a bar from `start`.
        case newMark(start: Double)
        /// Dragging one end of a bar; `fixed` is the other end.
        case markEdge(ref: MarkRef, edge: ClipEdge, fixed: Double, started: Bool)
        /// Dragging a whole bar, held `grab` beats from its start.
        case markMove(ref: MarkRef, grab: Double, length: Double, started: Bool)
        /// Pressed in empty lane with the clip tool: a click seeks there, a
        /// drag does nothing - no rectangle, no scrolling.
        case emptyLane
        case nothing
    }

    var body: some View {
        HStack(spacing: 0) {
            LaneHeaders(session: session, order: heldOrder ?? session.laneOrder)
                .frame(width: Self.headerWidth)
            Divider()
            VStack(spacing: 0) {
            GeometryReader { geometry in
                let layout = TimelineLayout(pixelsPerBeat: pixelsPerBeat, scrollX: scrollX, size: geometry.size,
                                            laneOrder: heldOrder ?? session.laneOrder, expanded: session.expandedLanes)
                let snapshot = TimelineSnapshot(session: session, library: library, tool: tool, draft: draft,
                                                selection: automationSelection, marquee: marquee,
                                                accent: accent, draftMark: draftMark)
                ScrollView(.horizontal) {
                    Color.clear
                        .frame(width: TimelineLayout.contentWidth(endBeat: session.endBeat, pixelsPerBeat: pixelsPerBeat,
                                                                  viewport: geometry.size.width),
                               height: geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            ZStack(alignment: .topLeading) {
                                Canvas { context, size in
                                    TimelineDrawing.draw(&context, size: size, snapshot: snapshot, layout: layout)
                                }
                                PlayheadOverlay(session: session, layout: layout, follow: follow,
                                                accent: accent) { target in
                                    scrollPosition.scrollTo(x: target)
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            // Every pointer modifier goes *before* the
                            // offset: one after `.offset` works in the
                            // view's un-offset frame, so locations arrive
                            // shifted by the scroll distance and points
                            // land that far right of the pointer.
                            .contentShape(Rectangle())
                            .gesture(dragGesture(layout, snapshot))
                            .simultaneousGesture(magnifyGesture)
                            .onContinuousHover { phase in hover(phase, layout, snapshot) }
                            .contextMenu { canvasMenu }
                            .dropDestination(for: String.self) { items, location in
                                drop(items, at: location, layout)
                            }
                            .offset(x: scrollX)
                        }
                }
                // The system's own scroller is an overlay that comes and goes;
                // TimelineScrollbar below is the one that stays.
                .scrollIndicators(.never)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                    scrollX = x
                }
                .onAppear { viewportWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in viewportWidth = width }
                .onChange(of: pixelsPerBeat) { old, new in
                    if let anchor = wheel.pending {
                        wheel.pending = nil
                        scrollPosition.scrollTo(x: CGFloat(WheelZoom.scrollX(
                            keeping: anchor.beat, at: Double(anchor.x), pixelsPerBeat: new,
                            leadingPad: Double(TimelineLayout.leadingPad))))
                    } else {
                        keepPlayheadInPlace(old: old, new: new, width: geometry.size.width)
                    }
                }
                // The live set moved back by whole bars (see LiveSet); scroll
                // back by as much, so what is on screen stays where it was.
                .onChange(of: session.liveShift) { old, new in
                    scrollPosition.scrollTo(x: max(0, scrollX - CGFloat(Double(new - old) * pixelsPerBeat)))
                }
            }
            Divider()
            TimelineScrollbar(
                scrollX: scrollX,
                contentWidth: TimelineLayout.contentWidth(endBeat: session.endBeat, pixelsPerBeat: pixelsPerBeat,
                                                          viewport: viewportWidth),
                viewportWidth: viewportWidth
            ) { x in
                scrollPosition.scrollTo(x: x)
            }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            guard wheel.monitor == nil else { return }
            // Local monitors are called on the main thread, as the view is.
            wheel.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                wheelZoom(event)
            }
        }
        .onDisappear {
            if let monitor = wheel.monitor { NSEvent.removeMonitor(monitor) }
            wheel.monitor = nil
            wheel.pointer = nil
        }
        .onKeyPress(.space) {
            session.togglePlay()
            return .handled
        }
        // ⌫ arrives as U+007F while `.delete` is U+0008, so it never
        // matches on its own; ⌦ (U+F728) matches `.deleteForward`.
        .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { press in
            // A picked transition bar goes first: picking it let go of the clips.
            if session.selectedMark != nil {
                session.removeSelectedMark()
                return .handled
            }
            return press.modifiers.contains(.option) ? deleteClipAutomation() : deleteSelected()
        }
        .onKeyPress(.home) {
            session.seek(toBeat: 0)
            return .handled
        }
        .onKeyPress(keys: [.tab]) { press in cycleTool(press.modifiers.contains(.shift) ? -1 : 1) }
        .onKeyPress(characters: CharacterSet(charactersIn: "+-"), phases: [.down, .repeat]) { press in
            zoomStep(press.characters == "+" ? 1.5 : 1 / 1.5)
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let direction = press.key == .leftArrow ? -1 : 1
            if press.modifiers.contains(.option) { return nudge(direction) }
            return scroll(direction, page: press.modifiers.contains(.shift))
        }
        .onChange(of: tool) {
            automationSelection = nil
            marquee = nil
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "bBlLmMeE"), phases: .down) { press in
            switch press.characters.lowercased() {
            case "b": session.splitSelection(atBeat: session.playheadBeat())
            case "e": session.toggleBeatgrid()
            case "l": session.toggleLoopSelection()
            case "m": session.toggleMuteSelection()
            default: return .ignored
            }
            return .handled
        }
    }

    /// Delete removes what the current tool has selected: automation in an
    /// automation tool, clips in the clip tool - never clips from an
    /// automation tool, where the selection on screen is a set of points. A
    /// clip goes with the automation drawn on it.
    private func deleteSelected() -> KeyPress.Result {
        if tool.kind != nil {
            guard let selection = automationSelection, !selection.isEmpty else { return .ignored }
            session.deleteAutomation(selection)
            automationSelection = nil
            return .handled
        }
        guard !session.selection.isEmpty else { return .ignored }
        session.deleteSelection()
        return .handled
    }

    /// ⌥⌫ in the clip tool deletes the automation drawn on the selected
    /// clips and keeps the clips - with nothing selected it does nothing. In
    /// an automation tool it is plain Delete, as it always was.
    private func deleteClipAutomation() -> KeyPress.Result {
        guard tool.kind == nil else { return deleteSelected() }
        guard !session.selection.isEmpty else { return .ignored }
        session.deleteSelectionAutomation()
        return .handled
    }

    /// + and − zoom by the zoom buttons' step; holding repeats. Matched by
    /// character, not key code, so the keys beside the letters work too. The
    /// playhead stays where it is on screen.
    private func zoomStep(_ factor: Double) -> KeyPress.Result {
        pixelsPerBeat = min(max(pixelsPerBeat * factor, TransportBar.zoomRange.lowerBound),
                            TransportBar.zoomRange.upperBound)
        return .handled
    }

    /// Tab steps to the next tool and ⇧Tab to the previous. Handled here so
    /// the key never reaches focus navigation; not a menu key, where it
    /// would take Tab from every text field in the window.
    private func cycleTool(_ step: Int) -> KeyPress.Result {
        let tools = TimelineTool.allCases
        let current = tools.firstIndex(of: tool) ?? 0
        session.tool = tools[(current + step + tools.count) % tools.count]
        return .handled
    }

    /// ⌥← / ⌥→ move the selected clips a beat, in the clip tool. With
    /// nothing to move they do nothing - not even scroll, so ⌥ always means
    /// an edit.
    private func nudge(_ direction: Int) -> KeyPress.Result {
        if tool == .clips, !session.selection.isEmpty {
            session.nudgeSelection(byBeats: direction)
        }
        return .handled
    }

    /// ← / → scroll the timeline, whatever is selected: an eighth of the
    /// view per press, a whole view with ⇧, never past either end. Holding
    /// the key repeats.
    private func scroll(_ direction: Int, page: Bool) -> KeyPress.Result {
        let content = TimelineLayout.contentWidth(endBeat: session.endBeat, pixelsPerBeat: pixelsPerBeat,
                                                  viewport: viewportWidth)
        let step = viewportWidth * (page ? 1 : 0.125) * CGFloat(direction)
        let target = min(max(0, scrollX + step), max(0, content - viewportWidth))
        guard target != scrollX else { return .handled }
        scrollPosition.scrollTo(x: target)
        return .handled
    }

    // MARK: - Zoom

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomBase ?? pixelsPerBeat
                if zoomBase == nil { zoomBase = pixelsPerBeat }
                pixelsPerBeat = min(max(base * value.magnification, TransportBar.zoomRange.lowerBound),
                                    TransportBar.zoomRange.upperBound)
            }
            .onEnded { _ in zoomBase = nil }
    }

    /// A wheel event over the timeline zooms around the pointer and goes no
    /// further; anything else is handed on untouched.
    private func wheelZoom(_ event: NSEvent) -> NSEvent? {
        guard let point = wheel.pointer, drag == nil else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.shift), !modifiers.contains(.control),
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
        // The glide after a flick on a trackpad or Magic Mouse would carry
        // the zoom on long after the fingers left: swallowed instead.
        guard event.momentumPhase.isEmpty else { return nil }
        let factor = WheelZoom.factor(deltaY: Double(event.scrollingDeltaY),
                                      precise: event.hasPreciseScrollingDeltas,
                                      inverted: event.isDirectionInvertedFromDevice)
        let zoomed = min(max(pixelsPerBeat * factor, TransportBar.zoomRange.lowerBound),
                         TransportBar.zoomRange.upperBound)
        guard zoomed != pixelsPerBeat else { return nil }
        let now = Date()
        let beat: Double
        if let held = wheel.anchor, now.timeIntervalSince(held.time) < WheelZoom.anchorHold,
           abs(held.point.x - point.x) <= 1, abs(held.point.y - point.y) <= 1 {
            beat = held.beat
        } else {
            beat = Double(point.x + scrollX - TimelineLayout.leadingPad) / pixelsPerBeat
        }
        wheel.anchor = (beat, point, now)
        wheel.pending = (beat, point.x)
        pixelsPerBeat = zoomed
        return nil
    }

    /// Zoom keeps the playhead where it is on screen - or, when the playhead
    /// is out of view, the middle of the view - so zooming never throws away
    /// the place being looked at.
    private func keepPlayheadInPlace(old: Double, new: Double, width: CGFloat) {
        let playhead = session.playheadBeat()
        let playheadX = CGFloat(playhead * old) + TimelineLayout.leadingPad - scrollX
        let anchorX: CGFloat
        let anchorBeat: Double
        if playheadX >= 0 && playheadX <= width {
            anchorX = playheadX
            anchorBeat = playhead
        } else {
            anchorX = width / 2
            anchorBeat = Double(scrollX + width / 2 - TimelineLayout.leadingPad) / old
        }
        let target = CGFloat(anchorBeat * new) + TimelineLayout.leadingPad - anchorX
        scrollPosition.scrollTo(x: max(0, target))
    }

    // MARK: - Pointer

    private func dragGesture(_ layout: TimelineLayout, _ snapshot: TimelineSnapshot) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    focused = true
                    heldOrder = layout.laneOrder
                    drag = begin(at: value.startLocation, layout, snapshot)
                }
                update(value, layout, snapshot)
            }
            .onEnded { value in
                finish(value, layout)
                drag = nil
                heldOrder = nil
            }
    }

    private func begin(at p: CGPoint, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) -> DragState {
        let modifiers = NSEvent.modifierFlags
        if p.y < TimelineLayout.rulerHeight {
            session.seek(toBeat: max(0, layout.beat(p.x)))
            return .scrub
        }
        if layout.transitionRect.contains(p) {
            return beginMark(at: p, layout, snapshot)
        }
        if layout.tempoRect.contains(p) {
            // DragGesture has no click count; the mouse-down that starts it
            // is still AppKit's current event, and that one does.
            let doubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2
            // Under a locked master only the up-and-down drag means
            // anything; the points' own tempo, place and ramp are not heard.
            if let master = snapshot.master {
                guard let clip = tempoPoint(near: p.x, layout, snapshot) else { return .nothing }
                session.selection = [clip.id]
                return .master(origin: master, startY: p.y, started: false)
            }
            if let clip = tempoPoint(near: p.x, layout, snapshot) {
                session.selection = [clip.id]
                if doubleClick {
                    // Back to the track's own tempo at this point.
                    session.perform { $0.setTargetBPM(clip.id, nil) }
                    return .nothing
                }
                if modifiers.contains(.option) {
                    session.beginGesture()
                    return .tempoAnchor(id: clip.id)
                }
                return .tempo(id: clip.id, origin: clip.targetBPM ?? clip.sourceBPM, startY: p.y, started: false)
            }
            if let clip = rampHandle(near: p.x, layout, snapshot) {
                session.selection = [clip.id]
                if doubleClick {
                    session.perform { $0.removeRampStart(clip.id) }
                    return .nothing
                }
                return .rampStart(id: clip.id, started: false)
            }
            // A click in the strip starts the ramp into the next tempo point
            // to its right, there; holding on drags it.
            let beat = layout.beat(p.x)
            guard let clip = nextTempoPoint(after: beat, snapshot) else { return .nothing }
            session.selection = [clip.id]
            session.perform { $0.setRampStart(clip.id, to: beat) }
            return .rampStart(id: clip.id, started: true)
        }
        guard let lane = layout.lane(atY: p.y) else { return .nothing }
        session.selectedMark = nil
        let beat = layout.beat(p.x)
        // A press in the stem rows of a clip whose song is not separated
        // separates it - in any tool: there is nothing in those rows yet to
        // draw on or pick.
        if layout.part(atY: p.y, lane: lane) != nil, let clip = clipHit(at: p, lane: lane, layout, snapshot),
           !clip.separated {
            if clip.separating == nil { library.separate([clip.trackID]) }
            return .nothing
        }
        if let kind = tool.kind {
            return beginAutomation(lane: lane, kind: kind, beat: beat, at: p, modifiers: modifiers, layout, snapshot)
        }
        if let clip = clipHit(at: p, lane: lane, layout, snapshot) {
            // A double-click opens the clip's beatgrid before trimming or
            // moving can take the press, so it leaves no undo step.
            // DragGesture has no click count; AppKit's current event does.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2, !modifiers.contains(.shift),
               let trackID = session.document.clips.first(where: { $0.id == clip.id })?.trackID {
                session.selection = [clip.id]
                session.beatgridRequest = BeatgridRequest(id: trackID)
                return .nothing
            }
            if modifiers.contains(.shift) {
                if session.selection.contains(clip.id) { session.selection.remove(clip.id) } else { session.selection.insert(clip.id) }
            } else {
                if !session.selection.contains(clip.id) { session.selection = [clip.id] }
                // Its row: a stem's in an expanded lane, which the clip bar's
                // gain and mute then work on; the clip's own otherwise.
                if session.selection == [clip.id] { session.selectedPart = layout.part(atY: p.y, lane: lane) }
            }
            let rect = layout.rect(for: clip.geometry, lane: lane)
            let edge = min(8, rect.width / 4)
            if p.x - rect.minX < edge { return .trim(id: clip.id, edge: .start, started: false) }
            if rect.maxX - p.x < edge { return .trim(id: clip.id, edge: .end, started: false) }
            let anchor = session.document.clips.first { $0.id == clip.id }?.anchorBeat ?? 0
            return .pendingClip(id: clip.id, grab: beat - Double(anchor))
        }
        if !modifiers.contains(.shift) { session.selection = [] }
        return .emptyLane
    }

    /// Automation is drawn only on a clip: a press outside every clip places
    /// and draws nothing, though a drag from there still selects. A locked
    /// clip is treated like no clip: its points cannot be grabbed, and
    /// nothing is placed or drawn on it.
    private func beginAutomation(lane: Int, kind: AutomationKind, beat: Double, at p: CGPoint,
                                 modifiers: NSEvent.ModifierFlags, _ layout: TimelineLayout,
                                 _ snapshot: TimelineSnapshot) -> DragState {
        // In an expanded lane, the row under the pointer: the clip's own or
        // a stem's. Everything below is the same for either.
        let part = layout.part(atY: p.y, lane: lane)
        // A node within grabbing distance, on any clip of the lane - one on a
        // clip's edge can be grabbed from just outside it. Nodes hidden by a
        // trim are not on screen, and cannot be hit either.
        for clip in snapshot.clips where clip.lane == lane && !clip.locked {
            let anchor = Double(clip.anchorBeat)
            guard let hit = clip.automation(part).nodes(kind).first(where: {
                $0.beat + anchor >= clip.geometry.start && $0.beat + anchor <= clip.geometry.end
                    && hypot(layout.x($0.beat + anchor) - p.x,
                             layout.y(value: $0.value, kind: kind, lane: lane, part: part) - p.y) < 7
            }) else { continue }
            if modifiers.contains(.option) {
                session.perform { $0.removeAutomationNode(clip: clip.id, part: part, kind: kind, node: hit) }
                return .nothing
            }
            // A double-click puts the point back at its kind's resting
            // value. Click count comes from AppKit's current event.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                session.perform { $0.resetAutomationNode(hit, kind: kind, clip: clip.id, part: part) }
                return .nothing
            }
            session.beginGesture()
            return .node(clip: clip.id, lane: lane, part: part, kind: kind, node: hit)
        }
        let clip = clipHit(at: p, lane: lane, layout, snapshot).flatMap { $0.locked ? nil : $0 }
        if modifiers.contains(.option) {
            if let clip, let gesture = clip.automation(part).gestures.first(where: {
                let local = beat - Double(clip.anchorBeat)
                return $0.kind == kind && local >= $0.start && local <= $0.end
            }) {
                session.perform { $0.removeGesture(gesture.id, clip: clip.id, part: part) }
            }
            return .nothing
        }
        let value = layout.value(atY: p.y, kind: kind, lane: lane, part: part)
        if drawStyle != .nodes {
            // Dragging draws the movement; with ⇧ it selects instead.
            if modifiers.contains(.shift) { return .marquee(kind: kind, lane: lane, part: part, origin: p) }
            if let clip {
                return .draw(clip: clip.id, lane: lane, part: part, kind: kind, start: snap(beat), startValue: value)
            }
            return .pendingNode(clip: nil, lane: lane, part: part, kind: kind, beat: beat, value: value)
        }
        // A click places a node, a drag selects - which one is only known
        // once the pointer moves, or is released without moving.
        return .pendingNode(clip: clip?.id, lane: lane, part: part, kind: kind, beat: snap(beat), value: value)
    }

    private func update(_ value: DragGesture.Value, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) {
        guard let drag else { return }
        let p = value.location
        let grids = session.grids
        let moved = hypot(value.translation.width, value.translation.height)
        switch drag {
        case .scrub:
            session.seek(toBeat: max(0, layout.beat(p.x)))
        case .pendingClip(let id, let grab):
            guard moved > 3, canDrag(id) else { return }
            session.beginGesture()
            self.drag = .moveClip(id: id, grab: grab)
            moveClip(id, grab: grab, to: p, layout)
        case .moveClip(let id, let grab):
            moveClip(id, grab: grab, to: p, layout)
        case .trim(let id, let edge, let started):
            if !started {
                guard moved > 1 else { return }
                session.beginGesture()
                self.drag = .trim(id: id, edge: edge, started: true)
            }
            session.perform(undoable: false, quiet: true) { document in
                try document.trimClip(id, edge: edge, to: layout.beat(p.x), grids: grids)
            }
        case .tempo(let id, let origin, let startY, let started):
            if !started {
                guard abs(value.translation.height) > 2 else { return }
                session.beginGesture()
                self.drag = .tempo(id: id, origin: origin, startY: startY, started: true)
            }
            // A tenth of a BPM per pixel; with Shift, a hundredth.
            let perPixel = NSEvent.modifierFlags.contains(.shift) ? 0.01 : 0.1
            let bpm = ((origin + Double(startY - p.y) * perPixel) * 100).rounded() / 100
            session.perform(undoable: false, quiet: true) { $0.setTargetBPM(id, bpm) }
        case .master(let origin, let startY, let started):
            if !started {
                guard abs(value.translation.height) > 2 else { return }
                session.beginGesture()
                self.drag = .master(origin: origin, startY: startY, started: true)
            }
            let perPixel = NSEvent.modifierFlags.contains(.shift) ? 0.01 : 0.1
            let bpm = ((origin + Double(startY - p.y) * perPixel) * 100).rounded() / 100
            session.perform(undoable: false, quiet: true) { $0.setMasterBPM(bpm) }
        case .rampStart(let id, let started):
            if !started {
                guard moved > 2 else { return }
                session.beginGesture()
                self.drag = .rampStart(id: id, started: true)
            }
            session.perform(undoable: false, quiet: true) { $0.setRampStart(id, to: layout.beat(p.x)) }
        case .tempoAnchor(let id):
            session.perform(undoable: false, quiet: true) { document in
                document.moveTempoAnchor(id, to: layout.beat(p.x), grids: grids)
            }
        case .node(let clip, let lane, let part, let kind, let node):
            // Held to the clip: dragged past its edge, the point stops on it -
            // and to its row: the value is read in the row it was grabbed in.
            let beat = snap(layout.beat(p.x))
            let level = layout.value(atY: p.y, kind: kind, lane: lane, part: part)
            var stored: AutomationNode?
            session.perform(undoable: false, quiet: true) { document in
                stored = document.moveAutomationNode(clip: clip, part: part, kind: kind, from: node, toBeat: beat,
                                                     value: level, grids: grids)
            }
            if let stored { self.drag = .node(clip: clip, lane: lane, part: part, kind: kind, node: stored) }
        case .draw(let clip, let lane, let part, let kind, let start, let startValue):
            guard let shape = drawStyle.shape else { return }
            let end = snap(layout.beat(p.x))
            let level = layout.value(atY: p.y, kind: kind, lane: lane, part: part)
            let drawn = AutomationGesture(kind: kind, start: min(start, end), end: max(start, end),
                                          shape: shape, period: period, low: level, high: startValue)
            draft = session.document.clippedGesture(drawn, clip: clip, grids: grids)
                .map { DraftGesture(clip: clip, lane: lane, part: part, drawn: drawn, gesture: $0) }
        case .pendingNode(_, let lane, let part, let kind, _, _):
            guard moved > 3 else { return }
            self.drag = .marquee(kind: kind, lane: lane, part: part, origin: value.startLocation)
            updateMarquee(kind: kind, lane: lane, part: part, from: value.startLocation, to: p, layout, snapshot)
        case .marquee(let kind, let lane, let part, let origin):
            updateMarquee(kind: kind, lane: lane, part: part, from: origin, to: p, layout, snapshot)
        case .newMark(let start):
            guard moved > 3 else { return }
            let end = snapMark(layout.beat(p.x), layout)
            draftMark = min(start, end)...max(start, end)
        case .markEdge(let ref, let edge, let fixed, let started):
            if !started {
                guard moved > 1 else { return }
                session.beginGesture()
            }
            // Never shorter than a beat, on whichever side the end belongs.
            let minimum = MixDocument.minimumMarkBeats
            let beat = snapMark(layout.beat(p.x), layout)
            let end = edge == .start ? min(beat, fixed - minimum) : max(beat, fixed + minimum)
            let now = session.moveMark(ref, from: fixed, to: end) ?? ref
            self.drag = .markEdge(ref: now, edge: edge, fixed: fixed, started: true)
        case .markMove(let ref, let grab, let length, let started):
            if !started {
                guard moved > 3 else { return }
                session.beginGesture()
            }
            let start = snapMarkStart(layout.beat(p.x) - grab, length: length, layout)
            let now = session.moveMark(ref, from: start, to: start + length) ?? ref
            self.drag = .markMove(ref: now, grab: grab, length: length, started: true)
        case .emptyLane, .nothing:
            break
        }
    }

    private func finish(_ value: DragGesture.Value, _ layout: TimelineLayout) {
        guard let drag else { return }
        let grids = session.grids
        switch drag {
        case .emptyLane:
            // Only a click: a drag that wandered off and came back is not
            // a decision about where the playhead goes.
            if hypot(value.translation.width, value.translation.height) < 3 {
                session.seek(toBeat: max(0, layout.beat(value.location.x)))
            }
        case .draw:
            // A draft exists only when a quarter beat or more of it lies on
            // the clip (see MixDocument.clippedGesture).
            if let draft {
                session.perform { _ = $0.addGesture(draft.drawn, clip: draft.clip, part: draft.part, grids: grids) }
            }
            draft = nil
        case .pendingNode(let clip, _, let part, let kind, let beat, let value):
            if let clip {
                session.perform {
                    _ = $0.addAutomationNode(clip: clip, part: part, kind: kind, beat: beat, value: value, grids: grids)
                }
            }
            automationSelection = nil
        case .marquee:
            marquee = nil
            if automationSelection?.isEmpty == true { automationSelection = nil }
        case .newMark:
            if let range = draftMark { session.addMark(from: range.lowerBound, to: range.upperBound) }
            draftMark = nil
        default:
            break
        }
    }

    /// Drags the clip under the pointer - and with it everything else that
    /// is selected, which keeps its distance. One clip on its own is the
    /// same move as before: it is a selection of one.
    private func moveClip(_ id: UUID, grab: Double, to p: CGPoint, _ layout: TimelineLayout) {
        guard let clip = session.document.clips.first(where: { $0.id == id }) else { return }
        let lane = layout.lane(atY: p.y) ?? clip.lane
        let grids = session.grids
        let ids = session.selection.contains(id) ? session.selection : [id]
        guard let step = session.moveMode.step else { return }
        session.perform(undoable: false, quiet: true) { document in
            try document.moveClips(ids, dragging: id, anchorBeat: layout.beat(p.x) - grab,
                                   lane: lane, step: step, grids: grids)
        }
    }

    /// Whether a drag from this clip may start moving: not with the move
    /// mode off, and not with a locked clip in what would move. Checked
    /// before the gesture begins, so a refused drag leaves no undo step.
    private func canDrag(_ id: UUID) -> Bool {
        guard session.moveMode.step != nil else { return false }
        let ids = session.selection.contains(id) ? session.selection : [id]
        return !session.document.clips.contains { ids.contains($0.id) && $0.locked }
    }

    /// Draws the selection rectangle and picks what it encloses, clip by
    /// clip, so nothing a trim hid is ever picked. Locked clips are passed
    /// over; a new rectangle replaces the old selection. It picks in one
    /// row: the clips' own rows across the lanes, or one stem's row in the
    /// lane it began in.
    private func updateMarquee(kind: AutomationKind, lane: Int, part: Stem?, from origin: CGPoint, to point: CGPoint,
                               _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) {
        let rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                          width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        marquee = rect
        let beats = layout.beat(rect.minX)...layout.beat(rect.maxX)
        var selection = AutomationSelection(kind: kind, part: part)
        for clip in snapshot.clips where !clip.locked && (part == nil || clip.lane == lane) {
            let inRow = rect.intersection(layout.rowRect(clip.lane, part: part))
            guard !inRow.isNull, inRow.height > 0 else { continue }
            let low = max(beats.lowerBound, clip.geometry.start)
            let high = min(beats.upperBound, clip.geometry.end)
            guard low <= high else { continue }
            let anchor = Double(clip.anchorBeat)
            let values = layout.valueRange(fromY: inRow.minY, toY: inRow.maxY, kind: kind, lane: clip.lane, part: part)
            let picked = clip.automation(part).selection(kind: kind, beats: (low - anchor)...(high - anchor), values: values)
            if !picked.nodes.isEmpty { selection.nodes[clip.id] = picked.nodes }
            if !picked.gestures.isEmpty { selection.gestures[clip.id] = picked.gestures }
        }
        automationSelection = selection
    }

    // MARK: - Transition bars

    /// A press in the transition strip: on a bar it picks it and holds an
    /// end or the whole; in empty strip it starts drawing a new one.
    private func beginMark(at p: CGPoint, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) -> DragState {
        guard let mark = markHit(at: p, layout, snapshot) else {
            session.selectedMark = nil
            return .newMark(start: snapMark(layout.beat(p.x), layout))
        }
        session.selection = []
        session.selectedMark = mark.ref
        guard !mark.locked else { return .nothing }
        let rect = layout.rect(for: mark)
        let edge = min(6, rect.width / 4)
        if p.x - rect.minX < edge { return .markEdge(ref: mark.ref, edge: .start, fixed: mark.end, started: false) }
        if rect.maxX - p.x < edge { return .markEdge(ref: mark.ref, edge: .end, fixed: mark.start, started: false) }
        return .markMove(ref: mark.ref, grab: layout.beat(p.x) - mark.start, length: mark.end - mark.start,
                         started: false)
    }

    /// The bar under the pointer; of two over each other, the shorter.
    private func markHit(at p: CGPoint, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) -> PlacedMark? {
        snapshot.marks
            .filter { layout.rect(for: $0).insetBy(dx: -3, dy: -3).contains(p) }
            .min { $0.end - $0.start < $1.end - $1.start }
    }

    /// How near, in pixels, an end of a bar has to come to stick.
    static let markMagnet: CGFloat = 8

    /// Where an end of a bar sticks: the edges of an overlap - where the
    /// incoming clip starts, where the outgoing one ends - before a bar
    /// line, each within `markMagnet` pixels. Nil when nothing is that near.
    private func magnet(_ beat: Double, _ layout: TimelineLayout) -> Double? {
        let reach = Double(Self.markMagnet) / layout.pixelsPerBeat
        let edges = session.document.transitions(session.grids).flatMap { [$0.start, $0.end] }
        if let edge = edges.min(by: { abs($0 - beat) < abs($1 - beat) }), abs(edge - beat) <= reach {
            return edge
        }
        let bar = Double(Clip.beatsPerBar)
        let line = (beat / bar).rounded() * bar
        return abs(line - beat) <= reach ? line : nil
    }

    /// An end of a bar: stuck to an overlap edge or a bar line when near
    /// one, otherwise on the whole beat. ⌘ lets go of all of it and lands
    /// on sixteenth notes.
    private func snapMark(_ beat: Double, _ layout: TimelineLayout) -> Double {
        if NSEvent.modifierFlags.contains(.command) { return (beat * 16).rounded() / 16 }
        return magnet(beat, layout) ?? beat.rounded()
    }

    /// The start of a whole bar being moved: whichever end is nearer to
    /// something it sticks to, decides; the length stays.
    private func snapMarkStart(_ start: Double, length: Double, _ layout: TimelineLayout) -> Double {
        if NSEvent.modifierFlags.contains(.command) { return (start * 16).rounded() / 16 }
        let byStart = magnet(start, layout)
        let byEnd = magnet(start + length, layout).map { $0 - length }
        switch (byStart, byEnd) {
        case let (a?, b?): return abs(a - start) <= abs(b - start) ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return start.rounded()
        }
    }

    /// What a right-click offers: the transition bar under the pointer, or
    /// the clip's stems - separating its song is asked for here, or by a
    /// click in its stem rows, never done by expanding a lane.
    @ViewBuilder
    private var canvasMenu: some View {
        if hoveredMark != nil {
            markMenu
        } else if let id = hoveredClip, let clip = session.document.clips.first(where: { $0.id == id }) {
            let separated = library.track(clip.trackID)?.stems?.isCurrent == true
            let separating = library.separating[clip.trackID] != nil
            Button(separating ? "Separating Stems…" : "Separate Stems") { library.separate([clip.trackID]) }
                .disabled(separated || separating)
            Button("Delete Stems") { library.deleteStems(clip.trackID) }
                .disabled(!separated && !separating)
        }
    }

    /// Right-click on a bar: write another style there, or delete it.
    @ViewBuilder
    private var markMenu: some View {
        if let ref = hoveredMark {
            ForEach(TransitionStyle.allCases) { style in
                Button(style.title) {
                    pick(ref)
                    session.autoCrossfade(style)
                }
            }
            Divider()
            Button("Delete Transition") {
                pick(ref)
                session.removeSelectedMark()
            }
        }
    }

    private func pick(_ ref: MarkRef) {
        session.selection = []
        session.selectedMark = ref
    }

    /// Automation lands on sixteenth notes unless ⌘ is held.
    private func snap(_ beat: Double) -> Double {
        NSEvent.modifierFlags.contains(.command) ? beat : (beat * 16).rounded() / 16
    }

    private func clipHit(at p: CGPoint, lane: Int, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) -> ClipDrawItem? {
        snapshot.clips.last { $0.lane == lane && layout.rect(for: $0.geometry, lane: lane).insetBy(dx: -2, dy: 0).contains(p) }
    }

    private func tempoPoint(near x: CGFloat, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) -> ClipDrawItem? {
        snapshot.clips
            .filter { abs(layout.x(Double($0.tempoAnchorBeat)) - x) < 8 }
            .min { abs(layout.x(Double($0.tempoAnchorBeat)) - x) < abs(layout.x(Double($1.tempoAnchorBeat)) - x) }
    }

    /// The ramp-start diamond nearest `x`, within grabbing distance.
    private func rampHandle(near x: CGFloat, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) -> ClipDrawItem? {
        func distance(_ clip: ClipDrawItem) -> CGFloat {
            clip.rampStartBeat.map { abs(layout.x(Double($0)) - x) } ?? .infinity
        }
        return snapshot.clips.filter { distance($0) < 8 }.min { distance($0) < distance($1) }
    }

    /// The clip whose tempo point is the first one after `beat` - the ramp a
    /// click at `beat` belongs to.
    private func nextTempoPoint(after beat: Double, _ snapshot: TimelineSnapshot) -> ClipDrawItem? {
        snapshot.clips.filter { Double($0.tempoAnchorBeat) > beat }.min { $0.tempoAnchorBeat < $1.tempoAnchorBeat }
    }

    private func hover(_ phase: HoverPhase, _ layout: TimelineLayout, _ snapshot: TimelineSnapshot) {
        if case .active(let p) = phase { wheel.pointer = p } else { wheel.pointer = nil }
        guard drag == nil else { return }
        guard case .active(let p) = phase else {
            hoveredMark = nil
            hoveredClip = nil
            NSCursor.arrow.set()
            return
        }
        let overClip = layout.lane(atY: p.y).flatMap { clipHit(at: p, lane: $0, layout, snapshot) }?.id
        if hoveredClip != overClip { hoveredClip = overClip }
        let overMark = layout.transitionRect.contains(p) ? markHit(at: p, layout, snapshot) : nil
        if hoveredMark != overMark?.ref { hoveredMark = overMark?.ref }
        if layout.transitionRect.contains(p) {
            if let mark = overMark, !mark.locked {
                let rect = layout.rect(for: mark)
                let edge = min(6, rect.width / 4)
                if p.x - rect.minX < edge || rect.maxX - p.x < edge {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.openHand.set()
                }
            } else {
                NSCursor.arrow.set()
            }
            return
        }
        if layout.tempoRect.contains(p), tempoPoint(near: p.x, layout, snapshot) != nil {
            NSCursor.resizeUpDown.set()
            return
        }
        if layout.tempoRect.contains(p), snapshot.master == nil, rampHandle(near: p.x, layout, snapshot) != nil {
            NSCursor.resizeLeftRight.set()
            return
        }
        if tool == .clips, let lane = layout.lane(atY: p.y), let clip = clipHit(at: p, lane: lane, layout, snapshot) {
            let rect = layout.rect(for: clip.geometry, lane: lane)
            let edge = min(8, rect.width / 4)
            if p.x - rect.minX < edge || rect.maxX - p.x < edge {
                NSCursor.resizeLeftRight.set()
            } else if clip.locked || session.moveMode.step == nil {
                // Nothing to grab: the hand would promise a move.
                NSCursor.arrow.set()
            } else {
                NSCursor.openHand.set()
            }
            return
        }
        NSCursor.arrow.set()
    }

    private func drop(_ items: [String], at location: CGPoint, _ layout: TimelineLayout) -> Bool {
        guard let text = items.first, let id = UUID(uuidString: text) else { return false }
        session.addTrack(id, lane: layout.lane(atY: location.y), startBeat: max(0, layout.beat(location.x)))
        return true
    }
}

// MARK: - Playhead

/// The playhead, redrawn every display frame from the engine's frame
/// counter, over a timeline that is not redrawn at all. With follow on it
/// turns the page rather than scrolling continuously, which would redraw
/// every frame and be harder to read while it moves.
struct PlayheadOverlay: View {
    let session: MixSession
    let layout: TimelineLayout
    let follow: Bool
    /// Handed in as a value rather than read from the environment: this view
    /// lives inside a TimelineView, whose children only redraw when the
    /// inputs they were given change.
    let accent: Color
    let scroll: (CGFloat) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
            let beat = session.playheadBeat()
            let x = layout.x(beat)
            let turnPage = follow && session.isPlaying && (x > layout.size.width * 0.88 || x < 0)
            Canvas { context, size in
                guard x >= -2, x <= size.width + 2 else { return }
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(accent.opacity(0.9)), lineWidth: 1.2)
                var head = Path()
                head.move(to: CGPoint(x: x - 6, y: 0))
                head.addLine(to: CGPoint(x: x + 6, y: 0))
                head.addLine(to: CGPoint(x: x, y: 9))
                head.closeSubpath()
                context.fill(head, with: .color(accent))
            }
            .allowsHitTesting(false)
            .onChange(of: turnPage) { _, turn in
                guard turn else { return }
                let playheadContentX = CGFloat(beat * layout.pixelsPerBeat) + TimelineLayout.leadingPad
                scroll(max(0, playheadContentX - layout.size.width * 0.1))
            }
        }
    }
}

// MARK: - Lane headers

/// Lane names and mute/solo, beside the timeline.
///
/// The rows are flexible and share the column's height; nothing here is
/// sized from a measured value. Rows given a fixed height computed from the
/// timeline's measured height made the column 15 points taller than what it
/// had measured once the scroll bar appeared, and the inspector's split
/// view went round in circles over the window's minimum size until AppKit
/// aborted - every time a working directory opened.
///
/// The rows still line up with the canvas lanes by construction: the column
/// holds the same ruler, transition and tempo heights at the top and the scroll bar's
/// height at the bottom, and the three rows split what is left by the same
/// weights as the timeline's lanes (LaneGeometry) - worked out from the
/// height the column is given, never from one measured over there.
/// The tempo strip's header: its name, and the master tempo - a lock that
/// holds the whole mix at one tempo, and the tempo it holds.
struct MasterTempoHeader: View {
    let session: MixSession
    @Environment(\.accent) private var accent

    var body: some View {
        let document = session.document
        let locked = document.masterLocked
        VStack(alignment: .leading, spacing: 8) {
            Text("Tempo")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { locked }, set: { on in
                let here = session.tempo.bpm(atBeat: max(0, session.playheadBeat()))
                session.perform { $0.setMasterLocked(on, fallbackBPM: here) }
            })) {
                Label("Master", systemImage: locked ? "lock.fill" : "lock.open")
                    .foregroundStyle(locked ? accent : Color.secondary)
            }
            .toggleStyle(.button)
            .help(locked
                  ? "Master tempo locked: the whole mix plays at this tempo. Click to unlock - every tempo point goes back to its own tempo."
                  : "Lock the whole mix to the master tempo. The tempo points keep their own tempo and get it back when unlocked.")
            BPMField(value: document.masterBPM ?? document.projectBPM, fractionDigits: 2, width: 70) { value in
                session.perform { $0.setMasterBPM(value) }
            }
            .help(locked ? "The master tempo, heard at once" : "The master tempo, heard once it is locked")
        }
    }
}

struct LaneHeaders: View {
    let session: MixSession
    /// The lanes top to bottom, as the timeline beside it draws them.
    let order: [Int]

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: TimelineLayout.rulerHeight)
            Text("Transitions")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .frame(height: TimelineLayout.transitionHeight)
                .overlay(alignment: .top) { Divider() }
            MasterTempoHeader(session: session)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .frame(height: TimelineLayout.tempoHeight)
                .overlay(alignment: .top) { Divider() }
            // In the rows' order, keyed by lane: a header moves with its
            // lane rather than being renamed.
            LaneRowsLayout(expanded: order.map { session.expandedLanes.contains($0) }) {
                ForEach(order, id: \.self) { lane in
                    laneHeader(lane)
                }
            }
            // The scroll bar and its divider, under the timeline.
            Color.clear.frame(height: TimelineScrollbar.height + 1)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// One lane's header: its name, switches and knobs, and in an expanded
    /// lane its stems' names, at their rows.
    @ViewBuilder
    private func laneHeader(_ lane: Int) -> some View {
        let state = session.document.lanes[lane]
        let expanded = session.expandedLanes.contains(lane)
        LaneRowLayout(expanded: expanded) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 3) {
                        LaneColorButton(session: session, lane: lane)
                        Text("Lane \(LaneStyle.names[lane])")
                            .font(.callout.weight(.semibold))
                        // The playhead is the engine's frame counter, which
                        // nothing observes, so the mark polls it - and is
                        // handed a plain Bool, since a TimelineView's child
                        // only redraws when its inputs change.
                        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                            LanePlayMark(on: session.isPlaying && session.document.soundingLanes(
                                atBeat: session.playheadBeat(), grids: session.grids, laneMask: session.laneMask
                            ).contains(lane), color: LaneStyle.color(lane, session.document.lanes))
                        }
                    }
                    HStack(spacing: 4) {
                        LaneToggle(title: "M", on: state.muted, tint: .yellow) { session.toggleLaneMute(lane) }
                            .help("Mute lane \(LaneStyle.names[lane])")
                        LaneToggle(title: "S", on: state.solo, tint: .green) { session.toggleLaneSolo(lane) }
                            .help("Solo lane \(LaneStyle.names[lane])")
                        LaneExpandButton(on: expanded) { session.setLaneExpanded(lane, !expanded) }
                            .help(expanded ? "Fold the stems of lane \(LaneStyle.names[lane]) away"
                                           : "Show the stems of lane \(LaneStyle.names[lane])'s clips - drums, bass, vocals and the rest, each a row with its own level, mute and automation. Songs never separated are separated now.")
                    }
                }
                Spacer(minLength: 4)
                // Keyed by lane, like the rest of the header: in the live set
                // a lane's knobs move with its row.
                HStack(spacing: 2) {
                    ForEach(0..<LaneKnobMath.knobsPerLane, id: \.self) { knob in
                        LaneKnob(slot: LaneKnobMath.slot(lane: lane, knob: knob))
                    }
                }
                .padding(.trailing, 6)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Divider() }
            if expanded {
                ForEach(Stem.allCases, id: \.self) { stem in
                    Text(stem.name.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Divider().opacity(0.5) }
                }
            }
        }
    }
}

/// The lane headers top to bottom, at the heights the timeline gives its
/// lanes (LaneGeometry), out of the height the column offers.
struct LaneRowsLayout: Layout {
    let expanded: [Bool]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = LaneGeometry.heights(total: Double(bounds.height), expanded: expanded)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() where index < heights.count {
            let height = CGFloat(heights[index])
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }
}

/// One lane header: the lane's own row, and in an expanded lane a row per
/// stem under it, as the timeline's rows (LaneGeometry.rows).
struct LaneRowLayout: Layout {
    let expanded: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard expanded, subviews.count > 1 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let rows = LaneGeometry.rows(laneHeight: Double(bounds.height))
        let clip = CGFloat(rows.clip), stem = CGFloat(rows.stem)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: clip))
        for (index, subview) in subviews.dropFirst().enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + clip + CGFloat(index) * stem),
                          proposal: ProposedViewSize(width: bounds.width, height: stem))
        }
    }
}

/// Expands a lane into its stems' rows, beside mute and solo.
struct LaneExpandButton: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 17)
                .foregroundStyle(on ? Color.black : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Hide stems" : "Show stems")
    }
}

/// ▶ beside a lane's name while a clip on it is heard - which lane is
/// playing, wherever the live set's rows have moved it. Its room is kept
/// when it is off, so the name beside it never shifts.
struct LanePlayMark: View {
    let on: Bool
    let color: Color

    var body: some View {
        Image(systemName: "play.fill")
            .font(.caption2)
            .foregroundStyle(color)
            .opacity(on ? 1 : 0)
            .padding(.leading, 2)
            .accessibilityLabel(on ? "Playing" : "")
            .help(on ? "Playing" : "")
    }
}

/// The colour bar in a lane header, and the popover that changes it.
///
/// The colour well sends a value for every movement in the colour panel,
/// so it is treated like a drag: the first real change records the document
/// once, the rest do not - one undo step per visit to the popover. The
/// swatches and Use Default are one step each.
///
/// A low contrast is reported, never corrected.
struct LaneColorButton: View {
    let session: MixSession
    let lane: Int
    @State private var showing = false
    @State private var recorded = false
    @Environment(\.colorScheme) private var colorScheme

    static let swatches = LaneSettings.defaultColors + ["E8484D", "F2C230", "3FBF6E", "2EC4C4", "8A8F98"]

    private var name: String { LaneStyle.names[lane] }
    private var current: String { LaneStyle.hex(lane, session.document.lanes) }

    var body: some View {
        Button { showing = true } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(LaneStyle.color(lane, session.document.lanes))
                .frame(width: 4, height: 16)
                .frame(width: 10, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Lane \(name) colour")
        .accessibilityLabel("Lane \(name) colour")
        .popover(isPresented: $showing, arrowEdge: .trailing) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lane \(name) Colour").font(.headline)
            HStack(spacing: 6) {
                ForEach(Self.swatches, id: \.self) { hex in
                    Button { choose(hex) } label: {
                        Circle()
                            .fill(LaneStyle.color(hex: hex))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary, lineWidth: hex == current ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(hex)")
                }
            }
            HStack {
                ColorPicker("Any colour", selection: well, supportsOpacity: false)
                Spacer()
                Button("Use Default") { choose(nil) }
                    .disabled(session.document.lanes[lane].color == nil)
            }
            if let ratio = contrast, ratio < 3 {
                Text("Hard to see on the timeline: contrast \(String(format: "%.1f", ratio)):1, 3:1 is the minimum.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onDisappear { recorded = false }
    }

    /// The colour well, recording the document once per popover visit.
    private var well: Binding<Color> {
        Binding(get: { LaneStyle.color(lane, session.document.lanes) }) { color in
            guard let hex = HexColor.normalized(AppAccent.hex(color)), hex != current else { return }
            if !recorded {
                session.beginGesture()
                recorded = true
            }
            session.perform(undoable: false, quiet: true) { $0.setLaneColor(lane, hex) }
        }
    }

    private func choose(_ hex: String?) {
        // A click after dragging the well is a step of its own.
        recorded = false
        session.perform { $0.setLaneColor(lane, hex) }
    }

    /// The lane colour against the timeline's background, as the current
    /// appearance draws it. `colorScheme` is read so a switch of appearance
    /// works it out again.
    private var contrast: Double? {
        _ = colorScheme
        var background: String?
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                let value = { (component: CGFloat) in Int((component * 255).rounded()) }
                background = String(format: "%02X%02X%02X", value(color.redComponent), value(color.greenComponent),
                                    value(color.blueComponent))
            }
        }
        return background.flatMap { HexColor.contrastRatio(current, $0) }
    }
}

struct LaneToggle: View {
    let title: String
    let on: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 17)
                .foregroundStyle(on ? Color.black : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? tint : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}
