//
//  ClipInspector.swift
//  Ultramix
//
//  The selected clip, on the right of the window, in sections by task: where
//  its grid sits, its tempo, its level, its key, its transition. It replaces
//  the two rows under the timeline that held all of it side by side, about
//  25 controls with nothing to say which belonged together.
//
//  With a stem row picked in an expanded lane, the level and mute are that
//  stem's. With a transition bar picked, the bar's own inspector shows
//  instead (TransitionInspector). With nothing picked, it offers the beatgrid
//  of the track selected in the library, if there is one.
//

import SwiftUI

struct ClipInspector: View {
    let session: MixSession
    let library: Library

    @AppStorage(LoudnessTarget.enabledKey) private var targetEnabled = false
    @AppStorage(LoudnessTarget.lufsKey) private var targetLUFS = LoudnessTarget.defaultLUFS
    private var target: Double? { targetEnabled ? LoudnessTarget.clamped(targetLUFS) : nil }

    var body: some View {
        // A picked transition bar lets go of the clips, so it comes first.
        if let mark = session.selectedMark {
            TransitionInspector(session: session, library: library, ref: mark)
        } else if session.selection.count == 1, let id = session.selection.first,
           let clip = session.document.clips.first(where: { $0.id == id }),
           let track = library.track(clip.trackID) {
            form(clip, track)
        } else if session.selection.count > 1 {
            ContentUnavailableView("\(session.selection.count) Clips Selected",
                                   systemImage: "square.stack",
                                   description: Text("Select one clip to see its grid, tempo, level and key."))
        } else {
            ContentUnavailableView {
                Label("No Clip Selected", systemImage: "square.dashed")
            } description: {
                Text("Click a clip on the timeline to see its grid, tempo, level and key.")
            } actions: {
                if let target = session.beatgridTarget, let name = library.track(target)?.displayName {
                    Button("Edit Beatgrid of “\(name)”…") { session.beatgridButton() }
                }
            }
        }
    }

