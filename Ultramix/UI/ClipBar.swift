//
//  ClipBar.swift
//  Ultramix
//
//  The strip under the timeline, in two rows: on top the selected clip - which
//  track, where it sits, its beatgrid, its lock - how dragging moves clips,
//  and the mix's length; below, its tempo target, gain, key and fine tune,
//  stems, loop, mute and
//  transition, and a warning when its tempo leaves what the stretcher can do.
//  With nothing selected, the handful of keys worth knowing.
//

import SwiftUI

struct ClipBar: View {
    let session: MixSession
    let library: Library

    @AppStorage(LoudnessTarget.enabledKey) private var targetEnabled = false
    @AppStorage(LoudnessTarget.lufsKey) private var targetLUFS = LoudnessTarget.defaultLUFS
    private var target: Double? { targetEnabled ? LoudnessTarget.clamped(targetLUFS) : nil }

    var body: some View {
        Group {
            if session.selection.count == 1, let id = session.selection.first,
               let clip = session.document.clips.first(where: { $0.id == id }),
               let track = library.track(clip.trackID) {
                clipRows(clip, track)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Text(session.selection.isEmpty
                             ? "Drag tracks from the library onto a lane."
                             : "\(session.selection.count) clips selected")
                            .foregroundStyle(.secondary)
                        columnRule
                        beatgridButton
                        columnRule
                        movePicker
                        Spacer(minLength: 8)
                        summaryText
                    }
                    .frame(height: Self.rowHeight)
                    Divider()
                    HStack {
                        if session.selection.isEmpty {
                            Text("Space plays · B splits at the playhead · L loops · M mutes · ← → scroll · ⌥← ⌥→ move a clip a beat · ⌥-drag a tempo point to move it")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: Self.rowHeight)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 76)
        .background(.bar)
    }

    private static let rowHeight: CGFloat = 37.5

    /// Opens the beatgrid of the clip or library track picked last, and
    /// with the pane already on it, folds it away and back. Lit while the
    /// pane shows that track.
    private var beatgridButton: some View {
        let target = session.beatgridTarget
        let showing = target != nil && session.beatgridRequest?.id == target && !session.beatgridHidden
        let name = target.flatMap { library.track($0)?.displayName }
        return Toggle(isOn: Binding(get: { showing }, set: { _ in session.beatgridButton() })) {
            Text("Beatgrid")
        }
        .toggleStyle(.button)
        .disabled(target == nil)
        .help(name.map { "Beatgrid of \($0) - click again to fold it away and back (E)" }
              ?? "Select a clip, or one track in the library, to edit its beatgrid")
    }

    private var summaryText: some View {
        Text(summary)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    /// The name sits over the tempo and is exactly as wide - it is laid over
    /// an invisible copy of the tempo controls and truncates within them -
    /// so "Bar one" lines up with Gain whatever the title's length.
    private func clipRows(_ clip: Clip, _ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) { tempo(clip, track) }
                    .hidden()
                    .disabled(true)
                    .accessibilityHidden(true)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 12) {
                            Circle().fill(LaneStyle.color(clip.lane, session.document.lanes)).frame(width: 9, height: 9)
                            Text(session.selectedPart.map { "\(track.displayName) — \($0.name.capitalized)" } ?? track.displayName)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .help(session.selectedPart.map { "The \($0.name) of \(track.displayName): gain and mute work on this stem" }
                                      ?? track.displayName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                columnRule
                Text("Bar one at \(barBeat(clip.anchorBeat))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help("Where the track's first downbeat sits on the timeline. ← → move the clip a beat.")
                beatgridButton
                columnRule
                Toggle(isOn: Binding(get: { clip.locked },
                                     set: { value in session.perform { $0.setLocked(clip.id, value) } })) {
                    // A fixed box: the open lock is wider than the closed one,
                    // and everything after the button would shift.
                    HStack(spacing: 5) {
                        Image(systemName: clip.locked ? "lock.fill" : "lock.open").frame(width: 14)
                        Text("Lock")
                    }
                }
                .toggleStyle(.button)
                .help(clip.locked ? "Locked: the clip cannot be moved and its automation cannot be changed. Click to unlock."
                                  : "Lock the clip: its place and its automation")
                columnRule
                movePicker
                Spacer(minLength: 8)
                summaryText
            }
            .frame(height: Self.rowHeight)
            Divider()
            HStack(spacing: 12) {
                tempo(clip, track)
                columnRule
                controls(clip, track)
                Spacer(minLength: 0)
            }
            .frame(height: Self.rowHeight)
        }
    }

    /// How dragging moves clips - for every clip, so it shows whatever is
    /// selected.
    private var movePicker: some View {
        HStack(spacing: 8) {
            Text("Move").foregroundStyle(.secondary).fixedSize()
            Picker("Move", selection: Binding(get: { session.moveMode }, set: { session.moveMode = $0 })) {
                ForEach(MoveMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .fixedSize()
        }
        .help("What a dragged clip snaps to: Off does not move clips, Free any beat, Half every half bar, Full bar lines. ← → still move a beat.")
    }

    private var columnRule: some View {
        Divider().frame(height: 18)
    }

    /// Under the name: the clip's tempo target.
    @ViewBuilder
    private func tempo(_ clip: Clip, _ track: Track) -> some View {
        let native = track.bpm ?? 0
        // Under a locked master the point's own tempo is kept but not heard;
        // changing it there would be an edit nobody can hear.
        let master = session.document.masterLocked ? session.document.masterBPM : nil
        Text("Tempo at its point").foregroundStyle(.secondary)
        BPMField(value: clip.targetBPM ?? native, fractionDigits: 2, width: 70) { value in
            session.perform { $0.setTargetBPM(clip.id, abs(value - native) < 0.0005 ? nil : value) }
        }
        .disabled(master != nil)
        Button("Native \(String(format: "%.2f", native))") {
            session.perform { $0.setTargetBPM(clip.id, nil) }
        }
        .disabled(clip.targetBPM == nil || master != nil)
        .help("Let the mix reach the track's own tempo at this clip")
        if let master {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .help(String(format: "Master tempo is locked at %.2f BPM. Unlock it at the tempo strip to change this point.", master))
        }
    }

    /// Under "Bar one": level, key, loop and mute, transition. With a stem
    /// row picked in an expanded lane, the gain and mute are that stem's.
    @ViewBuilder
    private func controls(_ clip: Clip, _ track: Track) -> some View {
        let part = session.selectedPart
        let gainDB = part.map { clip.parts[$0].gainDB } ?? clip.gainDB
        let whose = part.map { "The \($0.name)'s" } ?? "Clip"
        Text(part.map { "\($0.name.capitalized) gain" } ?? "Gain").foregroundStyle(.secondary)
        Button { stepGain(clip, part, by: -1) } label: {
            stepIcon("minus")
        }
        .disabled(gainDB.rounded() <= Clip.gainRange.lowerBound)
        .help("\(whose) gain 1 dB quieter")
        .accessibilityLabel("Gain down")
        // A fixed width, so the buttons stay put between "-9 dB" and "-10 dB".
        Text(Self.gainLabel(gainDB))
            .monospacedDigit()
            .frame(width: 46)
            .help(part != nil ? "The stem's level change, −24 to +12 dB, before the clip's gain; 0 dB plays it as it is"
                  : target.map { "Offset from the \(String(format: "%.1f", $0)) LUFS target, −24 to +12 dB in all; 0 dB plays the clip at the target" }
                  ?? "The clip's level change, −24 to +12 dB; 0 dB plays it as it is")
        Button { stepGain(clip, part, by: 1) } label: {
            stepIcon("plus")
        }
        .disabled(gainDB.rounded() >= Clip.gainRange.upperBound)
        .help("\(whose) gain 1 dB louder")
        .accessibilityLabel("Gain up")
        loudness(clip)
        Divider().frame(height: 18)
        key(clip, track)
        Divider().frame(height: 18)
        stems(clip)
        Toggle("Loop", isOn: Binding(get: { clip.looping },
                                     set: { value in session.perform { $0.setLooping(clip.id, value) } }))
            .toggleStyle(.checkbox)
        Toggle("Mute", isOn: Binding(get: { part.map { clip.parts[$0].muted } ?? clip.muted },
                                     set: { value in
                                         session.perform { document in
                                             if let part { document.setPartMuted(clip.id, part, value) } else { document.setMuted(clip.id, value) }
                                         }
                                     }))
            .toggleStyle(.checkbox)
            .help(part.map { "Mute the \($0.name) of this clip" } ?? "Mute the clip")
        Divider().frame(height: 18)
        Menu {
            ForEach(TransitionStyle.allCases) { style in
                Button(style.title) { session.autoCrossfade(style) }
            }
        } label: {
            Label(session.transitionStyle.title, systemImage: "arrow.left.arrow.right")
        } primaryAction: {
            session.autoCrossfade()
        }
        .fixedSize()
        .help("\(session.transitionStyle.title) over this clip's overlaps with clips on other lanes; the arrow picks another transition")
        if session.plan?.outOfRange.contains(clip.id) == true {
            Label("Tempo outside 0.5×–2× of the track", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    /// Semitones up or down, and the key that makes - in Camelot, which is
    /// what a DJ matches by - then the fine tune in cents. A shift plays once
    /// it is rendered; until then the clip plays as it is, and a spinner says
    /// so.
    @ViewBuilder
    private func key(_ clip: Clip, _ track: Track) -> some View {
        Text("Key").foregroundStyle(.secondary)
        Button { session.perform { $0.stepKeyShift(clip.id, by: -1) } } label: {
            stepIcon("minus")
        }
        .disabled(clip.keyShift <= Clip.keyShiftRange.lowerBound)
        .help("Play the clip a semitone lower")
        .accessibilityLabel("Key down")
        Text(Self.keyLabel(clip.keyShift, track.key?.key))
            .monospacedDigit()
            .frame(width: 70)
            .help(track.key.map { "\($0.key.name) (\($0.key.camelot)) as analysed; the length and the beatgrid stay as they are" }
                  ?? "Semitones up or down, −6 to +6; the length and the beatgrid stay as they are")
        Button { session.perform { $0.stepKeyShift(clip.id, by: 1) } } label: {
            stepIcon("plus")
        }
        .disabled(clip.keyShift >= Clip.keyShiftRange.upperBound)
        .help("Play the clip a semitone higher")
        .accessibilityLabel("Key up")
        Text("Fine").foregroundStyle(.secondary)
        Button { session.perform { $0.stepFineTune(clip.id, by: -1) } } label: {
            stepIcon("minus")
        }
        .disabled(clip.fineTune <= Clip.fineTuneRange.lowerBound)
        .help("Tune the clip 5 cents lower")
        .accessibilityLabel("Fine tune down")
        Text(Self.fineLabel(clip.fineTune))
            .monospacedDigit()
            .frame(width: 46)
            .help("Cents on top of the key, −50 to +50 in steps of 5 - for a record a little off concert pitch")
        Button { session.perform { $0.stepFineTune(clip.id, by: 1) } } label: {
            stepIcon("plus")
        }
        .disabled(clip.fineTune >= Clip.fineTuneRange.upperBound)
        .help("Tune the clip 5 cents higher")
        .accessibilityLabel("Fine tune up")
        if !clip.pitch.isNone, library.shifting.contains(Library.ShiftKey(track: clip.trackID, pitch: clip.pitch)) {
            ProgressView()
                .controlSize(.small)
                .help("Rendering the pitch shift; the clip plays unshifted until it is ready")
        }
    }

    /// While the song is being separated, how far that has got, and a
    /// spinner while its stems are decoded or shifted - the clip plays the
    /// whole song until they are there.
    @ViewBuilder
    private func stems(_ clip: Clip) -> some View {
        if let fraction = library.separating[clip.trackID] {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help("Separating the song into stems: \(Int(fraction * 100)) %. The clip plays the whole song until they are ready.")
        } else if clip.parts.playsStems,
                  library.shifting.contains(Library.ShiftKey(track: clip.trackID, pitch: clip.pitch, stems: true)) {
            ProgressView()
                .controlSize(.small)
                .help("Preparing the stems; the clip plays the whole song until they are ready")
        }
    }

    private func stepGain(_ clip: Clip, _ part: Stem?, by steps: Int) {
        session.perform { document in
            if let part { document.stepPartGain(clip.id, part, by: steps) } else { document.stepGain(clip.id, by: steps) }
        }
    }

    /// "+15 ct", or "0 ct" in tune.
    static func fineLabel(_ cents: Int) -> String {
        cents == 0 ? "0 ct" : String(format: "%+d ct", cents)
    }

    /// "+2 · 10A", or "0" when the clip plays in its own key; the Camelot
    /// code only when the track's key is known.
    static func keyLabel(_ semitones: Int, _ key: MusicalKey?) -> String {
        let shift = semitones == 0 ? "0" : String(format: "%+d", semitones)
        guard let key else { return shift }
        return "\(shift) · \(key.transposed(by: semitones).camelot)"
    }

    /// Minus is a flat glyph: a button sized by it comes out lower than the
    /// plus beside it. Both get the same box.
    private func stepIcon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 12, height: 12)
    }

    /// The clip's loudness as it plays, and Match. Worked out on every
    /// redraw rather than stored: a lookup in the track's profile costs
    /// microseconds, and it can never be stale after a trim or a gain step.
    @ViewBuilder
    private func loudness(_ clip: Clip) -> some View {
        let grids = session.grids
        let profiles = library.loudness
        let target = target
        let own = ClipLoudness.lufs(clip, grids, { profiles[$0] }, target: target)
        let reference = session.document.matchReference(for: clip.id, grids: grids)
        let referenceLUFS = reference.flatMap { ClipLoudness.lufs($0, grids, { profiles[$0] }) }
        // A fixed width, like the gain, so Match stays put.
        Text(own.map { String(format: "%.1f LUFS", $0) } ?? "– LUFS")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 78, alignment: .leading)
            .help("Integrated loudness of the part of the song this clip plays, with the gain it plays with. The lane's volume, pan and filters are not included.")
        Button("Match") {
            session.perform { $0.matchGain(clip.id, grids: grids, loudness: { profiles[$0] }) }
        }
        .disabled(own == nil || referenceLUFS == nil || target != nil || session.selectedPart != nil)
        .help(matchHelp(reference, referenceLUFS))
    }

    private func matchHelp(_ reference: Clip?, _ referenceLUFS: Double?) -> String {
        if target != nil { return "Off while the loudness target is on (Settings)" }
        if session.selectedPart != nil { return "Matches the whole clip: pick the clip's own row" }
        guard let reference else { return "Nothing to match: no clip plays into this one or before it" }
        let name = library.track(reference.trackID)?.displayName ?? "the clip before"
        guard let referenceLUFS else { return "“\(name)” has not been measured yet" }
        return "Set the gain, to the whole dB, so this clip is as loud as “\(name)” (\(String(format: "%.1f", referenceLUFS)) LUFS)"
    }

    /// "0 dB", "-1 dB", "+3 dB": a gain with its sign, so louder and quieter
    /// read differently at a glance.
    static func gainLabel(_ dB: Double) -> String {
        let whole = Int(dB.rounded())
        return whole == 0 ? "0 dB" : String(format: "%+d dB", whole)
    }

    /// A timeline beat as bar.beat, counting from 1.1.
    private func barBeat(_ beat: Int) -> String {
        let bar = Int((Double(beat) / Double(Clip.beatsPerBar)).rounded(.down))
        let inBar = beat - bar * Clip.beatsPerBar
        return "\(bar + 1).\(inBar + 1)"
    }

    private var summary: String {
        let seconds = max(0, session.tempo.seconds(atBeat: session.endBeat))
        let clips = session.document.clips.count
        return "\(clips) clip\(clips == 1 ? "" : "s") · \(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
}
