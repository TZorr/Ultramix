//
//  BeatgridEditor.swift
//  Ultramix
//
//  Where a wrong grid is put right, where the next record is told to come in,
//  and where a loop is cut out - by ear and by eye.
//
//  A pane opening from the bottom rather than a sheet over the window: a cue
//  point is set to be mixed at and a loop is made to be dropped into the
//  timeline, so both are easier to judge with the mix in sight.
//
//  The strip (BeatgridStrip.swift) shows the song with the grid over it, cue
//  points along the top and the marked stretch below them, at one of four
//  spans. Bar ones are drawn stronger and the analyser's kicks are ticked
//  along the bottom, so a grid that is off shows as a steady gap. A click
//  selects a gridline and Play starts on it - or, with Cycle on, plays the
//  marked stretch round and round while ← → and ⌥← ⌥→ move its ends a beat
//  (⇧: a bar). ⌥-click on a kick puts bar one there.
//
//  Under the strip a bar shows how well the grid holds, eight bars at a time
//  (`GridFit`), and says so when the whole grid sits early or late, when the
//  kicks drift away part way through, and when an intro sits beside the grid.
//
//  Every change is stored as the track's correction at once, so the mix
//  follows while the editor is open. The analysis is never touched, and
//  Analysis › Revert to Analysis goes back to it.
//
//  Laid out as a drawer with its own header - the track, how sure the
//  analysis is, whether the grid was edited, the Analysis menu and Done -
//  then the controls on the left in two groups, Grid and Cues & loops, and
//  the strip on the right with its own toolbar and a legend for its marks.
//

import SwiftUI
import AppKit

struct BeatgridEditor: View {
    let trackID: UUID
    let session: MixSession
    let library: Library
    let preview: PreviewPlayer
    /// Open with the BPM correction panel showing.
    var correctBPM = false
    /// Folded down to a bar: kept alive, so its mark and zoom survive.
    var hidden = false
    let hide: () -> Void
    let close: () -> Void

    @Environment(\.accent) private var accent
    /// Seconds either side of the middle - the strip shows twice this.
    /// Four steps rather than a free zoom and a Fit: every step draws a
    /// known amount, and the view can never land past the end of the song.
    @AppStorage("beatgridSpan") private var span = 15.0
    @AppStorage("loopRepeats") private var repeats = 8
    @State private var showBPMPanel = false
    /// A typed tempo far from the current one, waiting for a yes.
    @State private var largeChange: LargeChange?
    /// The selected gridline, as a line index (0 is bar one). An index, so
    /// it stays on its line while the grid is nudged.
    @State private var selectedLine = 0
    /// Kicks over the whole track, for the ticks. Empty until measured.
    @State private var onsets: [Double] = []
    /// The marked stretch, in seconds of the song. Not saved: it belongs to
    /// the loop being made, not to the record.
    @State private var region: LoopRegion?
    /// Play goes round the marked stretch instead of on from the line.
    @State private var cycle = false
    @State private var viewportWidth: CGFloat = 0
    @State private var showSeconds: Double?
    @State private var visibleRange = 0.0...0.0
    @State private var centreSeconds: Double?
    @FocusState private var focused: Bool

    /// The spans the strip can be set to. ±15 s to start - a phrase at a
    /// glance - down to ±2 s, where a millisecond is still a pixel or two.
    static let spans = [2.0, 5.0, 15.0, 30.0]

    /// The scale the strip draws at: the span across the width it has. Until
    /// the width is known, a middling scale, so the first frame is not drawn
    /// at some extreme.
    private var pixelsPerSecond: Double {
        viewportWidth > 1 ? Double(viewportWidth) / (2 * span) : 30
    }

    private struct LargeChange {
        let from: Double
        let to: Double
    }

    var body: some View {
        if let track = library.track(trackID) {
            editor(track)
        } else {
            HStack {
                Text("This track is no longer in the library.")
                Button("Close") { close() }
            }
            .padding(20)
        }
    }

