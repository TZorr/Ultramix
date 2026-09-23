//
//  BounceSheet.swift
//  Ultramix
//
//  Bouncing the mix: pick a format, set the mastering limiter, and the sheet
//  says in one line what the limiter is about to do before it does it.
//
//  The settings are remembered whenever they change, not only when a bounce
//  runs: they are chain settings, adjusted long before anything is exported.
//

import SwiftUI
import AppKit
import Synchronization

/// A cancel request the bounce polls from its own thread - so not
/// MainActor-isolated, which the project's default would make it.
nonisolated final class CancelFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func cancel() { flag.store(true, ordering: .relaxed) }
    func reset() { flag.store(false, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

@Observable
final class BounceJob {
    var progress: Double?
    let cancel = CancelFlag()
}

struct BounceSheet: View {
    let session: MixSession

    @Environment(\.dismiss) private var dismiss
    @State private var settings = BounceSheet.storedSettings()
    @State private var job = BounceJob()

    private static let settingsKey = "bounceSettings"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bounce the Mix").font(.title2.weight(.semibold))
                Text(lengthDescription).foregroundStyle(.secondary)
            }

            Picker("Format", selection: $settings.format) {
                ForEach(BounceFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if settings.format == .mp3 {
                Text("Constant bit rate, joint stereo, with a gapless (LAME) tag. Choosing MP3 lowers the ceiling to −1 dB: the codec rebuilds peaks slightly higher than it was given.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Mastering limiter", isOn: $settings.mastering.enabled)
                    Group {
                        LabeledContent("Threshold") {
                            HStack {
                                Slider(value: $settings.mastering.thresholdDB, in: -12...0, step: 0.1)
                                Text(String(format: "%.1f dB", settings.mastering.thresholdDB))
                                    .monospacedDigit()
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                        LabeledContent("Ceiling") {
                            HStack {
                                Slider(value: $settings.mastering.ceilingDB, in: -3...0, step: 0.1)
                                Text(String(format: "%.1f dB", settings.mastering.ceilingDB))
                                    .monospacedDigit()
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                        Toggle("Release follows the music", isOn: $settings.mastering.autoRelease)
                        if !settings.mastering.autoRelease {
                            LabeledContent("Release") {
                                HStack {
                                    Slider(value: $settings.mastering.releaseMilliseconds, in: 10...1000)
                                    Text(String(format: "%.0f ms", settings.mastering.releaseMilliseconds))
                                        .monospacedDigit()
                                        .frame(width: 58, alignment: .trailing)
                                }
                            }
                        }
                        Text(limiterDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!settings.mastering.enabled)
                }
                .padding(6)
            }

            if let progress = job.progress {
                ProgressView(value: progress) {
                    Text("Bouncing…")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    if job.progress != nil { job.cancel.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Bounce…") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.progress != nil || session.document.clips.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onChange(of: settings) { _, new in Self.store(new) }
        .onChange(of: settings.format) { _, format in
            settings.mastering.ceilingDB = format.recommendedCeilingDB
        }
    }

    private var lengthDescription: String {
        let seconds = max(0, session.tempo.seconds(atBeat: session.endBeat))
        return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60)) · \(session.document.clips.count) clips · 44.1 kHz stereo"
    }

    private var limiterDescription: String {
        let mastering = settings.mastering
        let ceiling = String(format: "%.1f dB", mastering.ceilingDB)
        if mastering.makeupDB > 0.05 {
            return String(format: "Raises the mix by %.1f dB, then holds every peak under %@.", mastering.makeupDB, ceiling)
        }
        return "Holds every peak under \(ceiling)."
    }

    private func start() {
        guard let url = FilePanels.bounceDestination(for: settings.format, name: session.title,
                                                     in: session.library.workspace.bounces) else { return }
        Self.store(settings)
        let job = job
        let flag = job.cancel
        flag.reset()
        job.progress = 0
        Task {
            // Audio the cache's size limit took is decoded first.
            guard await session.prepareAudio() else {
                job.progress = nil
                return
            }
            let plan = session.bouncePlan()
            let mask = session.laneMask
            let chosen = settings
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                var reported = 0.0
                do {
                    try Bounce.run(plan: plan, laneMask: mask, settings: chosen, to: url, progress: { value in
                        guard value - reported >= 0.004 || value >= 1 else { return }
                        reported = value
                        Task { @MainActor in job.progress = value }
                    }, isCancelled: { flag.isCancelled })
                    return nil
                } catch {
                    return error
                }
            }.value
            job.progress = nil
            if let failure {
                if case BounceError.cancelled = failure { return }
                session.message = failure.localizedDescription
            } else {
                dismiss()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private static func storedSettings() -> BounceSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(BounceSettings.self, from: data) else { return BounceSettings() }
        return settings
    }

    private static func store(_ settings: BounceSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }
}
