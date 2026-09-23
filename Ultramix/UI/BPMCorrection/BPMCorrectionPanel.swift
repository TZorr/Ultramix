//
//  BPMCorrectionPanel.swift
//  Ultramix
//
//  Putting a tempo right that the analysis got an octave wrong. Tap along on
//  every beat for a moment - rough taps are enough - and the panel offers the
//  measured tempo at half, as it is and at double, with the one nearest the
//  taps picked.
//
//  The taps are timed on the system clock, not against a player: only the
//  intervals matter, and the delay to the speaker is the same for each. So it
//  works with whatever is playing.
//
//  The Choice list is always four rows tall. Growing a row the moment the taps
//  earned a tempo grew the popover with it, moving the Tap button out from
//  under the pointer in the middle of tapping.
//

import SwiftUI

/// How the Choice list is laid out, whatever there is to show: four rows of
/// one height, so the panel never changes size while it is tapped into.
private enum ChoiceLayout {
    static let rows = 4
    static let rowHeight: CGFloat = 20
}

struct BPMCorrectionPanel<Accessory: View>: View {
    let detected: Double?
    let sourceLabel: String
    var note: String?
    let onUse: (Double) -> Void
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.accent) private var accent
    @State private var taps: [Double] = []
    @State private var tapResult: TapTempo.Result?
    /// A tempo picked by hand; until then the suggestion is followed.
    @State private var picked: Double?

    private var candidates: [BPMChoice.Candidate] {
        BPMChoice.candidates(detected: detected, tapped: tapResult?.bpm)
    }

    private var selection: Double? {
        picked ?? candidates.first(where: \.isSuggested)?.bpm ?? detected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            detectedSection
            Divider()
            tapSection
            Divider()
            choiceSection
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let selection { onUse(selection) }
            } label: {
                Label(selection.map { String(format: "Use %.1f BPM", $0) } ?? "Use", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .padding(18)
        .frame(width: 320)
    }

    // MARK: - Sections

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("Detected")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detected.map { String(format: "%.1f BPM", $0) } ?? "–")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(sourceLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("÷2") { step(0.5) }
                    .help("Half the selected tempo")
                Button("×2") { step(2) }
                    .help("Double the selected tempo")
            }
            .disabled(selection == nil)
        }
    }

    private var tapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption("Tap")
                Spacer()
                accessory()
            }
            Button(action: tap) {
                Text("Tap").font(.headline).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("t", modifiers: [])
            .help("Tap along on every beat (T)")
            HStack {
                Text(tapSummary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Reset") {
                    taps = []
                    tapResult = nil
                    picked = nil
                }
                .buttonStyle(.link)
                .disabled(taps.isEmpty)
            }
        }
    }

    /// Four slots: the octave candidates, then one for a tempo of the taps'
    /// or the hand's own. An empty slot is drawn grey rather than left out,
    /// so the panel keeps its height while it is being tapped into.
    private var choiceSection: some View {
        let rows = candidates
        let extra = picked.flatMap { hand in
            rows.contains { abs($0.bpm - hand) < 0.0005 } ? nil : hand
        }
        return VStack(alignment: .leading, spacing: 6) {
            caption("Choice")
            ForEach(0..<ChoiceLayout.rows, id: \.self) { index in
                if index < rows.count {
                    row(rows[index])
                } else if index == ChoiceLayout.rows - 1, let extra {
                    row(BPMChoice.Candidate(bpm: extra, kind: .tap), byHand: true)
                } else {
                    emptyRow
                }
            }
        }
    }


    private func row(_ candidate: BPMChoice.Candidate, byHand: Bool = false) -> some View {
        let selected = selection.map { abs($0 - candidate.bpm) < 0.0005 } ?? false
        return Button {
            picked = candidate.bpm
        } label: {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? accent : .secondary)
                Text(String(format: "%.1f BPM", candidate.bpm))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .leading)
                Text(byHand ? "by hand" : candidate.kind.rawValue).foregroundStyle(.secondary)
                Spacer()
                if candidate.isSuggested {
                    Text("suggested").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: ChoiceLayout.rowHeight)
    }

    private var emptyRow: some View {
        HStack {
            Image(systemName: "circle").foregroundStyle(.quaternary)
            Text("–").monospacedDigit().frame(width: 80, alignment: .leading)
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .frame(height: ChoiceLayout.rowHeight)
        .accessibilityHidden(true)
    }



    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func tap() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = taps.last, now - last > TapTempo.beatSeriesTimeout {
            taps = []
        }
        taps.append(now)
        tapResult = TapTempo.fit(beatTaps: taps)
        // New taps say something new: follow the suggestion again.
        picked = nil
    }

    private func step(_ factor: Double) {
        guard let selection else { return }
        let range = TempoMap.bpmRange
        picked = min(max(selection * factor, range.lowerBound), range.upperBound)
    }

    private var tapSummary: String {
        if taps.isEmpty { return "Tap along on every beat" }
        guard let result = tapResult else {
            return "\(taps.count) tap\(taps.count == 1 ? "" : "s") – keep going"
        }
        return String(format: "%.1f BPM  ·  %d taps  ·  ±%.1f BPM", result.bpm, result.tapsUsed, result.bpmSpread)
    }
}

extension BPMCorrectionPanel where Accessory == EmptyView {
    init(detected: Double?, sourceLabel: String, note: String? = nil, onUse: @escaping (Double) -> Void) {
        self.init(detected: detected, sourceLabel: sourceLabel, note: note, onUse: onUse) { EmptyView() }
    }
}
