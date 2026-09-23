//
//  SettingsView.swift
//  Ultramix
//
//  The settings window (⌘,): appearance, which beat analyser new songs get,
//  the optional loudness target, whether imports are copied, where the mix and
//  auditioning are heard, which MIDI controller turns the lane knobs, and how
//  much decoded audio the cache keeps. They belong to the Mac, not to a
//  working directory.
//
//  The one setting that is also a piece of work sits here too: keeping every
//  song decoded fills the cache with the whole library, so it asks first with
//  the figures for this library.
//

import SwiftUI

struct SettingsView: View {
    /// The open working directory's library, if there is one. Only the
    /// decoding of every song needs it; every other setting is a stored
    /// value and works with no working directory open.
    let library: Library?

    @AppStorage("appearance") private var appearance: AppAppearance = .dark
    @AppStorage("accentColor") private var accentHex = AppAccent.system
    @AppStorage(LoudnessTarget.enabledKey) private var targetEnabled = false
    @AppStorage(LoudnessTarget.lufsKey) private var targetLUFS = LoudnessTarget.defaultLUFS
    @AppStorage(BeatAlgorithm.storageKey) private var beatAlgorithm: BeatAlgorithm = BeatAlgorithm.fallback
    @AppStorage(AudioCacheLimit.storageKey) private var cacheLimitGB = AudioCacheLimit.defaultGB
    @AppStorage(ImportCopy.storageKey) private var copyOnImport = true
    @AppStorage(AudioCacheLimit.noLimitKey) private var keepDecoded = false
    @AppStorage(AudioRouting.deviceKey) private var outputDeviceUID = ""
    @AppStorage(AudioRouting.deviceNameKey) private var outputDeviceName = ""
    @AppStorage(AudioRouting.mainKey) private var mainPair = 0
    @AppStorage(AudioRouting.auditionKey) private var auditionPair = 0
    /// Raised when keeping every song decoded is switched on, and answered
    /// before anything is decoded. `plan` is counted when the box is ticked,
    /// not while the window draws: it stats every file in the Cache folder.
    @State private var askFill = false
    @State private var plan: Library.CacheFillPlan?
    private var audioDevices = AudioDevices.shared
    private var midi = MIDIControllerInput.shared
    private var knobs = LaneKnobController.shared

    /// "" is the system's output. Choosing an interface also remembers its
    /// name, so a missing one can be named.
    private var outputDevice: Binding<String> {
        Binding(get: { outputDeviceUID },
                set: { uid in
                    outputDeviceUID = uid
                    outputDeviceName = audioDevices.devices.first { $0.uid == uid }?.name ?? ""
                })
    }

    /// Switching it on asks first; switching it off is immediate - what has
    /// been decoded stays, and the limit simply applies to it again.
    private var keepOption: Binding<Bool> {
        Binding(get: { keepDecoded },
                set: { wanted in
                    guard wanted else { keepDecoded = false; return }
                    plan = library?.cacheFillPlan()
                    askFill = true
                })
    }

    /// What filling the cache would cost, in figures, for this library.
    private var warning: String {
        var parts: [String] = []
        if let plan, !plan.isEmpty {
            let songs = "\(plan.songs) song\(plan.songs == 1 ? "" : "s")"
            // Saying "more than it holds now" when it holds nothing would
            // state the same figure twice.
            parts.append(plan.nowBytes > 0
                ? "\(songs) still have to be decoded: about \(bytes(plan.totalBytes)) in the Cache folder, \(bytes(plan.addedBytes)) more than it holds now."
                : "\(songs) have to be decoded: about \(bytes(plan.addedBytes)) in the Cache folder.")
        } else if plan != nil {
            parts.append("Every song is decoded already.")
        } else {
            parts.append("No working directory is open, so nothing is decoded now.")
        }
        parts.append("Nothing is given back while this is on, so every song is ready to play at once and nothing is decoded while the music runs.")
        parts.append("The song files themselves are not touched, and switching it off puts the limit back.")
        return parts.joined(separator: " ")
    }

    private func bytes(_ count: Int) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private var accent: Binding<Color> {
        Binding(get: { AppAccent.color(accentHex) }, set: { accentHex = AppAccent.hex($0) })
    }

