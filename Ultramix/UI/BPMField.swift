//
//  BPMField.swift
//  Ultramix
//
//  A tempo typed by hand, applied only when confirmed.
//
//  Bound straight to the value, every keystroke was a tempo: typing "120" set
//  1 BPM, which the range clamped to 40, which the field then displayed - so
//  "2" and "0" were typed after "40.000" and the intended tempo could not be
//  entered at all. The same keystroke set a track to 40 BPM behind a trimmed
//  clip and made a mix that crashed when opened.
//
//  So typing edits a draft. Set or Return applies it, only then clamped;
//  Escape puts the current value back. A draft that differs from what is
//  applied is outlined in the accent colour. A change from elsewhere replaces
//  the draft only if it was untouched.
//

import SwiftUI

struct BPMField: View {
    let value: Double
    let fractionDigits: Int
    var width: CGFloat = 80
    let onCommit: (Double) -> Void

    @State private var draft = ""
    /// What the draft was last filled with; a draft still equal to it has
    /// not been touched.
    @State private var base = ""
    @Environment(\.accent) private var accent

    private var formatted: String { String(format: "%.\(fractionDigits)f", value) }
    private var pending: Bool { draft != formatted }
    private var canSet: Bool { pending && BPMInput.parse(draft) != nil }

    var body: some View {
        HStack(spacing: 4) {
            TextField("BPM", text: $draft)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: width)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(accent, lineWidth: 1.5).opacity(pending ? 0.9 : 0))
                .onSubmit(commit)
                .onExitCommand { draft = formatted }
                .help("Type a tempo, then Set or Return. Escape discards it.")
            Button("Set", action: commit)
                .disabled(!canSet)
        }
        .onAppear {
            draft = formatted
            base = formatted
        }
        .onChange(of: value) {
            let untouched = draft == base
            base = formatted
            if untouched { draft = formatted }
        }
    }

    /// A draft that reads as the value already applied - untouched, or
    /// "120" for "120.000" - is tidied and goes no further: confirming a
    /// tempo that is already set is not an edit, and passing it on made the
    /// beatgrid editor save the library for nothing.
    private func commit() {
        guard let bpm = BPMInput.parse(draft) else { return }
        draft = String(format: "%.\(fractionDigits)f", bpm)
        base = draft
        guard draft != formatted else { return }
        onCommit(bpm)
    }
}
