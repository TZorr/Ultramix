//
//  LaneGeometry.swift
//  Ultramix
//
//  How the timeline's height is shared among its lanes, and how an expanded
//  lane is shared among its rows: the clip's own on top, then one per stem.
//
//  By weight, not by measured heights: a lane counts 1, an expanded one 3
//  (its own row 1, each stem's a half), each held to a minimum, and what the
//  minimums take comes out of the others. With nothing expanded every lane
//  gets a third, as it always did. The timeline and the lane headers both
//  work their rows out from this, so they cannot drift apart - the headers
//  must not be given heights measured from the timeline (see LaneHeaders).
//
//  The timeline does not scroll vertically - the wheel's vertical travel is
//  its zoom - so three expanded lanes in a small window are tight; below
//  the minimums the lanes run past the bottom, as one did before.
//

import Foundation

nonisolated enum LaneGeometry {
    static let laneWeight = 1.0
    static let expandedWeight = 3.0
    static let minimumLane = 44.0
    /// A stem row is never thinner than this; the clip's row gets what the
    /// four leave, and never less than a collapsed lane's minimum.
    static let minimumStemRow = 18.0
    static var minimumExpanded: Double { minimumLane + Double(Stem.allCases.count) * minimumStemRow }

    /// Each lane's height, in the order given, sharing `total`.
    static func heights(total: Double, expanded: [Bool]) -> [Double] {
        let weights = expanded.map { $0 ? expandedWeight : laneWeight }
        let minimums = expanded.map { $0 ? minimumExpanded : minimumLane }
        var fixed = [Double?](repeating: nil, count: expanded.count)
        // Whichever lane its share leaves under its minimum gets the
        // minimum, and the rest is shared again among the others.
        while true {
            let free = expanded.indices.filter { fixed[$0] == nil }
            guard !free.isEmpty else { break }
            let left = total - fixed.compactMap { $0 }.reduce(0, +)
            let weight = free.reduce(0) { $0 + weights[$1] }
            let short = free.filter { left * weights[$0] / weight < minimums[$0] }
            if short.isEmpty {
                return expanded.indices.map { fixed[$0] ?? left * weights[$0] / weight }
            }
            for i in short { fixed[i] = minimums[i] }
        }
        return fixed.map { $0 ?? 0 }
    }

    /// An expanded lane of `height`: the clip's row and each stem row's,
    /// adding up to `height`. A third for the clip, a sixth each for the
    /// stems; where a third is under a lane's minimum, the clip's row keeps
    /// the minimum and the stems share the rest.
    static func rows(laneHeight height: Double) -> (clip: Double, stem: Double) {
        let stems = Double(Stem.allCases.count)
        var stem = height * 0.5 / expandedWeight
        if height - stems * stem < minimumLane { stem = max(minimumStemRow, (height - minimumLane) / stems) }
        return (height - stems * stem, stem)
    }
}
