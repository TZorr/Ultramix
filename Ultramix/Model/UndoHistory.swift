//
//  UndoHistory.swift
//  Ultramix
//
//  Undo as snapshots of a value. The document is a struct, so a snapshot is a
//  copy and restoring one is an assignment - there is no inverse operation per
//  edit to write, and so none to get wrong. The cost is memory, bounded by
//  `limit`; a mix of a few hundred clips is kilobytes.
//

import Foundation

nonisolated struct UndoHistory<State: Equatable> {
    let limit: Int
    private var past: [State] = []
    private var future: [State] = []

    init(limit: Int = 50) {
        self.limit = limit
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Call with the state *before* an edit. Recording anything new discards
    /// the redo branch, as it does everywhere else on the Mac.
    mutating func record(_ state: State) {
        if past.last == state { return }
        past.append(state)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    mutating func undo(from current: State) -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(from current: State) -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }

    mutating func clear() {
        past.removeAll()
        future.removeAll()
    }
}
