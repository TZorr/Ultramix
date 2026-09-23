//
//  TimelineScrollbar.swift
//  Ultramix
//
//  A horizontal scroll bar under the timeline that is always there. The
//  ScrollView's own scroller follows the system's "Show scroll bars" setting,
//  which by default is an overlay that appears only while scrolling - with a
//  mouse that has no horizontal wheel, that is no scroll bar at all, and
//  `.scrollIndicators(.visible)` does not change it on macOS.
//
//  Drawn in a Canvas, which has no minimum size of its own, so no thumb
//  position or width can feed back into the window's layout. One gesture
//  covers the whole bar: grabbing the thumb drags it, clicking the track
//  beside it jumps there with the thumb centred on the pointer.
//

import SwiftUI

struct TimelineScrollbar: View {
    static let height: CGFloat = 14
    static let minimumThumb: CGFloat = 32

    let scrollX: CGFloat
    let contentWidth: CGFloat
    let viewportWidth: CGFloat
    let scroll: (CGFloat) -> Void

    /// Where in the thumb the pointer took hold, while dragging.
    @State private var grab: CGFloat?
    /// The bar's own width, as last drawn - the gesture needs it.
    @State private var trackWidth: CGFloat = 0

    var body: some View {
        let dragging = grab != nil
        Canvas { context, size in
            let metrics = Self.metrics(track: size.width, scrollX: scrollX,
                                       contentWidth: contentWidth, viewportWidth: viewportWidth)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.primary.opacity(0.05)))
            let thumb = CGRect(x: metrics.x, y: (size.height - 8) / 2, width: metrics.thumb, height: 8)
            context.fill(Path(roundedRect: thumb, cornerRadius: 4),
                         with: .color(Color.primary.opacity(dragging ? 0.5 : 0.32)))
        }
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            trackWidth = width
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let metrics = Self.metrics(track: trackWidth, scrollX: scrollX,
                                               contentWidth: contentWidth, viewportWidth: viewportWidth)
                    if grab == nil {
                        let start = value.startLocation.x
                        let onThumb = start >= metrics.x && start <= metrics.x + metrics.thumb
                        grab = onThumb ? start - metrics.x : metrics.thumb / 2
                    }
                    let x = min(max(value.location.x - (grab ?? 0), 0), metrics.travel)
                    scroll(metrics.travel > 0 ? x / metrics.travel * metrics.maxScroll : 0)
                }
                .onEnded { _ in grab = nil }
        )
    }

    /// Thumb width, how far it can travel, where it is, and the scroll
    /// distance that travel stands for - for a track `track` points wide.
    static func metrics(track: CGFloat, scrollX: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat)
        -> (thumb: CGFloat, travel: CGFloat, x: CGFloat, maxScroll: CGFloat)
    {
        let maxScroll = max(0, contentWidth - viewportWidth)
        let thumb = maxScroll > 0 ? min(track, max(minimumThumb, track * viewportWidth / contentWidth)) : track
        let travel = max(0, track - thumb)
        let x = maxScroll > 0 ? min(max(scrollX / maxScroll, 0), 1) * travel : 0
        return (thumb, travel, x, maxScroll)
    }
}