    /// Held to the range and to 0.1 LU when it is set. The field sets it
    /// only on Return or when it loses focus, never per keystroke - typing
    /// "−14" must not pass through "−1" on its way there.
    private var target: Binding<Double> {
        Binding(get: { LoudnessTarget.clamped(targetLUFS) },
                set: { targetLUFS = LoudnessTarget.clamped(($0 * 10).rounded() / 10) })
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Accent Color") {
                    HStack(spacing: 10) {
                        ColorPicker("Accent Color", selection: accent, supportsOpacity: false)
                            .labelsHidden()
                        Button("Use System Color") { accentHex = AppAccent.system }
                            .disabled(accentHex == AppAccent.system)
                    }
                }
                Text("Tints the tempo curve, selections and Ultramix's own controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Beat Detection") {
                Picker("Analyser", selection: $beatAlgorithm) {
                    ForEach(BeatAlgorithm.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("For new imports and Analyse Again; existing grids are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Loudness") {
                Toggle("Play every clip at a loudness target", isOn: $targetEnabled)
                LabeledContent("Target") {
                    HStack(spacing: 8) {
                        TextField("Target", value: target, format: .number.precision(.fractionLength(1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 60)
                        Text("LUFS").foregroundStyle(.secondary)
                        Stepper("Target", value: target, in: LoudnessTarget.range, step: 1)
                            .labelsHidden()
                        Button("Use −14") { targetLUFS = LoudnessTarget.defaultLUFS }
                            .disabled(LoudnessTarget.clamped(targetLUFS) == LoudnessTarget.defaultLUFS)
                    }
                }
                .disabled(!targetEnabled)
                Text("Every clip plays at this loudness; the gains in the mix are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Library") {
                Toggle("Copy imported songs into the working directory", isOn: $copyOnImport)
                Text("Off: songs are read where they lie and must stay there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Nothing to do with copying: the cache is every song's,
                // the ones read where they lie included.
                Toggle("Keep every song decoded (32-bit float)", isOn: keepOption)
                    .disabled(library?.fillingCache == true)
                Text("Every song is decoded once and kept, so nothing is decoded while you play. About 10 MB a minute; the size below does not apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The bar itself is at the foot of the main window; this is
                // for the user who is still standing in Settings.
                if let running = library?.cacheFill {
                    LabeledContent("Decoding") {
                        HStack(spacing: 10) {
                            ProgressView(value: Double(running.done), total: Double(max(running.total, 1)))
                                .progressViewStyle(.linear)
                            Text("\(running.done) of \(running.total)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Stop") { library?.cancelCacheFill() }
                        }
                    }
                }
            }

            // Directly under the option that lifts it, so it is plain what
            // the greying out is about.
            Section("Audio Cache") {
                Picker("Keep up to", selection: $cacheLimitGB) {
                    ForEach(AudioCacheLimit.choicesGB, id: \.self) { gigabytes in
                        Text("\(gigabytes) GB").tag(gigabytes)
                    }
                }
                Text(keepDecoded
                     ? "No limit while every song is kept decoded: nothing is given back."
                     : "Decoded audio used longest ago is given back above this size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(keepDecoded)

            Section("Audio Output") {
                let routing = AudioRouting.current()
                let used = routing.device(in: audioDevices.devices) ?? audioDevices.systemDefault
                let pairs = AudioRouting.pairCount(channels: used?.channels ?? 2)
                Picker("Interface", selection: outputDevice) {
                    Text("System Output" + (audioDevices.systemDefault.map { " (\($0.name))" } ?? "")).tag("")
                    ForEach(audioDevices.devices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if routing.isMissing(in: audioDevices.devices) {
                        Text("\(outputDeviceName.isEmpty ? "Interface" : outputDeviceName) (not connected)").tag(outputDeviceUID)
                    }
                }
                Picker("Main Mix", selection: $mainPair) {
                    ForEach(0..<max(pairs, mainPair + 1), id: \.self) { pair in
                        Text(AudioRouting.pairLabel(pair, names: used?.channelNames ?? [])).tag(pair)
                    }
                }
                Picker("Audition", selection: $auditionPair) {
                    ForEach(0..<max(pairs, auditionPair + 1), id: \.self) { pair in
                        Text(AudioRouting.pairLabel(pair, names: used?.channelNames ?? [])).tag(pair)
                    }
                }
                if routing.isMissing(in: audioDevices.devices) {
                    Text("\(outputDeviceName.isEmpty ? "The interface" : outputDeviceName) is not connected - playing through the system output.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Different outputs: audition in the headphones while the mix plays on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("MIDI Controller") {
                if midi.sources.isEmpty {
                    Text("No MIDI inputs found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(midi.sources) { source in
                    Toggle(source.name, isOn: Binding(get: { midi.isChosen(source) },
                                                      set: { midi.setController(source, on: $0) }))
                }
                HStack {
                    if let error = midi.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Rescan") { midi.refresh() }
                }
                ForEach(0..<LaneKnobMath.slotCount, id: \.self) { slot in
                    KnobSettingsRow(slot: slot)
                }
                Text("Two knobs per lane, heard while playing, never bounced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("Every setting is explained in Help › Settings (⌘?).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Keep every song decoded?", isPresented: $askFill) {
            Button("Keep Decoded") {
                keepDecoded = true
                library?.fillCache()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(warning)
        }
        // Learn armed here and forgotten would take the next knob turned,
        // whenever that is, as its address.
        .onDisappear { knobs.cancelLearn() }
        // Scrolls rather than growing with every section: it opens at a
        // height that fits the screen, and can be made taller.
        .frame(width: 460)
        .frame(minHeight: 320, idealHeight: 560, maxHeight: .infinity)
    }
}

/// One knob in Settings: its function, the CC it listens to, Learn and
/// Forget. A view of its own, so each row observes only its own knob.
///
/// Testing trap: Accessibility kept reading "–" after Learn had worked,
/// while the window itself showed the CC. Look at the window, not the AX
/// text, before concluding the row does not update.
struct KnobSettingsRow: View {
    let slot: Int
    var knobs = LaneKnobController.shared

    var body: some View {
        let lane = LaneStyle.names[slot / LaneKnobMath.knobsPerLane]
        let assignment = knobs.setup.slots[slot]
        let learning = knobs.learning == slot
        LabeledContent("Lane \(lane) · \(slot % LaneKnobMath.knobsPerLane + 1)") {
            HStack(spacing: 6) {
                Picker("Function", selection: Binding(get: { assignment.function },
                                                      set: { knobs.setFunction(slot, $0) })) {
                    ForEach(KnobFunction.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 104)
                Text(learning ? "Move a knob…" : assignment.label)
                    .monospacedDigit()
                    .foregroundStyle(learning ? .primary : .secondary)
                    .frame(width: 92, alignment: .leading)
                Button(learning ? "Cancel" : "Learn") { knobs.toggleLearn(slot) }
                    .frame(width: 62)
                Button {
                    knobs.forget(slot)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!assignment.isAssigned)
                // Disabled alone left it looking as clickable as the rest.
                .opacity(assignment.isAssigned ? 1 : 0.3)
                .help("Forget the CC")
                .accessibilityLabel("Forget the CC")
            }
        }
    }
}