    private func editor(_ track: Track) -> some View {
        let bpm = track.bpm ?? 120
        let first = track.firstBeatSeconds ?? 0
        let duration = max(track.durationSeconds, 1)
        let grid = SourceGrid(bpm: bpm, firstBeatSeconds: first, durationSeconds: duration)
        return VStack(spacing: 0) {
            header(track)
            Divider()
            HStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        gridSection(track, bpm: bpm, first: first)
                        Divider()
                        cueSection(track, grid: grid)
                    }
                }
                .scrollIndicators(.automatic)
                .frame(width: 270)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                VStack(spacing: 0) {
                    waveToolbar(bpm: bpm, first: first, grid: grid)
                    Divider()
                    BeatgridStrip(audio: library.audio(for: trackID), waveform: library.waveforms[trackID],
                                  preview: preview, trackID: trackID, grid: grid, onsets: onsets,
                                  cues: track.cuePoints, selectedLine: selectedLine, region: region, accent: accent,
                                  pixelsPerSecond: pixelsPerSecond, viewportWidth: $viewportWidth,
                                  showSeconds: $showSeconds, centreSeconds: $centreSeconds,
                                  visibleRange: $visibleRange,
                                  onSelect: { selectedLine = $0 },
                                  onPick: { seconds in
                                      setFirstBeat(seconds, track)
                                      selectedLine = 0
                                  },
                                  onRegion: { region = $0 },
                                  onMoveCue: { number, seconds in library.setCue(trackID, number: number, seconds: seconds) },
                                  onGoToCue: { goTo($0, grid: grid) })
                    .frame(minHeight: 70)
                    Divider()
                    fitRow(track, bpm: bpm, first: first, duration: duration)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in key(press, track: track, grid: grid) }
        .alert(largeChange.map { String(format: "Change the tempo from %.2f to %.2f BPM?", $0.from, $0.to) } ?? "",
               isPresented: Binding(get: { largeChange != nil }, set: { if !$0 { largeChange = nil } }),
               presenting: largeChange) { change in
            Button("Change Tempo") {
                if let track = library.track(trackID) { setBPM(change.to, track) }
                largeChange = nil
            }
            Button("Cancel", role: .cancel) { largeChange = nil }
        } message: { change in
            Text(String(format: "That is %.0f %% %@ than now. Clips of this track in a mix change their length with the tempo - if the tempo is an octave out, Correct BPM… is the safer way.",
                        abs(change.to / change.from - 1) * 100, change.to > change.from ? "faster" : "slower"))
        }
        .onAppear {
            preview.setGrid(bpm: bpm, firstBeatSeconds: first)
            showSeconds = first
            focused = true
        }
        .task {
            // A popover needs its anchor on screen; give the pane a moment.
            guard correctBPM else { return }
            try? await Task.sleep(for: .milliseconds(300))
            showBPMPanel = true
        }
        // The tempo only sets how far apart two onsets must be, so a nudge
        // does not measure again; an octave change does.
        // Its audio may have gone to the cache's size limit: decoded first,
        // and the kicks measured once it is there.
        .task(id: trackID) { library.prepare([trackID], first: true) }
        .task(id: [Int(bpm.rounded()), library.audio(for: trackID) == nil ? 0 : 1]) {
            guard let audio = library.audio(for: trackID) else { return }
            let tempo = bpm
            onsets = await Task.detached(priority: .userInitiated) {
                TempoAnalyzer.kicks(audio, bpm: tempo)
            }.value
        }
        .onChange(of: cycle) { applyCycle() }
        .onChange(of: region) { applyCycle() }
        // Back from the bar, the keys should work at once - 1…8, I, O.
        .onChange(of: hidden) { _, hidden in
            if !hidden { focused = true }
        }
        .onDisappear {
            preview.stop()
            preview.clickEnabled = false
        }
    }

    // MARK: - Header

    /// The track, how the grid came about - analyser, confidence, edited or
    /// not - and what can be done about it: the Analysis menu, and Done.
    private func header(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Text("Beatgrid")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(track.title).font(.headline).lineLimit(1)
                if let artist = track.artist {
                    Text(artist).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            statusChip(track)
            Text(track.isCorrected ? "Edited by hand" : "As analysed")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            analysisMenu(track)
            // No Return shortcut: Return adds tracks from the library and
            // confirms typed tempos, and must not close the drawer as well.
            Button("Done") { close() }
                .help("Close the beatgrid editor (Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .barSurface()
    }

    /// Which analyser found the grid and how sure it was, coloured by that:
    /// green from 80 %, yellow from 50 %, red below.
    @ViewBuilder
    private func statusChip(_ track: Track) -> some View {
        if let analysis = track.analysis {
            let confidence = analysis.confidence
            let color: Color = confidence >= 0.8 ? Color(red: 0.3, green: 0.8, blue: 0.4)
                : confidence >= 0.5 ? Color(red: 0.95, green: 0.8, blue: 0.2) : Color(red: 0.95, green: 0.3, blue: 0.3)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(analysis.analyser.title) · \(Int(confidence * 100)) % confidence")
                    .monospacedDigit()
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .help(String(format: "As analysed: %.3f BPM, bar one at %.3f s", analysis.bpm, analysis.firstBeatSeconds))
        } else if track.state == .failed {
            Label("Analysis failed: \(track.failure ?? "unknown reason"). Set the tempo by hand or tap it.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else {
            Text("Not analysed yet").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Everything that runs the analysis again or goes back to it, in one
    /// place - and which of them overwrites the hand's work, said in the
    /// title.
    private func analysisMenu(_ track: Track) -> some View {
        let current = track.bpm ?? 120
        let mix = session.document.masterBPM ?? session.document.projectBPM
        return Menu("Analysis") {
            Button(String(format: "Re-analyse near Mix Tempo (%.1f BPM)", mix)) {
                library.reanalyse(trackID, nearBPM: mix, clearCorrection: true)
            }
            Button(String(format: "Re-analyse near %.1f BPM", current)) {
                library.reanalyse(trackID, nearBPM: current, clearCorrection: true)
            }
            Button("Correct BPM…") { showBPMPanel = true }
            Divider()
            Button("Revert to Analysis") { library.resetCorrection(trackID) }
                .disabled(!track.isCorrected || track.analysis == nil)
        }
        .fixedSize()
        .help("Run the analysis again with the analyser chosen in Settings, searching only close to a tempo - this replaces the grid edited by hand - or go back to the analysis as it was")
    }

    // MARK: - Left column

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Tempo and bar one, each one value between − and +, and the grid
    /// moved by whole beats.
    private func gridSection(_ track: Track, bpm: Double, first: Double) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Grid")
            StepperRow(title: "Tempo", hint: "Step 0.01 · ⇧ 0.1",
                       decreaseLabel: "Tempo down", increaseLabel: "Tempo up") { direction, coarse in
                setBPM(bpm + Double(direction) * (coarse ? 0.1 : 0.01), track)
            } value: {
                BPMField(value: bpm, fractionDigits: 3, width: 78, showsSet: false) { value in
                    if track.bpm != nil && BPMInput.isLargeChange(from: bpm, to: value) {
                        largeChange = LargeChange(from: bpm, to: value)
                    } else {
                        setBPM(value, track)
                    }
                }
            }
            StepperRow(title: "Bar 1 at", hint: "Step 1 ms · ⇧ 10 ms",
                       decreaseLabel: "Bar one earlier", increaseLabel: "Bar one later") { direction, coarse in
                setFirstBeat(first + Double(direction) * (coarse ? 0.010 : 0.001), track)
            } value: {
                StepperValue(text: String(format: "%.3f s", first), width: 78)
            }
            HStack(spacing: 6) {
                Text("Shift grid").foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("◀ 1 beat") { shiftBeat(-1, track) }
                    .help("Bar one a beat earlier")
                Button("1 beat ▶") { shiftBeat(1, track) }
                    .help("Bar one a beat later - when the grid's one is really the two")
            }
            Button("Correct BPM…") { showBPMPanel = true }
                .frame(maxWidth: .infinity)
                .help("Tap along to check the tempo, then pick half, as measured or double")
                .popover(isPresented: $showBPMPanel, arrowEdge: .trailing) {
                    BPMCorrectionPanel(detected: track.analysis?.bpm ?? track.bpm,
                                       sourceLabel: sourceLabel(track)) { value in
                        setBPM(value, track)
                        showBPMPanel = false
                    } accessory: {
                        playButton(bpm: bpm, first: first)
                            .controlSize(.small)
                    }
                }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Cue points, the marked stretch, and the loop made of it - what the
    /// drawer is opened for when the grid is already right.
    private func cueSection(_ track: Track, grid: SourceGrid) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("Cues & loops")
                Spacer()
                Button("Clear cues") { library.clearCues(trackID) }
                    .buttonStyle(.borderless)
                    .disabled(track.cuePoints.isEmpty)
                    .help("Take every cue point off this track")
            }
            HStack(spacing: 4) {
                ForEach(Array(CueRules.numbers), id: \.self) { number in
                    cueButton(number, track: track, grid: grid)
                }
            }
            Text(regionLabel(grid))
                .foregroundStyle(region == nil ? .secondary : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .help("Drag in the strip to mark a stretch, or I and O at the selected line or while it plays")
            HStack(spacing: 6) {
                Text("Repeat").foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Picker("Repeat", selection: $repeats) {
                    ForEach([1, 2, 4, 8, 16, 32], id: \.self) { Text("× \($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("How often the loop repeats")
            }
            HStack(spacing: 6) {
                Button("Loop at End") { loop(atPlayhead: false) }
                    .frame(maxWidth: .infinity)
                    .help("Put the marked stretch at the end of the mix as a loop, with the current beatmix")
                Button("Loop at Playhead") { loop(atPlayhead: true) }
                    .frame(maxWidth: .infinity)
                    .help("Put the marked stretch into the mix at the playhead as a loop")
            }
            .disabled(region == nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func cueButton(_ number: Int, track: Track, grid: SourceGrid) -> some View {
        let set = CueRules.cue(track.cuePoints, number: number) != nil
        return Button {
            if NSEvent.modifierFlags.contains(.option) {
                library.setCue(trackID, number: number, seconds: nil)
            } else {
                cue(number, track: track, grid: grid)
            }
        } label: {
            Text("\(number)").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(set ? Color(red: 0.2, green: 0.75, blue: 0.5) : nil)
        .help(set ? "Go to cue \(number) · ⌥-click to remove it"
                  : "Set cue \(number) where the song is now (\(number))")
        .contextMenu {
            Button("Set Here") { library.setCue(trackID, number: number, seconds: spot(track, grid: grid)) }
            Button("Go To") { goTo(CuePoint(number: number, seconds: cueSeconds(track, number)), grid: grid) }
                .disabled(!set)
            Button("Remove") { library.setCue(trackID, number: number, seconds: nil) }
                .disabled(!set)
        }
    }

    // MARK: - Strip

    /// Above the strip: listening, the legend for what the strip draws, and
    /// how much of the song it shows. Where the drawer is too narrow for all
    /// of it, the legend goes first, then the word "Window" - never the
    /// controls themselves.
    private func waveToolbar(bpm: Double, first: Double, grid: SourceGrid) -> some View {
        ViewThatFits(in: .horizontal) {
            waveToolbarRow(bpm: bpm, first: first, grid: grid, legend: true, windowLabel: true)
            waveToolbarRow(bpm: bpm, first: first, grid: grid, legend: false, windowLabel: true)
            waveToolbarRow(bpm: bpm, first: first, grid: grid, legend: false, windowLabel: false)
            waveToolbarRow(bpm: bpm, first: first, grid: grid, legend: false, windowLabel: false, compact: true)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
    }

    /// `compact`: symbols instead of words, for the narrowest drawer; the
    /// words stay in the help tags.
    private func waveToolbarRow(bpm: Double, first: Double, grid: SourceGrid,
                                legend showLegend: Bool, windowLabel: Bool, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            playButton(bpm: bpm, first: first, compact: compact)
            Toggle(isOn: $cycle) {
                Label("Cycle", systemImage: "repeat")
                    .labelStyle(.adaptive(iconOnly: compact))
            }
            .toggleStyle(.button)
            .disabled(region == nil)
            .help(region == nil ? "Mark a stretch to play it round and round"
                                : "Play the marked stretch round and round · ← → move its start, ⌥← ⌥→ its end, ⇧ by a bar")
            if compact {
                Toggle(isOn: Binding(get: { preview.clickEnabled }, set: { preview.clickEnabled = $0 })) {
                    Image(systemName: "metronome")
                }
                .toggleStyle(.button)
                .help("Metronome: click along with the preview")
                .accessibilityLabel("Metronome")
            } else {
                Toggle("Metronome", isOn: Binding(get: { preview.clickEnabled }, set: { preview.clickEnabled = $0 }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            if showLegend {
                Divider().frame(height: 14)
                legend
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if windowLabel {
                    Text("Window").foregroundStyle(.secondary)
                }
                Picker("Window", selection: $span) {
                    ForEach(Self.spans, id: \.self) { Text(compact ? "\(Int($0))" : "±\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .help("How much of the song the strip shows, either side of the middle, in seconds")
            playheadButton(grid: grid, compact: compact)
        }
    }

    /// What the strip's marks mean, drawn as the strip draws them.
    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("Bar") { Rectangle().fill(StripColors.bar).frame(width: 2, height: 12) }
            legendItem("Beat") { Rectangle().fill(StripColors.beat).frame(width: 1, height: 12) }
            legendItem("Bar 1") { Rectangle().fill(StripColors.barOne).frame(width: 2, height: 12) }
            legendItem("Off-grid kick") { Circle().fill(StripColors.offGrid).frame(width: 6, height: 6) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func legendItem(_ title: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 5) {
            mark()
            Text(title)
        }
    }

    /// Jumps the view to the spot of the song that lies under the
    /// timeline's playhead. Only while a clip of this track is there -
    /// otherwise this song is not playing at the playhead and there is
    /// nowhere to jump to. The marked stretch stays where it is; only the
    /// view and the selected line move.
    private func playheadButton(grid: SourceGrid, compact: Bool = false) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let seconds = session.document.sourceSeconds(ofTrack: trackID, atBeat: session.playheadBeat(),
                                                         grids: session.grids)
            Button {
                guard let seconds else { return }
                centreSeconds = seconds
                selectedLine = BeatLines.nearestLine(to: seconds, bpm: grid.bpm, firstBeat: grid.firstBeatSeconds)
            } label: {
                Label("Center Playhead", systemImage: "scope")
                    .labelStyle(.adaptive(iconOnly: compact))
            }
            .fixedSize()
            .disabled(seconds == nil)
            .help(seconds == nil ? "The timeline's playhead is not over a clip of this song"
                                 : "Show the spot under the timeline's playhead")
        }
    }

    /// Under the strip: the grid's fit over the whole song, which is also
    /// the overview to drag the view along, and what it found in words.
    private func fitRow(_ track: Track, bpm: Double, first: Double, duration: Double) -> some View {
        let fit = onsets.isEmpty ? nil
            : GridFit.summary(kicks: onsets, bpm: bpm, firstBeat: first, duration: duration)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Grid fit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                GridFitBar(summary: fit, duration: duration, visibleStart: visibleRange.lowerBound,
                           visibleLength: visibleRange.upperBound - visibleRange.lowerBound) { seconds in
                    centreSeconds = seconds
                } onEnd: { seconds in
                    selectedLine = BeatLines.nearestLine(to: seconds, bpm: bpm, firstBeat: first)
                }
                .frame(height: 14)
                Text("Drag to navigate")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if let fit {
                fitNotes(fit, track: track, first: first, duration: duration)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// What the fit bar found, in words, with the fix that exists for it.
    @ViewBuilder
    private func fitNotes(_ fit: GridFit.Summary, track: Track, first: Double, duration: Double) -> some View {
        if let baseline = fit.alignment {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
                Text(String(format: "The kicks sit %.0f ms %@ the grid throughout.",
                            abs(baseline) * 1000, baseline > 0 ? "after" : "before"))
                Button("Align to Kicks") { setFirstBeat(first + baseline, track) }
                    .help(String(format: "Move bar one %+.0f ms, onto the kicks", baseline * 1000))
            }
            .font(.callout)
        }
        if let intro = fit.intro, let to = intro.to {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(String(format: "Until %@ the kicks sit beside the grid (%+.0f ms, later %+.0f ms) - the intro is played differently or in another tempo.",
                            Self.clock(to), intro.firstOffset * 1000, intro.lastOffset * 1000))
                    .lineLimit(1)
                Button("Show") { showSeconds = intro.from }
            }
            .font(.callout)
        }
        if let drift = fit.drift {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(String(format: "From %@ the kicks drift away from the grid (%+.0f ms, later %+.0f ms). One tempo cannot follow that - fit the grid to the part you will mix.",
                            Self.clock(drift.from), drift.firstOffset * 1000, drift.lastOffset * 1000))
                    .lineLimit(1)
                Button("Show") { showSeconds = drift.from }
            }
            .font(.callout)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Keys

    /// The keys the pane takes while it has the focus. Space is handed on to
    /// the mix on purpose: it means the same thing in every part of the
    /// window, and an editor that quietly took it away would be the one
    /// place where it did not.
    private func key(_ press: KeyPress, track: Track, grid: SourceGrid) -> KeyPress.Result {
        // Folded away it may still hold the focus - it was just pressed E in.
        // Then only E (back) and Space (the mix) mean anything: a cue set
        // with 3 in a pane nobody can see would be a mark set by accident.
        if hidden {
            switch press.key.character {
            case "e", "E": hide()
            case " ": session.togglePlay()
            default: return .ignored
            }
            return .handled
        }
        switch press.key.character {
        case KeyEquivalent.escape.character:
            close()
        case " ":
            session.togglePlay()
        case KeyEquivalent.leftArrow.character, KeyEquivalent.rightArrow.character:
            let direction = press.key.character == KeyEquivalent.leftArrow.character ? -1 : 1
            if cycling {
                moveLoopEdge(end: press.modifiers.contains(.option),
                             by: direction * (press.modifiers.contains(.shift) ? Clip.beatsPerBar : 1), grid: grid)
            } else {
                step(direction, grid: grid)
            }
        case "e", "E":
            hide()
        case "p", "P":
            togglePreview(bpm: grid.bpm, first: grid.firstBeatSeconds)
        case "i", "I":
            setRegionEdge(start: true, grid: grid, track: track)
        case "o", "O":
            setRegionEdge(start: false, grid: grid, track: track)
        default:
            guard let number = press.key.character.wholeNumberValue, CueRules.numbers.contains(number) else {
                return .ignored
            }
            if press.modifiers.contains(.option) {
                library.setCue(trackID, number: number, seconds: nil)
            } else {
                cue(number, track: track, grid: grid)
            }
        }
        return .handled
    }

    /// Going round the stretch right now - what turns the arrows from the
    /// selected line to the loop's ends.
    private var cycling: Bool {
        cycle && region != nil && preview.isPlaying && preview.trackID == trackID
    }

    /// One end of the loop a number of beats on, the other where it is; a
    /// beat apart at least, and inside the song. The playback follows at
    /// once through `.onChange(of: region)`.
    private func moveLoopEdge(end: Bool, by beats: Int, grid: SourceGrid) {
        guard let region else { return }
        let beat = 60 / max(grid.bpm, 1)
        let shift = Double(beats) * beat
        if end {
            let to = min(max(region.endSeconds + shift, region.startSeconds + beat), grid.durationSeconds)
            self.region = LoopRegion(from: region.startSeconds, to: to)
            showSeconds = to
        } else {
            let to = max(min(region.startSeconds + shift, region.endSeconds - beat), 0)
            self.region = LoopRegion(from: to, to: region.endSeconds)
            showSeconds = to
        }
    }

    private func step(_ direction: Int, grid: SourceGrid) {
        selectedLine += direction
        showSeconds = BeatLines.time(ofLine: selectedLine, bpm: grid.bpm, firstBeat: grid.firstBeatSeconds)
    }

    // MARK: - Cue points

    /// Where the song is now: what is being heard while it plays, and the
    /// selected gridline while it does not.
    private func spot(_ track: Track, grid: SourceGrid) -> Double {
        if preview.isPlaying, preview.trackID == trackID {
            return min(max(0, preview.positionSeconds - preview.outputLatency), grid.durationSeconds)
        }
        return BeatLines.time(ofLine: selectedLine, bpm: grid.bpm, firstBeat: grid.firstBeatSeconds)
    }

    private func cueSeconds(_ track: Track, _ number: Int) -> Double {
        CueRules.cue(track.cuePoints, number: number)?.seconds ?? 0
    }

    /// A number that is free sets a cue; a number that is taken goes there.
    private func cue(_ number: Int, track: Track, grid: SourceGrid) {
        if let existing = CueRules.cue(track.cuePoints, number: number) {
            goTo(existing, grid: grid)
        } else {
            library.setCue(trackID, number: number, seconds: max(0, spot(track, grid: grid)))
        }
    }

    private func goTo(_ cue: CuePoint, grid: SourceGrid) {
        selectedLine = BeatLines.nearestLine(to: cue.seconds, bpm: grid.bpm, firstBeat: grid.firstBeatSeconds)
        showSeconds = cue.seconds
        if preview.isPlaying, preview.trackID == trackID {
            preview.seek(toSeconds: cue.seconds)
        }
    }

    // MARK: - The marked stretch

    private func regionLabel(_ grid: SourceGrid) -> String {
        guard let region else { return "No stretch marked" }
        let beats = region.beats(in: grid)
        let bars = Double(beats) / Double(Clip.beatsPerBar)
        return String(format: "%@ – %@ · %d beats%@", Self.clock(region.startSeconds), Self.clock(region.endSeconds),
                      beats, bars == bars.rounded() ? String(format: " · %.0f bars", bars) : "")
    }

    /// I and O, as in a DAW: the mark begins here, or ends here.
    private func setRegionEdge(start: Bool, grid: SourceGrid, track: Track) {
        let here = spot(track, grid: grid)
        let beat = 60 / max(grid.bpm, 1)
        let line = grid.firstBeatSeconds + ((here - grid.firstBeatSeconds) / beat).rounded() * beat
        let other = region.map { start ? $0.endSeconds : $0.startSeconds } ?? (start ? line + 4 * beat : line - 4 * beat)
        region = LoopRegion(from: line, to: other).clamped(to: grid.durationSeconds)
    }

    private func loop(atPlayhead: Bool) {
        guard let region else { return }
        session.addLoop(trackID, region: region, repeats: repeats,
                        beatmix: session.beatmixLength, atPlayhead: atPlayhead)
    }

    // MARK: - Changes

    private func setBPM(_ value: Double, _ track: Track) {
        let bpm = min(max(value, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound)
        library.setCorrection(trackID, bpm: bpm, firstBeatSeconds: track.firstBeatSeconds ?? 0)
        preview.setGrid(bpm: bpm, firstBeatSeconds: track.firstBeatSeconds ?? 0)
    }

    private func setFirstBeat(_ seconds: Double, _ track: Track) {
        let first = min(max(0, seconds), max(0, track.durationSeconds))
        library.setCorrection(trackID, bpm: track.bpm ?? 120, firstBeatSeconds: first)
        preview.setGrid(bpm: track.bpm ?? 120, firstBeatSeconds: first)
    }

    /// Moves bar one by whole beats; a move before the start of the file
    /// wraps forward by a bar, which names the same grid. The selection
    /// keeps its place in the music, so its index moves the other way.
    private func shiftBeat(_ beats: Int, _ track: Track) {
        let beat = 60 / (track.bpm ?? 120)
        var first = (track.firstBeatSeconds ?? 0) + Double(beats) * beat
        var moved = beats
        if first < 0 {
            first += 4 * beat
            moved += 4
        }
        setFirstBeat(first, track)
        selectedLine -= moved
    }

    // MARK: - Listening

    private func togglePreview(bpm: Double, first: Double) {
        if preview.isPlaying, preview.trackID == trackID {
            preview.stop()
        } else if let audio = library.audio(for: trackID) {
            session.pauseForEditorPreview()
            let line = BeatLines.time(ofLine: selectedLine, bpm: bpm, firstBeat: first)
            let from = cycle ? region?.startSeconds ?? line : line
            preview.setGrid(bpm: bpm, firstBeatSeconds: first)
            preview.play(audio, track: trackID, fromSeconds: max(0, from))
            applyCycle()
        }
    }

    /// Hands the cycle to a running preview, or takes it away. With no
    /// stretch left to go round, Cycle switches itself off.
    private func applyCycle() {
        if region == nil, cycle { cycle = false }
        guard preview.isPlaying, preview.trackID == trackID else { return }
        if cycle, let region {
            preview.setLoop(startSeconds: region.startSeconds, endSeconds: region.endSeconds)
        } else {
            preview.clearLoop()
        }
    }

    private func playButton(bpm: Double, first: Double, compact: Bool = false) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let playing = preview.isPlaying && preview.trackID == trackID
            Button {
                togglePreview(bpm: bpm, first: first)
            } label: {
                Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
                    .labelStyle(.adaptive(iconOnly: compact))
            }
            .fixedSize()
            .help(cycle ? "Play the marked stretch round and round (P) - the timeline stops"
                        : "Play from the selected gridline (P) - the timeline stops")
        }
    }

    private func sourceLabel(_ track: Track) -> String {
        guard track.analysis != nil else { return "No analysis" }
        if let manual = track.manualBPM {
            return String(format: "Automatic analysis · now %.2f by hand", manual)
        }
        return "Automatic analysis"
    }
}

/// The whole track, one cell per `GridFit` window: green where the kicks sit
/// on the lines, yellow and red as they move off, grey where the kick is not
/// steady, empty where there is none. It is also the strip's overview: the
/// frame is what the strip shows, and a click or a drag moves it there.
struct GridFitBar: View {
    let summary: GridFit.Summary?
    let duration: Double
    let visibleStart: Double
    let visibleLength: Double
    /// The spot to put in the middle of the strip, while dragging.
    let onScrub: (Double) -> Void
    /// Where the drag let go.
    let onEnd: (Double) -> Void

    /// Offsets up to this are on the lines: the kick timing itself is good
    /// to a few milliseconds.
    static let onLine = 0.010

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let scale = size.width / CGFloat(max(duration, 1))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
                for window in summary?.windows ?? [] where window.heard {
                    let rect = CGRect(x: CGFloat(window.start) * scale, y: 2,
                                      width: max(1, CGFloat(window.end - window.start) * scale - 1),
                                      height: size.height - 4)
                    context.fill(Path(rect), with: .color(Self.color(window)))
                }
                let visible = CGRect(x: CGFloat(visibleStart) * scale, y: 0.5,
                                     width: max(2, CGFloat(visibleLength) * scale), height: size.height - 1)
                context.stroke(Path(visible), with: .color(.white), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in onScrub(seconds(value.location.x, width: geometry.size.width)) }
                    .onEnded { value in onEnd(seconds(value.location.x, width: geometry.size.width)) }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .help(summary == nil ? "Measuring the kicks… Drag to move the view along the song."
              : "How well the grid holds, eight bars at a time: green on the kicks, yellow and red beside them, grey without a steady kick. The frame is what the strip shows: click or drag to move it.")
    }

    private func seconds(_ x: CGFloat, width: CGFloat) -> Double {
        min(max(Double(x / max(width, 1)), 0), 1) * duration
    }

    static func color(_ window: GridFit.Window) -> Color {
        guard window.isSteady else { return Color(white: 0.4) }
        let off = abs(window.offset)
        if off <= onLine { return Color(red: 0.3, green: 0.8, blue: 0.4) }
        if off <= GridFit.driftBeyond { return Color(red: 0.95, green: 0.8, blue: 0.2) }
        return Color(red: 0.95, green: 0.3, blue: 0.3)
    }
}

/// A label with its title, or - where there is no room - only its symbol.
struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
            .fixedSize()
        }
    }
}

extension LabelStyle where Self == AdaptiveLabelStyle {
    static func adaptive(iconOnly: Bool) -> AdaptiveLabelStyle { AdaptiveLabelStyle(iconOnly: iconOnly) }
}
