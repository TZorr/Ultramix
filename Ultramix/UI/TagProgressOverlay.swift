//
//  TagProgressOverlay.swift
//  Ultramix
//
//  A bar at the foot of the window for a long round of work - writing tempos
//  into the song files, or decoding every one of them into the cache.
//
//  It floats rather than taking a strip of the layout: the work is usually
//  over in seconds, and a window that changed shape for two seconds and back
//  would be worse than the silence it replaces. Shown from the window rather
//  than the library panel, which can be put away while the writing runs.
//

import SwiftUI

struct TagProgressOverlay: View {
    /// What is running: the same bar serves the tag writing and the
    /// decoding of the whole library.
    let title: String
    let done: Int
    let total: Int
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.callout.weight(.medium))
                    // Never truncated: the bar's width would otherwise
                    // decide how much of the sentence there is room for.
                    .fixedSize()
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                Text("\(done) of \(total)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Stop", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .padding(.bottom, 30)
    }
}
