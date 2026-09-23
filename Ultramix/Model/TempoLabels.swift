//
//  TempoLabels.swift
//  Ultramix
//
//  Where the tempo strip writes each point's BPM: beside the point where there
//  is room, above or below it where that would collide, and left out where it
//  fits nowhere. The point itself is always drawn.
//
//  Worked out here rather than in the drawing so the harness can check it: the
//  placement is plain rectangle arithmetic.
//

import CoreGraphics

nonisolated enum TempoLabels {
    struct Point: Equatable {
        /// The point's centre.
        var x: CGFloat
        var y: CGFloat
        /// The label's size as it will be drawn.
        var size: CGSize
    }

    enum Slot: Equatable {
        case right, above, below, hidden
    }

    /// Radius of a drawn point; a label keeps clear of every point.
    static let dotRadius: CGFloat = 5
    /// Between a point and its label.
    static let gap: CGFloat = 3

    /// One slot per point, in the order given. Points are placed from right
    /// to left: the rightmost label has nothing after it and keeps the usual
    /// place beside its point, and where two compete the earlier one gives
    /// way. `bounds` is the strip the labels must stay inside, top to
    /// bottom - sideways a label may run out of view, as the strip scrolls;
    /// `blocked` is anything else already written there.
    static func place(_ points: [Point], in bounds: CGRect, blocked: [CGRect] = []) -> [Slot] {
        let dots = points.map {
            CGRect(x: $0.x - dotRadius, y: $0.y - dotRadius, width: 2 * dotRadius, height: 2 * dotRadius)
        }
        var taken = blocked
        var slots = Array(repeating: Slot.hidden, count: points.count)
        for i in points.indices.sorted(by: { points[$0].x > points[$1].x }) {
            for slot in [Slot.right, .above, .below] {
                let rect = self.rect(slot, for: points[i])
                let clear = rect.minY >= bounds.minY && rect.maxY <= bounds.maxY
                    && !taken.contains { $0.intersects(rect) }
                    && !dots.enumerated().contains { $0.offset != i && $0.element.intersects(rect) }
                if clear {
                    slots[i] = slot
                    taken.append(rect)
                    break
                }
            }
        }
        return slots
    }

    /// Where a label in `slot` is drawn: its leading edge just right of the
    /// point, beside it or clear above or below the dot - diagonally, so a
    /// label near the start of the strip keeps clear of the scale numbers.
    static func rect(_ slot: Slot, for point: Point) -> CGRect {
        let x = point.x + dotRadius + gap
        switch slot {
        case .right, .hidden:
            return CGRect(x: x, y: point.y - point.size.height / 2, width: point.size.width, height: point.size.height)
        case .above:
            return CGRect(x: x, y: point.y - dotRadius - gap / 2 - point.size.height,
                          width: point.size.width, height: point.size.height)
        case .below:
            return CGRect(x: x, y: point.y + dotRadius + gap / 2,
                          width: point.size.width, height: point.size.height)
        }
    }
}