    private func form(_ clip: Clip, _ track: Track) -> some View {
        Form {
            Section {
                header(clip, track)
            }
            Section("Grid") {
                LabeledContent("Bar 1 at") {
                    Text(barBeat(clip.anchorBeat)).monospacedDigit()
                }
                .help("Where the track's first downbeat sits on the timeline. ⌥← ⌥→ move the clip a beat.")
                Toggle(isOn: Binding(get: { clip.locked },
                                     set: { value in session.perform { $0.setLocked(clip.id, value) } })) {
                    Label("Locked", systemImage: clip.locked ? "lock.fill" : "lock.open")
                }
                .help(clip.locked ? "Locked: the clip cannot be moved and its automation cannot be changed."
                                  : "Lock the clip: its place and its automation")
                beatgridButton(track)
            }
            Section("Tempo") {
                tempo(clip, track)
            }
            Section("Level") {
                level(clip)
            }
            Section("Key") {
                key(clip, track)
            }
            Section("Transition") {
                transition(clip)
            }
            Section {
                Toggle("Loop", isOn: Binding(get: { clip.looping },
                                             set: { value in session.perform { $0.setLooping(clip.id, value) } }))
                    .help("Repeat the clip's stretch for as long as the clip is drawn out (L)")
                let part = session.selectedPart
                Toggle(part.map { "Mute \($0.name.capitalized)" } ?? "Mute",
                       isOn: Binding(get: { part.map { clip.parts[$0].muted } ?? clip.muted },
                                     set: { value in
                                         session.perform { document in
                                             if let part { document.setPartMuted(clip.id, part, value) } else { document.setMuted(clip.id, value) }
                                         }
                                     }))
                    .help(part.map { "Mute the \($0.name) of this clip" } ?? "Mute the clip (M)")
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }

    // MARK: - Sections

    private func header(_ clip: Clip, _ track: Track) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(LaneStyle.color(clip.lane, session.document.lanes))
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.selectedPart.map { "Stem · \($0.name.capitalized) · Lane \(LaneStyle.number(clip.lane))" }
                     ?? "Clip · Lane \(LaneStyle.number(clip.lane))")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(track.title)
                    .font(.headline)
                    .lineLimit(2)
                Text([track.artist, Self.clock(track.durationSeconds)].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                stems(clip)
            }
        }
    }

    /// The beatgrid of this clip's track: opens it, or with the drawer
    /// already on it, folds the drawer away and back (E, ⌘E).
    private func beatgridButton(_ track: Track) -> some View {
        let showing = session.beatgridRequest?.id == track.id && !session.beatgridHidden
        return Button(showing ? "Hide Beatgrid" : "Edit Beatgrid…") {
            session.beatgridButton()
        }
        .frame(maxWidth: .infinity)
        .help("Edit the beatgrid of \(track.displayName) in the drawer under the timeline (E, ⌘E)")
    }

    /// The clip's tempo target.
    @ViewBuilder
    private func tempo(_ clip: Clip, _ track: Track) -> some View {
        let native = track.bpm ?? 0
        // Under a locked master the point's own tempo is kept but not heard;
        // changing it there would be an edit nobody can hear.
        let master = session.document.masterLocked ? session.document.masterBPM : nil
        LabeledContent("Native") {
            Text(String(format: "%.2f BPM", native)).monospacedDigit()
        }
        LabeledContent("At its point") {
            BPMField(value: clip.targetBPM ?? native, fractionDigits: 2, width: 70) { value in
                session.perform { $0.setTargetBPM(clip.id, abs(value - native) < 0.0005 ? nil : value) }
            }
            .disabled(master != nil)
        }
        .help("The tempo the mix reaches at this clip's tempo point")
        if let master {
            Label(String(format: "Master tempo locked at %.2f BPM. Unlock it in the tempo lane to change this point.", master),
                  systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button("Use Native Tempo") {
                session.perform { $0.setTargetBPM(clip.id, nil) }
            }
            .frame(maxWidth: .infinity)
            .disabled(clip.targetBPM == nil)
            .help("Let the mix reach the track's own tempo at this clip")
        }
        if session.plan?.outOfRange.contains(clip.id) == true {
            Label("Tempo outside 0.5×–2× of the track", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    /// Gain - the selected stem's in an expanded lane - its loudness as it
    /// plays, and Match.
    @ViewBuilder
    private func level(_ clip: Clip) -> some View {
        let part = session.selectedPart
        let gainDB = part.map { clip.parts[$0].gainDB } ?? clip.gainDB
        StepperRow(title: part.map { "\($0.name.capitalized) gain" } ?? "Gain",
                   canDecrease: gainDB.rounded() > Clip.gainRange.lowerBound,
                   canIncrease: gainDB.rounded() < Clip.gainRange.upperBound,
                   decreaseLabel: "Gain down", increaseLabel: "Gain up") { direction, _ in
            stepGain(clip, part, by: direction)
        } value: {
            StepperValue(text: Self.gainLabel(gainDB), width: 48)
        }
        .help(part != nil ? "The stem's level change, −24 to +12 dB, before the clip's gain; 0 dB plays it as it is"
              : target.map { "Offset from the \(String(format: "%.1f", $0)) LUFS target, −24 to +12 dB in all; 0 dB plays the clip at the target" }
              ?? "The clip's level change, −24 to +12 dB in steps of 1 dB; 0 dB plays it as it is")
        loudness(clip)
    }

    /// Semitones up or down, and the key that makes - in Camelot, which is
    /// what a DJ matches by - then the fine tune in cents. A shift plays once
    /// it is rendered; until then the clip plays as it is, and a spinner says
    /// so.
    @ViewBuilder
    private func key(_ clip: Clip, _ track: Track) -> some View {
        StepperRow(title: "Transpose",
                   canDecrease: clip.keyShift > Clip.keyShiftRange.lowerBound,
                   canIncrease: clip.keyShift < Clip.keyShiftRange.upperBound,
                   decreaseLabel: "Key down", increaseLabel: "Key up") { direction, _ in
            session.perform { $0.stepKeyShift(clip.id, by: direction) }
        } value: {
            StepperValue(text: Self.keyLabel(clip.keyShift, track.key?.key), width: 64)
        }
        .help(track.key.map { "Semitones up or down, −6 to +6, from \($0.key.name) (\($0.key.camelot)) as analysed; the length and the beatgrid stay as they are" }
              ?? "Semitones up or down, −6 to +6; the length and the beatgrid stay as they are")
        StepperRow(title: "Fine",
                   canDecrease: clip.fineTune > Clip.fineTuneRange.lowerBound,
                   canIncrease: clip.fineTune < Clip.fineTuneRange.upperBound,
                   decreaseLabel: "Fine tune down", increaseLabel: "Fine tune up") { direction, _ in
            session.perform { $0.stepFineTune(clip.id, by: direction) }
        } value: {
            StepperValue(text: Self.fineLabel(clip.fineTune), width: 48)
        }
        .help("Cents on top of the key, −50 to +50 in steps of 5 - for a record a little off concert pitch")
        if !clip.pitch.isNone, library.shifting.contains(Library.ShiftKey(track: clip.trackID, pitch: clip.pitch)) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Rendering the pitch shift; the clip plays unshifted until it is ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The transition over this clip's overlaps: which one, and Apply.
    @ViewBuilder
    private func transition(_ clip: Clip) -> some View {
        Picker("Type", selection: Binding(get: { session.transitionStyle },
                                          set: { session.transitionStyle = $0 })) {
            ForEach(TransitionStyle.allCases) { Text($0.title).tag($0) }
        }
        .help("The transition Apply puts over this clip's overlaps with clips on other lanes")
        Button("Apply \(session.transitionStyle.title)") {
            session.autoCrossfade()
        }
        .frame(maxWidth: .infinity)
        .help("\(session.transitionStyle.title) over this clip's overlaps with clips on other lanes (⇧⌘X)")
    }

    /// While the song is being separated, how far that has got, and a
    /// spinner while its stems are decoded or shifted - the clip plays the
    /// whole song until they are there.
    @ViewBuilder
    private func stems(_ clip: Clip) -> some View {
        if let fraction = library.separating[clip.trackID] {
            HStack(spacing: 6) {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.mini)
                Text("Separating stems: \(Int(fraction * 100)) %")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("The clip plays the whole song until the stems are ready.")
        } else if clip.parts.playsStems,
                  library.shifting.contains(Library.ShiftKey(track: clip.trackID, pitch: clip.pitch, stems: true)) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Preparing the stems")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("The clip plays the whole song until the stems are ready.")
        }
    }

    private func stepGain(_ clip: Clip, _ part: Stem?, by steps: Int) {
        session.perform { document in
            if let part { document.stepPartGain(clip.id, part, by: steps) } else { document.stepGain(clip.id, by: steps) }
        }
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
        LabeledContent("Loudness") {
            Text(own.map { String(format: "%.1f LUFS", $0) } ?? "– LUFS").monospacedDigit()
        }
        .help("Integrated loudness of the part of the song this clip plays, with the gain it plays with. The lane's volume, pan and filters are not included.")
        Button("Match Loudness") {
            session.perform { $0.matchGain(clip.id, grids: grids, loudness: { profiles[$0] }) }
        }
        .frame(maxWidth: .infinity)
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

    // MARK: - Labels

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

    /// "0 dB", "-1 dB", "+3 dB": a gain with its sign, so louder and quieter
    /// read differently at a glance.
    static func gainLabel(_ dB: Double) -> String {
        let whole = Int(dB.rounded())
        return whole == 0 ? "0 dB" : String(format: "%+d dB", whole)
    }

    static func clock(_ seconds: Double) -> String? {
        guard seconds > 0 else { return nil }
        return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }

    /// A timeline beat as bar.beat, counting from 1.1.
    private func barBeat(_ beat: Int) -> String {
        let bar = Int((Double(beat) / Double(Clip.beatsPerBar)).rounded(.down))
        let inBar = beat - bar * Clip.beatsPerBar
        return "\(bar + 1).\(inBar + 1)"
    }
}
