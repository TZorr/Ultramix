//
//  StepperRow.swift
//  Ultramix
//
//  One value with its unit between − and +: gain, key, fine tune, and the
//  beatgrid's tempo and bar one. A single control per value, rather than a
//  row of −10 −1 +1 +10 buttons whose unit nobody could see.
//
//  ⇧ makes a step coarse where the value has a coarse step; the hint under
//  the row, when there is one, says how big each is.
//

import SwiftUI
import AppKit

struct StepperRow<Value: View>: View {
    let title: String
    var hint: String?
    var canDecrease = true
    var canIncrease = true
    var decreaseLabel = "Down"
    var increaseLabel = "Up"
    /// Called with −1 or +1, and whether ⇧ was held.
    let step: (_ direction: Int, _ coarse: Bool) -> Void
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                button("minus", direction: -1, enabled: canDecrease, label: decreaseLabel)
                value()
                    .monospacedDigit()
                button("plus", direction: 1, enabled: canIncrease, label: increaseLabel)
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Minus is a flat glyph: a button sized by it comes out lower than the
    /// plus beside it. Both get the same box.
    private func button(_ symbol: String, direction: Int, enabled: Bool, label: String) -> some View {
        Button {
            step(direction, NSEvent.modifierFlags.contains(.shift))
        } label: {
            Image(systemName: symbol).frame(width: 10, height: 10)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// A value shown in a stepper row: fixed width, so − and + stay put while
/// the number changes, in a sunken box like a field.
struct StepperValue: View {
    let text: String
    var width: CGFloat = 64

    var body: some View {
        Text(text)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.08)))
    }
}
