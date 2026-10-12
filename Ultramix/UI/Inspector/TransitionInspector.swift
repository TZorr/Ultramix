//
//  TransitionInspector.swift
//  Ultramix
//
//  The inspector for a picked transition bar: which two clips it hands over
//  between, its style, where it starts and ends, and Delete. Everything here
//  could already be done on the bar itself - right-click for the style and
//  Delete, a drag for its ends - but not seen, and not to the beat.
//
//  Every change goes through what the bar's own gestures use
//  (MixSession.autoCrossfade with the bar picked, moveMark, removeSelectedMark),
//  so it is written, refused and undone exactly as a drag would be.
//

import SwiftUI

struct TransitionInspector: View {
    let session: MixSession
    let library: Library
    let ref: MarkRef

    var body: some View {
        let grids = session.grids
        let document = session.document
        if let mark = document.placedMarks(grids).first(where: { $0.ref == ref }) {
            form(mark, document.transition(over: mark.start, mark.end, grids: grids))
        } else {
            ContentUnavailableView("No Transition Selected", systemImage: "square.dashed")
        }
    }

    private func form(_ mark: PlacedMark, _ transition: Transition?) -> some View {
        Form {
            Section {
                header(mark, transition)
            }
            Section("Style") {
                Picker("Style", selection: Binding(
                    get: { StyleTag(mark.choice) },
                    set: { tag in choose(tag, mark) })) {
                    if mark.choice == nil {
                        Text("Beatmix handover").tag(StyleTag.handover)
                    }
                    ForEach(TransitionStyle.allCases) { Text($0.title).tag(StyleTag.preset($0)) }
                    Divider()
                    Text("Custom").tag(StyleTag.custom)
                }
                .help("Writes this style over the bar's range, in place of what is there. Custom: choose the moves below, for the outgoing and the incoming track.")
                Text(description(mark))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(mark.locked)
            moveSections(mark, transition)
                .disabled(mark.locked)
            Section("Range") {
                StepperRow(title: "Start", hint: "Step 1 beat · ⇧ 1 bar",
                           decreaseLabel: "Start a beat earlier", increaseLabel: "Start a beat later") { direction, coarse in
                    move(mark, start: mark.start + step(direction, coarse), end: mark.end)
                } value: {
                    StepperValue(text: Self.barBeat(mark.start), width: 64)
                }
                StepperRow(title: "End", hint: "Step 1 beat · ⇧ 1 bar",
                           decreaseLabel: "End a beat earlier", increaseLabel: "End a beat later") { direction, coarse in
                    move(mark, start: mark.start, end: mark.end + step(direction, coarse))
                } value: {
                    StepperValue(text: Self.barBeat(mark.end), width: 64)
                }
                LabeledContent("Length") {
                    Text(Self.length(mark.end - mark.start)).monospacedDigit()
                }
            }
            .disabled(mark.locked)
            Section {
                Button("Delete Transition", role: .destructive) {
                    session.removeSelectedMark()
                }
                .frame(maxWidth: .infinity)
                .disabled(mark.locked)
                .help("Removes the bar, and every volume, pan, low-pass and high-pass point inside its range on every lane (⌫). The curves either side stay.")
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    private func header(_ mark: PlacedMark, _ transition: Transition?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Transition")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(mark.title)
                .font(.headline)
            if let transition {
                Text("Lane \(LaneStyle.number(transition.outgoingLane)) → Lane \(LaneStyle.number(transition.incomingLane))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    trackLine("arrow.up.right", clip: transition.outgoing)
                    trackLine("arrow.down.right", clip: transition.incoming)
                }
                .font(.callout)
                .padding(.top, 2)
            }
            if mark.locked {
                Label("Its clip is locked: unlock it to change the transition.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    /// One of the two records, with an arrow for out or in.
    private func trackLine(_ symbol: String, clip id: UUID) -> some View {
        let name = session.document.clips.first { $0.id == id }
            .flatMap { library.track($0.trackID)?.displayName } ?? "–"
        return Label(name, systemImage: symbol)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: - Style and moves

    /// What the style picker shows: a style, the bar's own moves, or the
    /// beatmix's handover.
    private enum StyleTag: Hashable {
        case handover
        case preset(TransitionStyle)
        case custom

        init(_ choice: TransitionChoice?) {
            switch choice {
            case .preset(let style): self = .preset(style)
            case .custom: self = .custom
            case nil: self = .handover
            }
        }
    }

    /// The moves the rows show: the bar's own, its style's, or - for a
    /// handover - Crossfade's, which is where Custom starts from there.
    private func moves(_ mark: PlacedMark) -> TransitionMoves {
        mark.choice?.moves ?? TransitionStyle.crossfade.moves
    }

    private func choose(_ tag: StyleTag, _ mark: PlacedMark) {
        switch tag {
        case .handover: break
        case .preset(let style): session.applyToSelectedMark(.preset(style))
        case .custom: session.applyToSelectedMark(.custom(moves(mark)))
        }
    }

    private func description(_ mark: PlacedMark) -> String {
        switch mark.choice {
        case .preset(let style): style.summary
        case .custom: "Your own moves for the outgoing and the incoming track, chosen below."
        case nil: "The beatmix's own handover: the outgoing record fades and is cut where the bar ends. Choosing a style or a move below writes that here instead."
        }
    }

    /// One move changed: the bar becomes custom - from a style, with that
    /// style's other moves kept.
    private func update(_ mark: PlacedMark, _ change: (inout TransitionMoves) -> Void) {
        var changed = moves(mark)
        change(&changed)
        guard changed != moves(mark) || mark.custom == nil else { return }
        session.applyToSelectedMark(.custom(changed))
    }

    /// The moves by kind - volume, the two filters, pan - each with a row
    /// for the outgoing and one for the incoming track.
    @ViewBuilder
    private func moveSections(_ mark: PlacedMark, _ transition: Transition?) -> some View {
        let current = moves(mark)
        let out = trackName(transition?.outgoing)
        let into = trackName(transition?.incoming)
        Section("Volume") {
            moveRow("Out", help: out, value: current.outgoing.volume,
                    title: { $0.title(incoming: false) }) { v in update(mark) { $0.outgoing.volume = v } }
            moveRow("In", help: into, value: current.incoming.volume,
                    title: { $0.title(incoming: true) }) { v in update(mark) { $0.incoming.volume = v } }
        }
        Section("Filter") {
            moveRow("Low-pass out", help: out, value: current.outgoing.lowPass,
                    title: { $0.title(incoming: false) }) { v in update(mark) { $0.outgoing.lowPass = v } }
            moveRow("Low-pass in", help: into, value: current.incoming.lowPass,
                    title: { $0.title(incoming: true) }) { v in update(mark) { $0.incoming.lowPass = v } }
            moveRow("High-pass out", help: out, value: current.outgoing.highPass,
                    title: { $0.title(incoming: false) }) { v in update(mark) { $0.outgoing.highPass = v } }
            moveRow("High-pass in", help: into, value: current.incoming.highPass,
                    title: { $0.title(incoming: true) }) { v in update(mark) { $0.incoming.highPass = v } }
        }
        Section("Pan") {
            moveRow("Out", help: out, value: current.outgoing.pan,
                    title: { $0.title }) { v in update(mark) { $0.outgoing.pan = v } }
            moveRow("In", help: into, value: current.incoming.pan,
                    title: { $0.title }) { v in update(mark) { $0.incoming.pan = v } }
        }
    }

    private func moveRow<Move: CaseIterable & Hashable>(_ label: String, help: String, value: Move,
                                                         title: @escaping (Move) -> String,
                                                         set: @escaping (Move) -> Void) -> some View
        where Move.AllCases: RandomAccessCollection {
        Picker(label, selection: Binding(get: { value }, set: { if $0 != value { set($0) } })) {
            ForEach(Array(Move.allCases), id: \.self) { Text(title($0)).tag($0) }
        }
        .help(help)
    }

    private func trackName(_ clip: UUID?) -> String {
        guard let clip, let found = session.document.clips.first(where: { $0.id == clip }) else { return "" }
        return library.track(found.trackID)?.displayName ?? ""
    }

    private func step(_ direction: Int, _ coarse: Bool) -> Double {
        Double(direction * (coarse ? Clip.beatsPerBar : 1))
    }

    /// Tried on a copy first: a refused step - shorter than a beat, off the
    /// overlap, a locked clip - says why and leaves no empty undo step.
    private func move(_ mark: PlacedMark, start: Double, end: Double) {
        var trial = session.document
        do {
            try trial.moveMark(mark.ref, from: start, to: end, currentStyle: session.transitionStyle,
                               grids: session.grids)
        } catch {
            session.message = error.localizedDescription
            return
        }
        session.beginGesture()
        _ = session.moveMark(mark.ref, from: start, to: end)
    }

    /// A timeline beat as bar.beat, counting from 1.1, with the sixteenth
    /// after it where the beat is not whole: "33.2", "33.2.3".
    static func barBeat(_ beat: Double) -> String {
        let sixteenths = Int((max(0, beat) * 4).rounded())
        let bar = sixteenths / (Clip.beatsPerBar * 4)
        let inBar = (sixteenths / 4) % Clip.beatsPerBar
        let sixteenth = sixteenths % 4
        return sixteenth == 0 ? "\(bar + 1).\(inBar + 1)" : "\(bar + 1).\(inBar + 1).\(sixteenth + 1)"
    }

    /// "16 beats · 4 bars", or "6 beats".
    static func length(_ beats: Double) -> String {
        let whole = beats.rounded()
        let text = abs(beats - whole) < 1e-6 ? "\(Int(whole))" : String(format: "%.2f", beats)
        let bars = beats / Double(Clip.beatsPerBar)
        guard abs(bars - bars.rounded()) < 1e-6 else { return "\(text) beats" }
        return "\(text) beats · \(Int(bars.rounded())) bar\(bars.rounded() == 1 ? "" : "s")"
    }
}
