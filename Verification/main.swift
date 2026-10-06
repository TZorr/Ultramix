//
//  Verification/main.swift
//  Ultramix
//
//  The verification harness. There is no test target; this is compiled with
//  the Model, Analysis, Engine and Export sources and run - see run.sh.
//
//  The reference values are worked out by hand and written in here as
//  literals. A value the harness computes for itself only proves that the
//  code agrees with itself.
//

import Foundation
import AVFoundation
import CoreML
import CoreMIDI

// MARK: - Harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String,
           file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL \(file):\(line)  \(message())")
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

func section(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "ok   \(name)" : "FAIL \(name)")
}

// MARK: - Tempo map

section("tempo map: constant tempo is exact") {
    let map = TempoMap(projectBPM: 120, targets: [])
    check(map.seconds(atBeat: 8) == 4.0, "8 beats at 120 = 4 s, got \(map.seconds(atBeat: 8))")
    check(map.beat(atSeconds: 4.0) == 8.0, "4 s at 120 = beat 8")
    check(map.seconds(atBeat: -2) == -1.0, "pre-roll extrapolates at the opening tempo")
}

section("tempo map: ramps step at whole beats") {
    // 120 at beat 0 to 128 at beat 4: beats 0,1,2,3 play at 120,122,124,126.
    let map = TempoMap(projectBPM: 120, targets: [TempoPoint(beat: 4, bpm: 128)])
    check(map.bpm(atBeat: 1.99) == 122, "beat 1.99 plays at 122, got \(map.bpm(atBeat: 1.99))")
    check(map.bpm(atBeat: 2.0) == 124, "beat 2.0 plays at 124")
    check(map.bpm(atBeat: 50) == 128, "the last tempo holds")
    // 60/120 + 60/122 + 60/124 + 60/126
    let four = 1.9518647226209363
    check(near(map.seconds(atBeat: 4), four, 1e-12), "seconds(4) = \(map.seconds(atBeat: 4))")
    check(near(map.seconds(atBeat: 10), four + 6 * 60 / 128, 1e-12), "extrapolation past the table")
    check(near(map.seconds(atBeat: 2.5), 0.5 + 60.0 / 122 + 0.5 * 60 / 124, 1e-12), "fraction of a beat")
}

section("tempo map: beat(seconds(b)) round-trips") {
    let map = TempoMap(projectBPM: 124, targets: [
        TempoPoint(beat: 64, bpm: 124), TempoPoint(beat: 96, bpm: 131.5),
        TempoPoint(beat: 200, bpm: 118), TempoPoint(beat: 260, bpm: 118),
    ])
    var worst = 0.0
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<5000 {
        let b = Double.random(in: -4..<400, using: &generator)
        worst = max(worst, abs(map.beat(atSeconds: map.seconds(atBeat: b)) - b))
    }
    check(worst < 1e-9, "worst round-trip error \(worst)")
}

section("tempo map: merging and clamping") {
    let map = TempoMap(projectBPM: 500, targets: [
        TempoPoint(beat: 8, bpm: 100), TempoPoint(beat: 8, bpm: 110), TempoPoint(beat: 0, bpm: 90),
    ])
    check(map.points.count == 2, "duplicates merge, got \(map.points.count)")
    check(map.points[0].bpm == 90, "a target at beat 0 replaces the project tempo")
    check(map.points[1].bpm == 110, "the later target at a shared beat wins")
    let clamped = TempoMap(projectBPM: 500, targets: [])
    check(clamped.points[0].bpm == 300, "BPM is clamped to 300")
    let extremes = map.bpmExtremes(in: 0...20)
    check(extremes.min == 90 && extremes.max == 110, "extremes \(extremes)")
}

section("tempo map: a ramp start holds the tempo until it") {
    // 120 until beat 8, then 120 → 128 over beats 8…16: beat 12 plays at 124.
    let map = TempoMap(projectBPM: 120, targets: [TempoPoint(beat: 16, bpm: 128, rampStart: 8)])
    check(map.bpm(atBeat: 7.5) == 120, "flat before the ramp start: \(map.bpm(atBeat: 7.5))")
    check(map.bpm(atBeat: 12) == 124, "half way up at beat 12: \(map.bpm(atBeat: 12))")
    check(map.bpm(atBeat: 16) == 128, "the target at its point")
    let plain = TempoMap(projectBPM: 120, targets: [TempoPoint(beat: 16, bpm: 128)])
    check(plain.bpm(atBeat: 8) == 124, "without one the ramp runs the whole way")
    let after = TempoMap(projectBPM: 120, targets: [TempoPoint(beat: 16, bpm: 128, rampStart: 20)])
    check(after.points.count == 2, "a ramp start not before its point is ignored")
    let chained = TempoMap(projectBPM: 120, targets: [
        TempoPoint(beat: 16, bpm: 128, rampStart: 8), TempoPoint(beat: 32, bpm: 124, rampStart: 28),
    ])
    check(chained.bpm(atBeat: 27) == 128 && chained.bpm(atBeat: 30) == 126, "each ramp holds from its own previous point")
    var worst = 0.0
    for b in stride(from: -2.0, to: 60, by: 0.37) {
        worst = max(worst, abs(chained.beat(atSeconds: chained.seconds(atBeat: b)) - b))
    }
    check(worst < 1e-9, "round-trip with holds: \(worst)")
}

// MARK: - Clip geometry

// 120 BPM, first downbeat at 1.0 s (2 beats of pre-roll), 120 s long
// (240 beats).
let testGrid = SourceGrid(bpm: 120, firstBeatSeconds: 1.0, durationSeconds: 120)
let trackA = UUID()
let trackB = UUID()
let gridB = SourceGrid(bpm: 128, firstBeatSeconds: 0.25, durationSeconds: 60)  // pre-roll 0.5333, 128 beats
let grids: GridLookup = { id in id == trackA ? testGrid : id == trackB ? gridB : nil }

section("clip geometry and loop segments") {
    var clip = Clip(trackID: trackA, lane: 0, anchorBeat: 8, trimStart: 10, trimEnd: 40)
    let plain = ClipGeometry(clip: clip, grid: testGrid)
    check(plain.fileStart == 6 && plain.bodyStart == 16 && plain.bodyEnd == 206, "geometry \(plain)")
    check(plain.segments() == [ClipSegment(start: 16, end: 206, fileStart: 6)], "one segment when not looping")

    clip.looping = true
    clip.loopLead = 50
    clip.loopTail = 400
    let looped = ClipGeometry(clip: clip, grid: testGrid)
    let segments = looped.segments()
    // Body 190 beats; copies −1…3, the outer two cut at the clip's edges.
    let expected = [
        ClipSegment(start: -34, end: 16, fileStart: -184),
        ClipSegment(start: 16, end: 206, fileStart: 6),
        ClipSegment(start: 206, end: 396, fileStart: 196),
        ClipSegment(start: 396, end: 586, fileStart: 386),
        ClipSegment(start: 586, end: 606, fileStart: 576),
    ]
    check(segments == expected, "segments \(segments)")
    // Every copy starts at the same place in the source: the trimmed head.
    check(segments.dropFirst().allSatisfy { $0.start - $0.fileStart == 10 }, "each copy restarts the body")
}

section("clip geometry: a tempo lowered after trimming cannot turn a clip inside out") {
    // Trimmed at 124 BPM, then corrected to 40: the minute-long file shrinks
    // from 124 beats to 40, and a tail trim of 100 beats no longer fits.
    let fast = SourceGrid(bpm: 124, firstBeatSeconds: 0.5, durationSeconds: 60)
    let slow = SourceGrid(bpm: 40, firstBeatSeconds: 0.5, durationSeconds: 60)
    let clip = Clip(trackID: trackA, lane: 0, anchorBeat: 64, trimStart: 4, trimEnd: 100)
    check(abs(ClipGeometry(clip: clip, grid: fast).bodyLength - 20) < 1e-9, "trims that fit are used as stored")
    let shape = ClipGeometry(clip: clip, grid: slow)
    check(shape.end >= shape.start, "end \(shape.end) not before start \(shape.start)")
    check(abs(shape.bodyLength - Clip.minimumBeats) < 1e-9, "the minimum length is kept: \(shape.bodyLength)")
    check(shape.bodyStart >= shape.fileStart && shape.bodyEnd <= shape.fileStart + slow.lengthBeats + 1e-9,
          "inside the file: \(shape.bodyStart)…\(shape.bodyEnd)")
    check(!shape.segments().isEmpty, "still one segment to play")
    // The expression the render plan crashed on when the mix was opened.
    let map = TempoMap(projectBPM: 124, targets: [])
    _ = map.bpmExtremes(in: max(0, shape.start)...max(0, shape.end))
    check(clip.trimEnd == 100, "the stored trim is untouched, so the old tempo restores the clip")
}

// MARK: - Editing

section("add: first clip sets the tempo, the next chain on") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, grids: grids)
    check(doc.projectBPM == 120, "project tempo from the first track")
    let first = doc.clips[0]
    // Left edge at 0 needs an anchor of at least 2; the lowest bar line is 4.
    check(first.id == a && first.lane == 0 && first.anchorBeat == 4, "first clip \(first)")
    try! doc.addClip(trackID: trackB, grid: gridB, grids: grids)
    let second = doc.clips[1]
    // Mix ends at 4 − 2 + 240 = 242; minus 32 = 210, plus pre-roll → 210.53 → bar 212.
    check(second.lane == 1 && second.anchorBeat == 212, "second clip \(second)")
}

section("move: snaps to bars, refuses overlap, carries automation") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let b = try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 100, grids: grids)
    // b: anchor 100, from 99.47. One node: the clip plays −6 dB throughout.
    doc.addAutomationNode(clip: b, kind: .volume, beat: 110, value: -6, grids: grids)
    check(doc.clips[1].automation.volume == [AutomationNode(beat: 10, value: -6)], "stored clip-local: \(doc.clips[1].automation.volume)")
    check(LanePlan(document: doc, lane: 1, grids: grids).volume.value(at: 110) == -6, "and heard at 110")
    try! doc.moveClip(b, anchorBeat: 129.7, lane: 1, grids: grids)
    check(doc.clips[1].anchorBeat == 128, "snapped to bar 128, got \(doc.clips[1].anchorBeat)")
    check(doc.clips[1].tempoAnchorBeat == 128, "tempo point moves with the clip")
    check(doc.clips[1].automation.volume == [AutomationNode(beat: 10, value: -6)], "the stored node is untouched by a move")
    let moved = LanePlan(document: doc, lane: 1, grids: grids).volume
    check(moved.value(at: 138) == -6, "the curve went with the clip")
    check(moved.value(at: 110) == Automation.defaultVolumeDB, "the place it left rests: \(moved.value(at: 110))")
    var refused = false
    do { try doc.moveClip(b, anchorBeat: 100, lane: 0, grids: grids) } catch { refused = true }
    check(refused, "lane 1 overlaps clip a")
    check(doc.clips[1].lane == 1 && doc.clips[1].anchorBeat == 128, "a refused move changes nothing")

    // To another lane: the curve changes lane with the clip.
    try! doc.moveClip(b, anchorBeat: 128, lane: 2, grids: grids)
    check(LanePlan(document: doc, lane: 2, grids: grids).volume.value(at: 138) == -6, "heard on lane C now")
    check(LanePlan(document: doc, lane: 1, grids: grids).volume.value(at: 138) == Automation.defaultVolumeDB, "lane B rests")
    _ = a
}

section("nudge: a beat at a time, with its tempo point and automation") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 16, grids: grids)
    check(doc.clips[0].anchorBeat == 20, "starts on bar line 20: \(doc.clips[0].anchorBeat)")
    doc.addAutomationNode(clip: a, kind: .volume, beat: 30, value: -6, grids: grids)
    doc.addAutomationNode(clip: a, kind: .volume, beat: 40, value: 0, grids: grids)
    let before = LanePlan(document: doc, lane: 0, grids: grids).volume
    try! doc.nudgeClips([a], byBeats: 1, grids: grids)
    check(doc.clips[0].anchorBeat == 21, "one beat, not one bar: \(doc.clips[0].anchorBeat)")
    check(doc.clips[0].tempoAnchorBeat == 21, "the tempo point moves with it")
    let after = LanePlan(document: doc, lane: 0, grids: grids).volume
    check(stride(from: 30.0, through: 40, by: 0.5).allSatisfy { after.value(at: $0 + 1) == before.value(at: $0) },
          "the curve moves a beat with the clip")
    try! doc.nudgeClips([a], byBeats: -1, grids: grids)
    check(doc.clips[0].anchorBeat == 20, "and back")

    // At the start of the mix: refused, and nothing changes.
    try! doc.moveClip(a, anchorBeat: 0, lane: 0, grids: grids)   // lowest bar line: 4
    let atStart = doc
    check((try? doc.nudgeClips([a], byBeats: -1, grids: grids)) == nil && doc == atStart, "no nudge past the start")

    // Into a neighbour: refused. Left spans 2…242, right 244…484.
    var two = MixDocument()
    let left = try! two.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    two.clips.append(Clip(trackID: trackA, lane: 0, anchorBeat: 246))
    let right = two.clips[1].id
    try! two.nudgeClips([left], byBeats: 1, grids: grids)
    try! two.nudgeClips([left], byBeats: 1, grids: grids)   // now end to end
    let touching = two
    check((try? two.nudgeClips([left], byBeats: 1, grids: grids)) == nil && two == touching, "no nudge into the neighbour")
    // Selected together they move in both directions, whichever comes first.
    try! two.nudgeClips([left, right], byBeats: 1, grids: grids)
    check(two.clips.map(\.anchorBeat) == [7, 247], "together right: \(two.clips.map(\.anchorBeat))")
    try! two.nudgeClips([left, right], byBeats: -1, grids: grids)
    check(two.clips.map(\.anchorBeat) == [6, 246], "together left: \(two.clips.map(\.anchorBeat))")
    // Dragging still snaps to bars.
    try! two.moveClip(right, anchorBeat: 301.3, lane: 0, grids: grids)
    check(two.clips[1].anchorBeat == 300, "a drag lands on a bar line: \(two.clips[1].anchorBeat)")
}

section("move mode: what a drag snaps to") {
    check(MoveMode.off.step == nil && MoveMode.free.step == 1 && MoveMode.half.step == 2 && MoveMode.full.step == 4,
          "steps: off none, free 1, half 2, full 4")
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 16, grids: grids)
    try! doc.moveClips([a], dragging: a, anchorBeat: 26.6, lane: 0, step: 1, grids: grids)
    check(doc.clips[0].anchorBeat == 27, "free: the nearest beat: \(doc.clips[0].anchorBeat)")
    check(doc.clips[0].tempoAnchorBeat == 27, "free: the tempo point goes along")
    try! doc.moveClips([a], dragging: a, anchorBeat: 21.2, lane: 0, step: 2, grids: grids)
    check(doc.clips[0].anchorBeat == 22, "half: the nearest half bar: \(doc.clips[0].anchorBeat)")
    try! doc.moveClips([a], dragging: a, anchorBeat: 22.4, lane: 0, grids: grids)
    check(doc.clips[0].anchorBeat == 24, "full, the default: the nearest bar line: \(doc.clips[0].anchorBeat)")
    // Pre-roll 2 beats: the lowest anchor is the first step at or after it.
    let clip = doc.clips[0]
    check(MixDocument.minimumAnchor(clip, testGrid, step: 1) == 2, "free reaches the start exactly")
    check(MixDocument.minimumAnchor(clip, testGrid, step: 2) == 2, "half reaches the start exactly")
    check(MixDocument.minimumAnchor(clip, testGrid) == 4, "full stops on the first bar line")
    try! doc.moveClips([a], dragging: a, anchorBeat: -5, lane: 0, step: 1, grids: grids)
    check(doc.clips[0].anchorBeat == 2, "free: a drag past the start stops at it: \(doc.clips[0].anchorBeat)")
}

section("tempo strip: point labels do not overlap") {
    let strip = CGRect(x: 0, y: 30, width: 1000, height: 58)
    let label = CGSize(width: 30, height: 12)
    func point(_ x: CGFloat, _ y: CGFloat) -> TempoLabels.Point { .init(x: x, y: y, size: label) }
    func rects(_ points: [TempoLabels.Point], _ slots: [TempoLabels.Slot]) -> [CGRect] {
        zip(points, slots).compactMap { $1 == .hidden ? nil : TempoLabels.rect($1, for: $0) }
    }
    func overlapFree(_ points: [TempoLabels.Point], _ slots: [TempoLabels.Slot]) -> Bool {
        let placed = rects(points, slots)
        let dots = points.map { CGRect(x: $0.x - 5, y: $0.y - 5, width: 10, height: 10) }
        for (i, r) in placed.enumerated() {
            if placed.enumerated().contains(where: { $0.offset != i && $0.element.intersects(r) }) { return false }
        }
        // A label may touch only its own point.
        for (p, s) in zip(points, slots) where s != .hidden {
            let r = TempoLabels.rect(s, for: p)
            if dots.contains(where: { $0.intersects(r) && !($0.midX == p.x && $0.midY == p.y) }) { return false }
        }
        return true
    }

    let apart = [point(100, 59), point(300, 59)]
    check(TempoLabels.place(apart, in: strip) == [.right, .right], "far apart: both beside their points")

    // The case seen in the app: two points 18 pt apart at the same tempo.
    let close = [point(100, 59), point(118, 59)]
    let slots = TempoLabels.place(close, in: strip)
    check(slots == [.above, .right], "close: the later keeps its place, the earlier moves up: \(slots)")
    check(overlapFree(close, slots), "close: nothing overlaps")

    // At the top of the strip there is no room above, so below.
    let high = [point(100, 40), point(118, 40)]
    check(TempoLabels.place(high, in: strip) == [.below, .right], "near the top: below")

    // Three in a row, 6 pt apart: right, above and below still take all
    // three. A fourth has nowhere left and is not written.
    let crowd = [point(100, 59), point(106, 59), point(112, 59)]
    let crowded = TempoLabels.place(crowd, in: strip)
    check(crowded == [.below, .above, .right] && overlapFree(crowd, crowded), "three: all placed, apart: \(crowded)")
    let four = [point(94, 59)] + crowd
    let packed = TempoLabels.place(four, in: strip)
    check(packed == [.hidden, .below, .above, .right] && overlapFree(four, packed), "four: the first gives up: \(packed)")

    // The scale numbers in the corner are kept clear.
    let corner = CGRect(x: 4, y: 32, width: 18, height: 11)
    check(TempoLabels.place([point(30, 45)], in: strip, blocked: [corner]) == [.right], "beside the corner: unchanged")
    check(TempoLabels.place([point(8, 45)], in: strip, blocked: [corner]) == [.below], "over the corner: moves below")
    // What the app showed: points 14 pt apart right at the start, the scale
    // numbers in both corners. Both labels are written.
    let low = CGRect(x: 4, y: 75, width: 16, height: 11)
    let start = [point(16.5, 59), point(30.5, 59)]
    let startSlots = TempoLabels.place(start, in: strip, blocked: [CGRect(x: 4, y: 32, width: 16, height: 11), low])
    check(!startSlots.contains(.hidden) && overlapFree(start, startSlots), "at the start: both written: \(startSlots)")
    let under = [point(2, 50)]
    let underSlot = TempoLabels.place(under, in: strip, blocked: [corner])
    check(!underSlot.contains(.above), "never on the scale number: \(underSlot)")

    // A label may run out of view sideways, as the strip scrolls.
    check(TempoLabels.place([point(990, 59)], in: strip) == [.right], "at the right edge: still beside it")
}

section("lock: a locked clip keeps its place") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 16, grids: grids)
    let b = try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 16, grids: grids)
    doc.setLocked(a, true)
    let locked = doc
    check((try? doc.moveClips([a], dragging: a, anchorBeat: 40, lane: 2, grids: grids)) == nil && doc == locked,
          "a locked clip is not dragged")
    check((try? doc.moveClips([a, b], dragging: b, anchorBeat: 40, lane: 1, grids: grids)) == nil && doc == locked,
          "nor is a selection holding it, by another clip")
    check((try? doc.nudgeClips([a], byBeats: 1, grids: grids)) == nil && doc == locked, "nor nudged")
    check((try? doc.nudgeClips([a, b], byBeats: 1, grids: grids)) == nil && doc == locked, "nor nudged with others")
    check((try? doc.moveClip(a, anchorBeat: 40, lane: 0, grids: grids)) == nil && doc == locked, "nor moved on its own")
    try! doc.nudgeClips([b], byBeats: 1, grids: grids)
    check(doc.clips.first { $0.id == b }?.anchorBeat != locked.clips.first { $0.id == b }?.anchorBeat,
          "an unlocked neighbour still moves")
    doc.setGain(a, -3)
    try! doc.trimClip(a, edge: .end, to: 60, grids: grids)
    check(doc.clips[0].gainDB == -3 && doc.clips[0].trimEnd > 0, "gain and trim still work")
    let right = try! doc.splitClip(a, at: 40, grids: grids)
    check(doc.clips.first { $0.id == right }?.locked == true && doc.clips[0].locked, "both halves of a split stay locked")
    let copy = try! doc.duplicateClip(right, grids: grids)
    check(doc.clips.first { $0.id == copy }?.locked == true, "a duplicate is locked too")
    doc.setLocked(a, false)
    // Left: the right half of the split stands against it on the right.
    try! doc.nudgeClips([a], byBeats: -1, grids: grids)
    check(doc.clips.first { $0.id == a }?.anchorBeat == 19, "unlocked, it moves again")

    // Saved only when set, and an older mix without the key loads unlocked.
    var clip = Clip(trackID: trackA, lane: 0, anchorBeat: 8)
    let plain = String(data: try! JSONEncoder().encode(clip), encoding: .utf8)!
    check(!plain.contains("locked"), "an unlocked clip writes no lock: \(plain)")
    check(try! JSONDecoder().decode(Clip.self, from: Data(plain.utf8)).locked == false, "no key reads as unlocked")
    clip.locked = true
    let saved = try! JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
    check(saved.locked, "a lock survives saving")
}

section("drag: the whole selection travels together") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let b = try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 400, grids: grids)
    let anchorA = doc.clips[0].anchorBeat
    let anchorB = doc.clips[1].anchorBeat

    // Dragging a by 16 bars-worth of beats takes b along, distance kept.
    try! doc.moveClips([a, b], dragging: a, anchorBeat: Double(anchorA + 16) + 1.3, lane: 0, grids: grids)
    check(doc.clips.map(\.anchorBeat) == [anchorA + 16, anchorB + 16], "both moved: \(doc.clips.map(\.anchorBeat))")
    check(doc.clips.map(\.lane) == [0, 1], "lanes unchanged: \(doc.clips.map(\.lane))")
    check(doc.clips[1].tempoAnchorBeat == anchorB + 16, "the tempo point travels with its clip")

    // A lane down moves both a lane down.
    try! doc.moveClips([a, b], dragging: a, anchorBeat: Double(anchorA + 16), lane: 1, grids: grids)
    check(doc.clips.map(\.lane) == [1, 2], "one lane down: \(doc.clips.map(\.lane))")
    // Further down is clamped, not refused: b is on the last lane already,
    // so the pair only moves sideways.
    try! doc.moveClips([a, b], dragging: a, anchorBeat: Double(anchorA + 20), lane: 2, grids: grids)
    check(doc.clips.map(\.lane) == [1, 2], "clamped at the last lane: \(doc.clips.map(\.lane))")
    check(doc.clips.map(\.anchorBeat) == [anchorA + 20, anchorB + 20], "and still follows sideways")

    // All or nothing: a neighbour in the way of b stops the pair. b is 128
    // beats long, so a clip four beats past its tail blocks a drag of eight.
    var pair = MixDocument()
    let left = try! pair.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let right = try! pair.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 400, grids: grids)
    pair.clips.append(Clip(trackID: trackB, lane: 1, anchorBeat: pair.clips[1].anchorBeat + 132))
    check(pair.fits(pair.clips[2], grids), "the neighbour stands clear to begin with")
    let blocked = pair
    var refused = false
    do { try pair.moveClips([left, right], dragging: left, anchorBeat: Double(pair.clips[0].anchorBeat + 8),
                            lane: 0, grids: grids) }
    catch { refused = true }
    check(refused && pair == blocked, "a blocked selection does not move at all")

    // Neither does one that would push a clip before the start of the mix.
    var early = MixDocument()
    let first = try! early.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let second = try! early.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 400, grids: grids)
    let atStart = early
    refused = false
    do { try early.moveClips([first, second], dragging: second, anchorBeat: 4, lane: 1, grids: grids) }
    catch { refused = true }
    check(refused && early == atStart, "nothing is dragged off the front of the mix")

    // One clip is a selection of one, and lands on a bar line as before.
    var single = MixDocument()
    let only = try! single.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! single.moveClips([only], dragging: only, anchorBeat: 101.4, lane: 2, grids: grids)
    check(single.clips[0].anchorBeat == 100 && single.clips[0].lane == 2, "single: \(single.clips[0])")
}

section("delete: a clip takes its automation, and only its own") {
    // A crossfade: the deleted clip's fade-out goes, the partner's fade-in stays.
    var mix = MixDocument()
    let outgoing = try! mix.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! mix.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
    try! mix.autoCrossfade(nil, grids: grids)
    let fadeIn = mix.clips[1].automation
    mix.removeClips([outgoing], grids: grids)
    check(mix.clips.count == 1 && mix.clips[0].automation == fadeIn && !fadeIn.volume.isEmpty, "the partner's fade-in stays")
    check(LanePlan(document: mix, lane: 0, grids: grids).volume.value(at: 230) == Automation.defaultVolumeDB,
          "lane A rests where the clip was")
}

section("clip automation: ⌥⌫ empties the clip, the hidden part included, and leaves it") {
    // a: anchor 4, 2…242; b on lane B.
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 0, grids: grids)
    doc.addAutomationNode(clip: a, kind: .volume, beat: 20, value: -6, grids: grids)
    doc.addAutomationNode(clip: a, kind: .pan, beat: 100, value: 0.5, grids: grids)
    doc.addGesture(AutomationGesture(kind: .lowPass, start: 210, end: 225, shape: .sine, period: 2, low: 0, high: 1),
                   clip: a, grids: grids)
    doc.addAutomationNode(clip: doc.clips[1].id, kind: .volume, beat: 20, value: -6, grids: grids)
    // Trimmed to 42…202: the volume node and the filter gesture are hidden.
    try! doc.trimClip(a, edge: .start, to: 42, grids: grids)
    try! doc.trimClip(a, edge: .end, to: 202, grids: grids)
    check(doc.clips[0].automation.volume.count == 1 && doc.clips[0].automation.gestures.count == 1,
          "a trim keeps what it hides")

    var nothing = doc
    try! nothing.removeAutomation(onClips: [])
    check(nothing == doc, "nothing selected: nothing changes")
    var expected = doc.clips[0]
    expected.automation = ClipAutomation()
    try! doc.removeAutomation(onClips: [a])
    check(doc.clips[0] == expected, "every kind, gestures and hidden points too, and the clip otherwise as it was")
    check(doc.clips[1].automation.volume.count == 1, "other clips keep theirs")
}

section("lock: a locked clip's automation stays as it is") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)   // body 2 … 242
    let b = try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
    let node = doc.addAutomationNode(clip: a, kind: .volume, beat: 50, value: -6, grids: grids)!
    doc.addGesture(AutomationGesture(kind: .highPass, start: 60, end: 70, shape: .sine, period: 2, low: 0, high: 1),
                   clip: a, grids: grids)
    let gesture = doc.clips[0].automation.gestures[0].id
    doc.setLocked(a, true)
    let locked = doc

    check(doc.addAutomationNode(clip: a, kind: .pan, beat: 80, value: 0.5, grids: grids) == nil && doc == locked,
          "no point placed")
    check(doc.moveAutomationNode(clip: a, kind: .volume, from: node, toBeat: 90, value: 0, grids: grids) == nil
          && doc == locked, "no point moved")
    doc.removeAutomationNode(clip: a, kind: .volume, node: node)
    doc.resetAutomationNode(node, kind: .volume, clip: a)
    check(doc == locked, "no point removed or reset")
    check(!doc.addGesture(AutomationGesture(kind: .pan, start: 100, end: 120, shape: .step, period: 1, low: -1, high: 1),
                          clip: a, grids: grids) && doc == locked, "no movement drawn")
    doc.removeGesture(gesture, clip: a)
    check(doc == locked, "no movement removed")
    var selection = AutomationSelection(kind: .volume)
    selection.nodes[a] = [node]
    doc.deleteAutomation(selection)
    check(doc == locked, "a selection does not delete its points")
    check((try? doc.removeAutomation(onClips: [a])) == nil && doc == locked, "⌥⌫ on the locked clip alone says so")
    doc.addAutomationNode(clip: b, kind: .volume, beat: 300, value: -2, grids: grids)
    try! doc.removeAutomation(onClips: [a, b])
    check(doc.clips[0].automation == locked.clips[0].automation && doc.clips[1].automation.isEmpty,
          "⌥⌫ over both clears only the unlocked one")

    // A transition writes only the side that is not locked.
    let count = try! doc.autoCrossfade(nil, grids: grids)
    check(count == 1, "the transition is still written: \(count)")
    check(doc.clips[0].automation == locked.clips[0].automation, "the locked outgoing clip keeps its points")
    check(!doc.clips[1].automation.volume.isEmpty, "the incoming clip gets its fade")
    doc.setLocked(b, true)
    let both = doc
    check((try? doc.autoCrossfade(nil, grids: grids)) == nil && doc == both, "locked on both sides: nothing, and said")

    // A beatmix over a locked last clip leaves it alone and still adds.
    var mix = MixDocument()
    let first = try! mix.addClip(trackID: trackA, grid: testGrid, beatmix: .beats16, grids: grids)
    mix.setLocked(first, true)
    try! mix.addClip(trackID: trackB, grid: gridB, beatmix: .beats16, grids: grids)
    check(mix.clips.count == 2 && mix.clips[0].automation.isEmpty, "the locked clip gets no fade-out")
    check(mix.clips[1].automation.volume.count == 3, "the new track still fades in")

    doc.setLocked(a, false)
    check(doc.addAutomationNode(clip: a, kind: .pan, beat: 80, value: 0.5, grids: grids) != nil, "unlocked, it is editable again")
}

section("regions: automation sounds only inside its clip") {
    // End to end on lane A after two nudges: left anchor 6, 4…244; right
    // anchor 246, 244…484.
    var pair = MixDocument()
    let left = try! pair.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    pair.clips.append(Clip(trackID: trackA, lane: 0, anchorBeat: 246))
    let right = pair.clips[1].id
    try! pair.nudgeClips([left], byBeats: 2, grids: grids)
    check(pair.geometry(pair.clips[0], grids)!.end == 244 && pair.geometry(pair.clips[1], grids)!.start == 244,
          "the two touch at 244")
    pair.addAutomationNode(clip: left, kind: .volume, beat: 100, value: -12, grids: grids)
    pair.addAutomationNode(clip: right, kind: .volume, beat: 300, value: 3, grids: grids)
    pair.addAutomationNode(clip: left, kind: .lowPass, beat: 10, value: 0.5, grids: grids)
    pair.addAutomationNode(clip: left, kind: .highPass, beat: 10, value: 0.3, grids: grids)
    let plan = LanePlan(document: pair, lane: 0, grids: grids)
    check(plan.volume.value(at: 243.9) == -12, "the left clip's curve up to the boundary")
    check(plan.volume.value(at: 244) == 3, "the right clip's from the boundary on")
    check(plan.volume.value(at: 3) == Automation.defaultVolumeDB, "before every clip the lane rests, though the left clip holds −12 there")
    check(plan.volume.value(at: 600) == Automation.defaultVolumeDB, "past every clip the lane rests")
    check(plan.lowPass.value(at: 200) == 0.5 && plan.lowPass.value(at: 300) == 1, "the low-pass is open on the clip that has none")
    check(plan.highPass.value(at: 200) == 0.3 && plan.highPass.value(at: 300) == 0, "the high-pass is off on the clip that has none")
    check(LanePlan(document: pair, lane: 1, grids: grids).volume.value(at: 100) == Automation.defaultVolumeDB, "an empty lane rests")

    check(pair.clip(atBeat: 250, lane: 0, grids: grids)?.id == right, "the clip under a beat")
    check(pair.clip(atBeat: 600, lane: 0, grids: grids) == nil && pair.clip(atBeat: 100, lane: 1, grids: grids) == nil,
          "no clip, no automation to draw on")

    // Held to the visible clip.
    var clamp = pair
    check(clamp.addAutomationNode(clip: left, kind: .pan, beat: 900, value: 5, grids: grids) == AutomationNode(beat: 238, value: 1),
          "a node past the tail lands on it (244 − anchor 6), its value held to the range")
    let node = clamp.clips[0].automation.volume[0]
    let moved = clamp.moveAutomationNode(clip: left, kind: .volume, from: node, toBeat: -50, value: -6, grids: grids)
    check(moved == AutomationNode(beat: -2, value: -6) && clamp.clips[0].automation.volume == [moved!],
          "dragged past the head it stops on it (4 − 6): \(String(describing: moved))")
    let over = AutomationGesture(kind: .highPass, start: 240, end: 260, shape: .step, period: 1, low: 0, high: 1)
    check(clamp.addGesture(over, clip: left, grids: grids), "a gesture reaching past the clip is added")
    let stored = clamp.clips[0].automation.gestures.last!
    check(stored.start == 234 && stored.end == 238, "cut to the clip: \(stored.start)…\(stored.end)")
    let beyond = AutomationGesture(kind: .highPass, start: 250, end: 260, shape: .step, period: 1, low: 0, high: 1)
    check(!clamp.addGesture(beyond, clip: left, grids: grids), "one wholly past the clip is not")
    check(clamp.addAutomationNode(clip: UUID(), kind: .volume, beat: 10, value: 0, grids: grids) == nil, "no such clip, nothing added")
}

section("regions: trim hides, extending restores; split, duplicate, loop") {
    // anchor 4, 2…242.
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    doc.addAutomationNode(clip: a, kind: .volume, beat: 20, value: -20, grids: grids)
    doc.addAutomationNode(clip: a, kind: .volume, beat: 60, value: 0, grids: grids)
    doc.addGesture(AutomationGesture(kind: .pan, start: 100, end: 120, shape: .sine, period: 4, low: -1, high: 1),
                   clip: a, grids: grids)
    let original = doc
    func samples(_ d: MixDocument, lane: Int = 0, _ kind: AutomationKind) -> [Double] {
        let curve = LanePlan(document: d, lane: lane, grids: grids).curve(kind)
        return stride(from: 2.0, to: 242, by: 1.0 / 16).map { curve.value(at: $0) }
    }

    try! doc.trimClip(a, edge: .start, to: 40, grids: grids)
    try! doc.trimClip(a, edge: .end, to: 110, grids: grids)
    let trimmed = LanePlan(document: doc, lane: 0, grids: grids)
    check(doc.clips[0].automation == original.clips[0].automation, "a trim keeps every point")
    check(trimmed.volume.value(at: 30) == Automation.defaultVolumeDB, "the hidden head is not heard")
    check(trimmed.volume.value(at: 40) == -10, "the edge still interpolates from the hidden node: \(trimmed.volume.value(at: 40))")
    try! doc.trimClip(a, edge: .start, to: 0, grids: grids)
    try! doc.trimClip(a, edge: .end, to: 300, grids: grids)
    check(samples(doc, .volume) == samples(original, .volume) && samples(doc, .pan) == samples(original, .pan),
          "extended again, the curve is exactly back")

    var split = original
    let right = try! split.splitClip(a, at: 80, grids: grids)
    check(split.clips.allSatisfy { $0.automation == original.clips[0].automation }, "both halves get the whole automation")
    check(samples(split, .volume) == samples(original, .volume) && samples(split, .pan) == samples(original, .pan),
          "a split does not change what is heard")
    _ = right

    var copied = original
    let copy = try! copied.duplicateClip(a, grids: grids)
    check(copied.clips.first { $0.id == copy }?.lane == 1, "the copy goes to lane B")
    check(copied.clips.first { $0.id == copy }?.automation == original.clips[0].automation, "a duplicate copies the automation")
    check(samples(copied, lane: 1, .volume) == samples(original, .volume), "and sounds like the original")

    // Looping: one curve across the whole length, not one per copy.
    var loop = MixDocument()
    let l = try! loop.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    loop.setLooping(l, true)
    try! loop.setLoopExtent(l, edge: .end, to: 342, grids: grids)
    loop.addAutomationNode(clip: l, kind: .volume, beat: 4, value: 0, grids: grids)
    check(loop.addAutomationNode(clip: l, kind: .volume, beat: 300, value: -30, grids: grids)?.beat == 296,
          "a node in the loop tail is placed there")
    let looped = LanePlan(document: loop, lane: 0, grids: grids).volume
    check(looped.value(at: 300) == -30 && looped.value(at: 330) == -30, "heard where it was placed")
    check(looped.value(at: 60) != -30, "not repeated a body earlier: \(looped.value(at: 60))")
}

section("trim: quarter beats, anchor fixed, limits") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    // anchor 4, fileStart 2, body 2…242
    try! doc.trimClip(a, edge: .start, to: 17.13, grids: grids)
    check(doc.clips[0].trimStart == 15.25 && doc.clips[0].anchorBeat == 4, "head trim \(doc.clips[0])")
    try! doc.trimClip(a, edge: .end, to: 1000, grids: grids)
    check(doc.clips[0].trimEnd == 0, "tail cannot grow past the file")
    try! doc.trimClip(a, edge: .end, to: 0, grids: grids)
    let shape = ClipGeometry(clip: doc.clips[0], grid: testGrid)
    check(abs(shape.bodyLength - Clip.minimumBeats) < 1e-9, "trim stops at the minimum length, got \(shape.bodyLength)")
}

section("split: whole beat, tempo line unchanged") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let b = try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
    doc.setTargetBPM(b, 126)
    let before = doc.tempoMap(grids)
    let right = try! doc.splitClip(a, at: 100.4, grids: grids)
    check(doc.clips.count == 3 && doc.clips[1].id == right, "right half inserted after the left")
    let left = ClipGeometry(clip: doc.clips[0], grid: testGrid)
    let rightShape = ClipGeometry(clip: doc.clips[1], grid: testGrid)
    check(left.bodyEnd == 100 && rightShape.bodyStart == 100, "split at beat 100: \(left.bodyEnd) / \(rightShape.bodyStart)")
    check(doc.clips[1].anchorBeat == doc.clips[0].anchorBeat, "both halves keep the anchor")
    let after = doc.tempoMap(grids)
    var worst = 0.0
    for beat in stride(from: 0.0, to: 400, by: 0.37) {
        worst = max(worst, abs(after.seconds(atBeat: beat) - before.seconds(atBeat: beat)))
    }
    check(worst < 1e-9, "tempo map changed by the split: \(worst)")
}

section("ramp start: bars, before its point, travels with its clip, keeps the line through a split") {
    var doc = MixDocument()
    let b = try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 100, grids: grids)
    let anchor = doc.clips[0].anchorBeat
    doc.setTargetBPM(b, 126)
    doc.moveTempoAnchor(b, to: Double(anchor + 64), grids: grids)
    let point = doc.clips[0].tempoAnchorBeat
    check(point == anchor + 64, "tempo point late in the clip: \(point) vs anchor \(anchor)")
    doc.setRampStart(b, to: Double(point) - 17.2)
    check(doc.clips[0].rampStartBeat == point - 16, "nearest bar: \(String(describing: doc.clips[0].rampStartBeat))")
    doc.setRampStart(b, to: Double(point) + 40)
    check(doc.clips[0].rampStartBeat == point - 1, "never at or after its point")
    doc.setRampStart(b, to: Double(point) - 32)

    // Split before the ramp start and between it and the point: the line stays.
    for at in [Double(point) - 48, Double(point) - 16] {
        var copy = doc
        let before = copy.tempoMap(grids)
        try! copy.splitClip(b, at: at, grids: grids)
        let after = copy.tempoMap(grids)
        var drift = 0.0
        for beat in stride(from: 0.0, to: Double(point) + 40, by: 0.37) {
            drift = max(drift, abs(after.seconds(atBeat: beat) - before.seconds(atBeat: beat)))
        }
        check(drift < 1e-9, "split at \(at) keeps the tempo line: \(drift)")
    }

    try! doc.moveClip(b, anchorBeat: Double(anchor + 32), lane: 1, grids: grids)
    check(doc.clips[0].rampStartBeat == point, "moves with its clip: \(String(describing: doc.clips[0].rampStartBeat))")
    doc.moveTempoAnchor(b, to: Double(doc.clips[0].anchorBeat), grids: grids)
    check(doc.clips[0].rampStartBeat == nil, "a point dragged back over its ramp start drops it")
    doc.setRampStart(b, to: Double(doc.clips[0].tempoAnchorBeat) - 8)
    doc.removeRampStart(b)
    check(doc.clips[0].rampStartBeat == nil, "removed")
}

section("duplicate: below, above, after, before") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackB, grid: gridB, lane: 0, startBeat: 0, grids: grids)
    // 128 beats + pre-roll-trimmed start; length 128 → step 128.
    let c1 = try! doc.duplicateClip(a, grids: grids)
    check(doc.clips.last!.id == c1 && doc.clips.last!.lane == 1, "first copy to the lane below")
    let c2 = try! doc.duplicateClip(c1, grids: grids)
    check(doc.clips.last!.lane == 2 && doc.clips.last!.id == c2, "copy of lane 1 goes below again")
    let c3 = try! doc.duplicateClip(c2, grids: grids)
    let copy = doc.clips.last!
    check(copy.id == c3 && copy.lane == 2 && copy.anchorBeat == doc.clips[0].anchorBeat + 128,
          "then after it on its own lane: \(copy)")
}

section("loop: extent and switching off") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 64, grids: grids)
    doc.setLooping(a, true)
    try! doc.trimClip(a, edge: .end, to: 500.1, grids: grids)
    let shape = ClipGeometry(clip: doc.clips[0], grid: testGrid)
    check(shape.end == 500 && doc.clips[0].trimEnd == 0, "end handle extends the loop: \(shape.end)")
    doc.setLooping(a, false)
    check(doc.clips[0].loopTail == 0 && doc.clips[0].loopLead == 0, "switching off forgets the extent")
}

section("typed tempo: read on confirmation, clamped only then") {
    check(BPMInput.parse("120") == 120, "120")
    check(BPMInput.parse(" 124,5 ") == 124.5, "comma and spaces")
    check(BPMInput.parse("123.456") == 123.456, "decimals")
    check(BPMInput.parse("12") == TempoMap.bpmRange.lowerBound, "below the range: its floor")
    check(BPMInput.parse("999") == TempoMap.bpmRange.upperBound, "above the range: its ceiling")
    check(BPMInput.parse("abc") == nil && BPMInput.parse("") == nil, "not a number: nothing")
    check(BPMInput.parse("nan") == nil && BPMInput.parse("inf") == nil, "not finite: nothing")
    check(!BPMInput.isLargeChange(from: 124, to: 124.35), "a fine correction is not asked about")
    check(!BPMInput.isLargeChange(from: 124, to: 150) && !BPMInput.isLargeChange(from: 124, to: 100), "up to a quarter either way")
    check(BPMInput.isLargeChange(from: 124, to: 40), "124 → 40 is asked about")
    check(BPMInput.isLargeChange(from: 87, to: 174) && BPMInput.isLargeChange(from: 174, to: 87), "an octave typed by hand is asked about")
    check(!BPMInput.isLargeChange(from: 0, to: 120), "no tempo yet: nothing to compare")
}

// MARK: - Automation

section("automation: fader taper, curves, gestures") {
    check(Automation.faderTravel(dB: 0) == 0.5, "unity sits mid-lane")
    check(Automation.faderTravel(dB: -10) == 0.25, "−10 dB half way down the lower half")
    check(Automation.dB(faderTravel: 0.25) == -10, "inverse")
    check(Automation.dB(faderTravel: 0) == Automation.silenceDB, "bottom is silence")
    check(Automation.gain(dB: Automation.silenceDB) == 0, "silence is exactly zero")

    var drawn = ClipAutomation()
    drawn.volume = [AutomationNode(beat: 0, value: -12), AutomationNode(beat: 8, value: 0)]
    let volume = AutomationCurve(kind: .volume, automation: drawn)
    check(volume.value(at: 4) == -6, "linear in dB")
    check(volume.value(at: -3) == -12 && volume.value(at: 99) == 0, "holds outside the nodes")

    drawn.highPass = [AutomationNode(beat: 16, value: 0.5, tension: 0.5), AutomationNode(beat: 32, value: 1)]
    let filter = AutomationCurve(kind: .highPass, automation: drawn)
    check(filter.value(at: 8) == 0, "the high-pass is off before its first node")
    drawn.lowPass = [AutomationNode(beat: 16, value: 0.2)]
    check(AutomationCurve(kind: .lowPass, automation: drawn).value(at: 8) == 1, "the low-pass is open before its first node")
    // tension 0.5 → exponent 2: t = 0.5 → 0.25.
    check(filter.value(at: 24) == 0.625, "tension bends the segment: \(filter.value(at: 24))")

    drawn.gestures = [AutomationGesture(kind: .volume, start: 2, end: 6, shape: .step, period: 2, low: -30, high: 0)]
    let gated = AutomationCurve(kind: .volume, automation: drawn)
    check(gated.value(at: 2.5) == 0 && gated.value(at: 3.5) == -30, "step gesture: high then low")
    // The gesture hands back at beat 6 at the value the nodes had there
    // (−3 dB), and the original line carries on: −1.5 dB at beat 7.
    check(gated.value(at: 7) == -1.5, "outside the gesture the nodes still rule: \(gated.value(at: 7))")
}

// MARK: - Document

section("document: round-trip and old files") {
    var doc = MixDocument(projectBPM: 126.5)
    var drawn = ClipAutomation()
    drawn.pan = [AutomationNode(beat: 4, value: -0.5, tension: 0.2)]
    drawn.gestures = [AutomationGesture(kind: .pan, start: 1, end: 9, shape: .triangle, period: 4, low: -1, high: 1)]
    doc.clips = [Clip(trackID: trackA, lane: 2, anchorBeat: 12, tempoAnchorBeat: 16, targetBPM: 127, rampStartBeat: 8,
                      trimStart: 1.25, trimEnd: 3.5, looping: true, loopLead: 2, loopTail: 8, muted: true,
                      automation: drawn)]
    doc.lanes[1].muted = true
    doc.lanes[2].solo = true
    doc.lanes[0].color = "12AB34"
    doc.tracks = [TrackReference(id: trackA, path: "/Music/a.mp3")]
    let data = try! doc.fileData()
    let restored = try! MixDocument.load(from: data)
    check(restored == doc, "every field survives a save")
    let text = String(data: data, encoding: .utf8)!
    check(text.contains("\"version\" : 3"), "saved as format 3")
    // A mix is passed around; a bookmark would carry the absolute paths of
    // the Mac that made it into a field nobody reads.
    check(!text.contains("bookmark"), "a track reference writes no bookmark")
    check(!text.contains("\"volume\"") && !text.contains("\"lpf\"") && !text.contains("\"hpf\""), "empty kinds leave no key")
    var bare = MixDocument()
    bare.clips = [Clip(trackID: trackA, lane: 0, anchorBeat: 4)]
    check(!String(data: try! bare.fileData(), encoding: .utf8)!.contains("automation"), "a clip with nothing drawn writes no key")

    // A v1 mix: its lane curves are not read (no migration), the lanes' mute,
    // solo and colour are.
    let v1 = """
    {"format":"ultramix-mix","version":1,
     "clips":[{"id":"\(UUID().uuidString)","trackID":"\(trackA.uuidString)","anchorBeat":8}],
     "lanes":[{"muted":true,"volume":[{"beat":4,"value":-6}],"gestures":[]},{"solo":true},{"color":"FF0000"}]}
    """
    let first = try? MixDocument.load(from: Data(v1.utf8))
    check(first?.clips.first?.automation.isEmpty == true, "a v1 mix opens with no automation")
    check(first?.lanes.map(\.muted) == [true, false, false] && first?.lanes[1].solo == true && first?.lanes[2].color == "FF0000",
          "and its lanes' switches and colours")
    check((try? MixDocument.load(from: Data(#"{"format":"ultramix-mix","version":4}"#.utf8))) == nil, "format 4 is refused")

    // A mix written before the bookmark was dropped: the key is passed over
    // rather than refused, so no format bump was needed for it.
    let withBookmark = """
    {"format":"ultramix-mix","version":3,
     "tracks":[{"id":"\(trackA.uuidString)","path":"/Music/a.mp3","bookmark":"AQID"}]}
    """
    let older = try? MixDocument.load(from: Data(withBookmark.utf8))
    check(older?.tracks.count == 1 && older?.tracks.first?.path == "/Music/a.mp3",
          "a mix that still carries a bookmark opens, and the key is passed over")

    // A v2 mix with the old bipolar filter: it opens, volume, pan and the
    // other gestures stay, the filter - nodes and gesture - is gone. No
    // migration.
    let v2 = """
    {"format":"ultramix-mix","version":2,
     "clips":[{"id":"\(UUID().uuidString)","trackID":"\(trackA.uuidString)","anchorBeat":8,
       "automation":{"volume":[{"beat":4,"value":-6}],"pan":[{"beat":2,"value":0.5}],
                     "filter":[{"beat":4,"value":-0.5}],
                     "gestures":[{"id":"\(UUID().uuidString)","kind":"filter","start":4,"end":8,"shape":"sine","period":1,"low":-1,"high":1},
                                 {"id":"\(UUID().uuidString)","kind":"pan","start":10,"end":12,"shape":"step","period":1,"low":-1,"high":1}]}}]}
    """
    let second = try? MixDocument.load(from: Data(v2.utf8))
    let kept = second?.clips.first?.automation
    check(kept?.volume == [AutomationNode(beat: 4, value: -6)] && kept?.pan == [AutomationNode(beat: 2, value: 0.5)],
          "a v2 mix opens with its volume and pan")
    check(kept?.lowPass.isEmpty == true && kept?.highPass.isEmpty == true && kept?.gestures.map(\.kind) == [.pan],
          "and without its old filter: \(String(describing: kept?.gestures.map(\.kind)))")

    let old = """
    {"clips":[{"id":"\(UUID().uuidString)","trackID":"\(trackA.uuidString)","anchorBeat":8}],"lanes":[{}]}
    """
    let legacy = try? MixDocument.load(from: Data(old.utf8))
    check(legacy?.clips.first?.tempoAnchorBeat == 8, "missing keys fall back to defaults")
    check(legacy?.lanes.count == 3, "always three lanes")
    check(legacy?.lanes.allSatisfy { $0.color == nil } == true, "an old mix has the lanes' own colours")
    let odd = ##"{"lanes":[{"color":"zz"},{"color":"#fa9933"}]}"##
    let oddColors = (try? MixDocument.load(from: Data(odd.utf8)))?.lanes.map(\.color)
    check(oddColors == [nil, "FA9933", nil], "a colour that is not one falls back, a sloppy one is tidied: \(String(describing: oddColors))")
    check(!(String(data: try! MixDocument().fileData(), encoding: .utf8)!).contains("color"),
          "a mix with no chosen colour does not write the key")
    let future = #"{"format":"ultramix-mix","version":99}"#
    check((try? MixDocument.load(from: Data(future.utf8))) == nil, "a newer format is refused")
}

section("lane colour: hex, defaults, contrast") {
    check(HexColor.normalized("#12ab34") == "12AB34", "a sloppy hex is tidied")
    check(HexColor.normalized("12345") == nil && HexColor.normalized("GGGGGG") == nil && HexColor.normalized("+12345") == nil,
          "five digits, a letter past F, a sign: not colours")

    var doc = MixDocument()
    doc.setLaneColor(1, "FF0000")
    check(doc.lanes[1].color == "FF0000", "a chosen colour is stored")
    doc.setLaneColor(1, "#dd7100")
    check(doc.lanes[1].color == nil, "the lane's own colour is stored as none")
    doc.setLaneColor(0, "123456")
    doc.setLaneColor(0, nil)
    check(doc.lanes[0].color == nil, "nil goes back to the lane's own")
    doc.setLaneColor(7, "FF0000")
    check(doc.lanes.map(\.color) == [nil, nil, nil], "a lane that does not exist changes nothing")

    check(HexColor.contrastRatio("000000", "FFFFFF").map { near($0, 21, 0.001) } == true, "black on white is 21:1")
    // The timeline's background, NSColor.windowBackgroundColor, in Aqua
    // and Dark Aqua.
    let light = "FFFFFF", dark = "1E1E1E"
    for (lane, hex) in LaneSettings.defaultColors.enumerated() {
        let onDark = HexColor.contrastRatio(hex, dark)!
        let onLight = HexColor.contrastRatio(hex, light)!
        print("     lane \(lane) \(hex): " + String(format: "%.2f:1 on dark, %.2f:1 on light", onDark, onLight))
        check(onDark >= 3, "lane \(lane)'s own colour is readable on dark: \(onDark)")
        check(onLight >= 3, "lane \(lane)'s own colour is readable on light: \(onLight)")
    }
    // The old orange, FA9933, measured 2.17:1 on white - why it was replaced.
    check(HexColor.contrastRatio("FA9933", light)! < 3, "the old orange really was too faint")
}

section("library file: what is saved is what loads") {
    var track = Track(path: "/Music/a.mp3", bookmark: Data([9, 8]), title: "A", artist: "Someone",
                      durationSeconds: 312.5, addedAt: Date(timeIntervalSince1970: 1_757_600_000))
    track.state = .done
    track.analysis = TrackAnalysis(bpm: 124.5, firstBeatSeconds: 0.731, confidence: 0.8, version: 1)
    track.setCorrection(bpm: 125, firstBeatSeconds: 0.5)
    let restored = try? Track.decodeLibrary(Track.encodeLibrary([track]))
    check(restored == [track], "a saved library reads back unchanged")
}

section("beatgrid correction: confirming what is already set is not a change") {
    // The case that rewrote a library for nothing: Return in the beatgrid
    // editor's untouched tempo field, on a track analysed at 119.999 and
    // corrected to 120. The library saves only when this returns true.
    var track = Track(path: "Audio/b.mp3", bookmark: nil, title: "B", artist: nil,
                      durationSeconds: 300, addedAt: Date(timeIntervalSince1970: 1_757_600_000))
    track.state = .done
    track.analysis = TrackAnalysis(bpm: 119.999, firstBeatSeconds: 0.3668, confidence: 0.9, version: 1)
    check(!track.setCorrection(bpm: 119.999, firstBeatSeconds: 0.3668) && track.manualBPM == nil,
          "the analysis confirmed as it is: no correction, no change")
    check(track.setCorrection(bpm: 120, firstBeatSeconds: 0.3668) && track.manualBPM == 120, "120 is a correction, and a change")
    check(!track.setCorrection(bpm: 120, firstBeatSeconds: 0.3668), "120 confirmed again: no change")
    check(!track.setCorrection(bpm: 120.0004, firstBeatSeconds: 0.3668), "a value that rounds to the same 120.000: no change")
    check(!track.setCorrection(bpm: track.bpm, firstBeatSeconds: track.firstBeatSeconds),
          "the editor handing back the track's own values: no change")
    check(track.setCorrection(bpm: 119.999, firstBeatSeconds: 0.3668) && track.manualBPM == nil,
          "back to the analysis clears the correction, and that is a change")
}

section("automation selection: pick by rectangle, delete exactly that") {
    var drawn = ClipAutomation()
    drawn.volume = [AutomationNode(beat: 4, value: -6), AutomationNode(beat: 8, value: Automation.silenceDB),
                    AutomationNode(beat: 20, value: 0)]
    drawn.pan = [AutomationNode(beat: 6, value: 0.5)]
    let gate = AutomationGesture(kind: .volume, start: 9, end: 12, shape: .step, period: 1, low: -20, high: 0)
    let sweep = AutomationGesture(kind: .pan, start: 5, end: 7, shape: .sine, period: 1, low: -1, high: 1)
    drawn.gestures = [gate, sweep]
    let picked = drawn.selection(kind: .volume, beats: 3...10, values: Automation.silenceDB...(-3))
    check(picked.nodes == [drawn.volume[0], drawn.volume[1]], "the two enclosed volume nodes, silence included: \(picked.nodes)")
    check(picked.gestures == [gate.id], "the volume gesture overlapping the range, not the pan one")
    check(drawn.selection(kind: .volume, beats: 3...10, values: -5...12).nodes.isEmpty, "a rectangle above the nodes picks none")

    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let b = try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 0, grids: grids)
    doc.clips[0].automation = drawn
    doc.clips[1].automation.volume = [AutomationNode(beat: 5, value: -10)]
    var selection = AutomationSelection(kind: .volume)
    selection.nodes[a] = picked.nodes
    selection.gestures[a] = picked.gestures
    selection.nodes[b] = doc.clips[1].automation.volume
    doc.deleteAutomation(selection)
    check(doc.clips[0].automation.volume == [AutomationNode(beat: 20, value: 0)],
          "only the unselected node stays: \(doc.clips[0].automation.volume)")
    check(doc.clips[0].automation.gestures.map(\.id) == [sweep.id], "the pan gesture stays")
    check(doc.clips[0].automation.pan == drawn.pan, "other kinds are untouched")
    check(doc.clips[1].automation.volume.isEmpty, "across clips")

    // A crossfade, selected over its range plus the guard margin, goes completely.
    var mix = MixDocument()
    try! mix.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! mix.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
    try! mix.autoCrossfade(nil, grids: grids)
    let transition = mix.transitions(grids)[0]
    var fade = AutomationSelection(kind: .volume)
    for clip in mix.clips {
        let anchor = Double(clip.anchorBeat)
        fade.nodes[clip.id] = clip.automation.selection(
            kind: .volume, beats: (transition.start - anchor - 0.1)...(transition.end - anchor + 0.1),
            values: Automation.silenceDB...Automation.maxVolumeDB).nodes
    }
    mix.deleteAutomation(fade)
    check(mix.clips.allSatisfy { $0.automation.volume.isEmpty },
          "crossfade gone: \(mix.clips.map(\.automation.volume.count)) nodes left")
    check(LanePlan(document: mix, lane: 0, grids: grids).volume.value(at: transition.start) == Automation.defaultVolumeDB,
          "the clip is back at its resting level")
}

section("audio files: what counts as a song, and what a folder holds") {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("ultramix-walk-\(UUID().uuidString)")
    let inner = root.appendingPathComponent("Album 2")
    try! files.createDirectory(at: inner, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    for name in ["02 Second.mp3", "10 Tenth.M4A", "01 First.wav", "cover.jpg", "notes.txt", ".hidden.mp3"] {
        files.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
    }
    for name in ["a.flac", "b.aiff", "c.pdf"] {
        files.createFile(atPath: inner.appendingPathComponent(name).path, contents: Data("x".utf8))
    }

    let found = AudioFiles.at(root).map(\.lastPathComponent)
    check(found == ["01 First.wav", "02 Second.mp3", "10 Tenth.M4A", "a.flac", "b.aiff"],
          "songs only, folders walked, numbers in human order: \(found)")
    check(!found.contains(".hidden.mp3"), "hidden files are left alone")
    check(AudioFiles.isAudio(root.appendingPathComponent("x.MP3")), "the extension is matched whatever its case")
    check(!AudioFiles.isAudio(root.appendingPathComponent("cover.jpg")), "a picture is not a song")

    // A single file is itself; a single file that is not audio is nothing.
    check(AudioFiles.at(root.appendingPathComponent("02 Second.mp3")).count == 1, "one file is itself")
    check(AudioFiles.at(root.appendingPathComponent("notes.txt")).isEmpty, "a text file is nothing")
    check(AudioFiles.at(root.appendingPathComponent("nowhere.mp3")).isEmpty, "a missing file is nothing")
}

section("workspace: structure, relative paths, unique names") {
    let files = FileManager.default
    let base = files.temporaryDirectory.appendingPathComponent("ultramix-ws-\(UUID().uuidString)")
    defer { try? files.removeItem(at: base) }
    let workspace = try! Workspace.prepare(at: base)
    for folder in [workspace.audio, workspace.mixes, workspace.bounces, workspace.cache] {
        var isDirectory: ObjCBool = false
        check(files.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue,
              "\(folder.lastPathComponent)/ created")
    }
    let song = workspace.audio.appendingPathComponent("Song.mp3")
    try! Data([1, 2, 3]).write(to: song)
    _ = try! Workspace.prepare(at: base)
    check((try? Data(contentsOf: song)) == Data([1, 2, 3]), "preparing again leaves existing files alone")

    let stored = workspace.storedPath(for: song)
    check(stored == "Audio/Song.mp3", "stored relative: \(stored)")
    let elsewhere = Workspace(root: URL(fileURLWithPath: "/Volumes/Other Drive/Mixing"))
    check(elsewhere.url(forStoredPath: stored).path == "/Volumes/Other Drive/Mixing/Audio/Song.mp3",
          "a relative path follows the drive to another mount point")
    check(workspace.storedPath(for: URL(fileURLWithPath: "/Music/x.mp3")) == "/Music/x.mp3", "a file outside stays absolute")
    check(workspace.url(forStoredPath: "/Music/x.mp3").path == "/Music/x.mp3", "and an absolute path is used as it is")

    // A mix is a document anyone may have written, and its track paths are
    // resolved against the working directory.
    check(workspace.isStorable("Audio/Song.mp3"), "a path inside the working directory is storable")
    check(workspace.isStorable("/Music/x.mp3"), "and so is an absolute one")
    check(!workspace.isStorable("../../../etc/hosts"), "a path that climbs out is not")
    check(!workspace.isStorable("Audio/../../../../etc/hosts"), "nor one that climbs out half way")
    check(!workspace.isStorable(""), "nor an empty one")
    check(workspace.isStorable("Audio/../Mixes/a.ultramix"), "but one that stays inside is")

    check(Workspace.uniqueDestination(for: "Song.mp3", in: workspace.audio).lastPathComponent == "Song 2.mp3",
          "an existing name gets a number")
    let planned: Set<String> = ["Song.mp3", "Song 2.mp3"]
    let third = Workspace.uniqueDestination(for: "Song.mp3", in: workspace.audio) { planned.contains($0.lastPathComponent) }
    check(third.lastPathComponent == "Song 3.mp3", "names planned but not yet on disk count as taken: \(third.lastPathComponent)")

    // A mix saved in one working directory opens under another root: its
    // track references are relative.
    var mix = MixDocument()
    mix.tracks = [TrackReference(id: trackA, path: stored)]
    let reopened = try! MixDocument.load(from: try! mix.fileData())
    check(elsewhere.url(forStoredPath: reopened.tracks[0].path).path.hasPrefix("/Volumes/Other Drive/Mixing/Audio/"),
          "a mix's track references resolve in the other working directory")
}

section("safe write: beside the destination, old version kept until the swap") {
    let files = FileManager.default
    let folder = files.temporaryDirectory.appendingPathComponent("ultramix-safewrite-\(UUID().uuidString)")
    try! files.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: folder) }
    let target = folder.appendingPathComponent("mix.ultramix")
    try! Data("old".utf8).write(to: target)
    var tempFolder: URL?
    try? SafeWrite.replace(target) { temporary in
        tempFolder = temporary.deletingLastPathComponent()
        try Data("half".utf8).write(to: temporary)
        throw EditError("interrupted")
    }
    check((try? String(contentsOf: target, encoding: .utf8)) == "old", "a failed write leaves the old version")
    check(tempFolder?.standardizedFileURL == folder.standardizedFileURL, "the temporary file went beside the destination")
    try! SafeWrite.replace(target) { try Data("new".utf8).write(to: $0) }
    check((try? String(contentsOf: target, encoding: .utf8)) == "new", "a finished write replaces it")
    check((try? files.contentsOfDirectory(atPath: folder.path))?.count == 1, "no temporary file left behind")
}

section("automation: a reset puts one node back at rest") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 1, startBeat: 0, grids: grids)
    let node = AutomationNode(beat: 8, value: -18, tension: 0.3)
    let other = AutomationNode(beat: 12, value: 3)
    doc.clips[0].automation.volume = [node, other]
    doc.clips[0].automation.lowPass = [AutomationNode(beat: 8, value: 0.3), AutomationNode(beat: 16, value: 0.6)]
    doc.clips[0].automation.highPass = [AutomationNode(beat: 8, value: 0.7)]
    doc.clips[0].automation.pan = [AutomationNode(beat: 4, value: -0.9)]
    doc.resetAutomationNode(node, kind: .volume, clip: a)
    check(doc.clips[0].automation.volume == [AutomationNode(beat: 8, value: Automation.defaultVolumeDB, tension: 0.3), other],
          "volume back to −4 dB, position and bend kept, the other node untouched: \(doc.clips[0].automation.volume)")
    doc.resetAutomationNode(doc.clips[0].automation.lowPass[0], kind: .lowPass, clip: a)
    check(doc.clips[0].automation.lowPass.map(\.value) == [1, 0.6], "low-pass back to open: \(doc.clips[0].automation.lowPass.map(\.value))")
    doc.resetAutomationNode(doc.clips[0].automation.highPass[0], kind: .highPass, clip: a)
    check(doc.clips[0].automation.highPass.map(\.value) == [0], "high-pass back to off")
    doc.resetAutomationNode(doc.clips[0].automation.pan[0], kind: .pan, clip: a)
    check(doc.clips[0].automation.pan[0].value == 0, "pan back to centre")
    let before = doc
    doc.resetAutomationNode(AutomationNode(beat: 99, value: 1), kind: .volume, clip: a)
    check(doc == before, "a node that is not there changes nothing")
}

section("cache sweep: only what no track owns, nothing it did not write") {
    let kept = UUID()
    let gone = UUID()
    let names = [
        "\(kept.uuidString).f32", "\(kept.uuidString).wave",
        "\(gone.uuidString).f32", "\(gone.uuidString).wave",
        ".\(kept.uuidString).f32.\(UUID().uuidString).partial",
        "notes.txt", "Other.f32", "\(gone.uuidString).mp3",
        "\(kept.uuidString).loud", "\(gone.uuidString).loud",
    ]
    let orphans = Set(CacheSweep.orphans(among: names, keeping: [kept]))
    check(orphans == Set([names[2], names[3], names[4], names[9]]), "orphans \(orphans.sorted())")
    check(CacheSweep.orphans(among: names, keeping: [kept, gone]) == [names[4]], "with both tracks, only the leftover .partial goes")
}

section("undo history") {
    var history = UndoHistory<Int>(limit: 3)
    for state in 1...5 { history.record(state) }
    var current = 6
    var seen: [Int] = []
    while let previous = history.undo(from: current) { seen.append(previous); current = previous }
    check(seen == [5, 4, 3], "the limit drops the oldest: \(seen)")
    check(history.redo(from: current) == 4, "redo walks back")
    history.record(99)
    check(!history.canRedo, "a new edit discards redo")
}

// MARK: - Analysis fixtures

/// A dance-music bar pattern at a known tempo and downbeat: an intro of
/// offbeat hats, then from `downbeat` a kick on every beat, hats on the
/// offbeats, and a bass note that changes on every bar's one.
func synthesizeTrack(bpm: Double, downbeat: Double, bars: Int, seed: UInt64) -> AudioFrames {
    let sr = AudioFrames.sampleRate
    let beat = 60 / bpm
    let total = Int((downbeat + Double(bars * 4) * beat + 2) * sr)
    var mono = [Float](repeating: 0, count: total)
    var random = seed
    func noise() -> Float {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: random >> 11) % 2_000_000) / 1_000_000 - 1
    }
    func add(_ start: Double, _ length: Double, _ sample: (Double) -> Float) {
        let a = Int((start * sr).rounded())
        guard a >= 0 else { return }
        for i in 0..<Int(length * sr) where a + i < total {
            mono[a + i] += sample(Double(i) / sr)
        }
    }
    // Hats from the first offbeat of the file.
    var t = downbeat.truncatingRemainder(dividingBy: beat) + beat / 2
    while t < downbeat { add(t, 0.04) { _ in 0.08 * noise() }; t += beat }
    let notes: [Double] = [55, 65.41, 49, 73.42]
    for b in 0..<(bars * 4) {
        let start = downbeat + Double(b) * beat
        // Kick: a pitch sweep from 150 to 50 Hz with an instant attack.
        add(start, 0.25) { x in
            let phase = 2 * Double.pi * (50 * x + 100 * 0.03 * (1 - exp(-x / 0.03)))
            return Float(0.8 * exp(-x / 0.12) * sin(phase))
        }
        add(start + beat / 2, 0.04) { x in Float(0.1 * exp(-x / 0.01)) * noise() }
        if b % 4 == 0 {
            let f = notes[(b / 4) % notes.count]
            add(start + 0.01, beat * 4 - 0.02) { x in Float(0.25 * sin(2 * .pi * f * x) * min(1, x / 0.005)) }
        }
    }
    var stereo = [Float](repeating: 0, count: total * 2)
    for i in 0..<total { stereo[2 * i] = mono[i]; stereo[2 * i + 1] = mono[i] }
    return AudioFrames(interleaved: stereo)
}

section("tempo analyser: synthetic tracks") {
    let cases: [(bpm: Double, downbeat: Double, bars: Int)] = [(124.5, 0.731, 64), (90, 3.217, 48), (174, 5.05, 96)]
    for (index, fixture) in cases.enumerated() {
        let audio = synthesizeTrack(bpm: fixture.bpm, downbeat: fixture.downbeat, bars: fixture.bars, seed: UInt64(index + 1))
        let started = Date()
        guard let result = try? TempoAnalyzer.analyze(audio) else {
            check(false, "\(fixture.bpm) BPM: no result")
            continue
        }
        let elapsed = Date().timeIntervalSince(started)
        let beat = 60 / fixture.bpm
        // Distance to the true downbeat, and to the nearest true beat - the
        // difference tells a timing error from a wrong bar phase.
        let error = result.firstBeatSeconds - fixture.downbeat
        let beatError = error - (error / beat).rounded() * beat
        print(String(format: "     %.1f BPM → %.3f, downbeat %+.2f ms (nearest beat %+.2f ms), confidence %.2f, %.2f s",
                     fixture.bpm, result.bpm, error * 1000, beatError * 1000, result.confidence, elapsed))
        // At 174 the fixture - a kick on every beat, hats between - is the
        // same signal as a kick on every eighth at 87, and version 2 reads
        // it as 87. Version 1's octave rule halved or doubled eight real
        // tracks it had right, so the octave is left to the tempo
        // preference and ½× in the beatgrid editor. What must hold either
        // way is the grid: every line on a kick. A bar of 87 is two bars of
        // 174, so its downbeat can be either one.
        let halved = fixture.bpm > 160 && abs(result.bpm - fixture.bpm / 2) <= 0.01
        check(abs(result.bpm - fixture.bpm) <= 0.01 || halved, "\(fixture.bpm): got \(result.bpm) BPM")
        check(abs(beatError) <= 0.002, "\(fixture.bpm): beat timing off by \(beatError * 1000) ms")
        let barError = halved ? error - (error / (8 * beat)).rounded() * 8 * beat : error
        check(abs(barError) <= 0.002 || (halved && abs(abs(barError) - 4 * beat) <= 0.002),
              "\(fixture.bpm): downbeat off by \(error * 1000) ms")
    }
}

/// Onset strength with a hit every beat and a weaker one halfway, sharp to
/// the frame - the shape whose peaks fall between whole-frame lags.
func pulseFlux(bpm: Double, offbeat: Float, seconds: Double) -> TempoAnalyzer.Flux {
    let frames = Int(seconds * 100)
    var values = [Float](repeating: 0, count: frames)
    let beat = 6000 / bpm
    var k = 0.0
    while k * beat < Double(frames - 1) {
        values[Int((k * beat).rounded())] += 1
        let half = Int(((k + 0.5) * beat).rounded())
        if half < frames { values[half] += offbeat }
        k += 1
    }
    return TempoAnalyzer.Flux(broad: values, low: values, bands: [])
}

section("tempo analyser: the rough period is read between frames") {
    // A 90 BPM beat is 66.7 frames. Scored at whole-frame lags, version 1
    // answered 89.72 here, and 120 with a strong offbeat.
    for offbeat: Float in [0.3, 0.6, 0.9] {
        guard let period = try? TempoAnalyzer.roughPeriod(pulseFlux(bpm: 90, offbeat: offbeat, seconds: 240), hint: nil) else {
            check(false, "offbeat \(offbeat): no period"); continue
        }
        check(abs(60 / period - 90) <= 0.15, "offbeat \(offbeat): rough tempo \(60 / period)")
    }
}

section("tempo analyser: the phase follows the kicks, not the mean of everything") {
    // Kicks, and a lighter onset a third of a beat after each: the mean
    // phase lies 36 ms beside the kicks, which cost a harness track its fit.
    let period = 60.0 / 96, phase = 0.05
    var events: [TempoAnalyzer.Event] = []
    for k in 0..<200 {
        events.append(.init(time: phase + Double(k) * period, weight: 0.55))
        events.append(.init(time: phase + (Double(k) + 0.35) * period, weight: 0.2))
    }
    let found = TempoAnalyzer.densestPhase(events, period: period)
    check(abs(found - phase) <= 0.001, "phase \(found * 1000) ms, kicks at 50 ms")
    let audio = synthesizeTrack(bpm: 96, downbeat: 1.3, bars: 48, seed: 3)
    if let result = try? TempoAnalyzer.analyze(audio) {
        let beat = 60 / 96.0
        let error = result.firstBeatSeconds - 1.3
        check(result.bpm == 96, "96 BPM fixture: \(result.bpm)")
        check(abs(error - (error / beat).rounded() * beat) <= 0.002, "96 BPM fixture: beat off by \(error * 1000) ms")
    } else {
        check(false, "96 BPM fixture: no result")
    }
}

section("tempo analyser: round tempos") {
    // Deterministic jitter of up to ±3 ms, as real onsets have.
    func events(bpm: Double, beats: Int, jitter: Double) -> [TempoAnalyzer.Event] {
        (0..<beats).map { k in
            let wobble = jitter * sin(Double(k) * 2.399) * cos(Double(k) * 0.713)
            return .init(time: 0.4 + Double(k) * 60 / bpm + wobble, weight: 1)
        }
    }
    func analysed(_ events: [TempoAnalyzer.Event]) -> (fitted: Double, rounded: Double) {
        let grid = TempoAnalyzer.bestFit(events, near: events[1].time - events[0].time)
        return (60 / grid.period, 60 / TempoAnalyzer.roundedTempo(events, grid).period)
    }
    // Fitted a hair beside 127 - the ends 2 ms off it: taken to 127.
    let clocked = analysed(events(bpm: 127.003, beats: 400, jitter: 0.003))
    print(String(format: "     127.003 with jitter: fitted %.4f, rounded %.4f", clocked.fitted, clocked.rounded))
    check(abs(clocked.fitted - 127) > 0.002, "the fit already landed on 127, so this checks nothing")
    check(abs(clocked.rounded - 127) < 1e-9, "127.003 with jitter came out \(clocked.rounded)")
    // 126.95 over 384 beats pulls the ends 36 ms apart: kept.
    let odd = analysed(events(bpm: 126.95, beats: 384, jitter: 0.003))
    check(abs(odd.rounded - odd.fitted) < 1e-9 && abs(odd.fitted - 126.95) < 0.005,
          "126.95 came out \(odd.rounded) (fitted \(odd.fitted))")
    // 127.02 without jitter is within the drift limit over 128 beats, but
    // fits measurably worse at 127: kept.
    let exact = analysed(events(bpm: 127.02, beats: 128, jitter: 0))
    check(abs(exact.rounded - 127.02) < 0.001, "127.02 came out \(exact.rounded)")
    // 124.5 is not a whole number but a half: taken there, not to 124 or 125.
    let half = analysed(events(bpm: 124.5, beats: 400, jitter: 0.003))
    check(abs(half.rounded - 124.5) < 1e-9, "124.5 came out \(half.rounded)")
}

section("beatgrid editor: ticks on the kicks, not the hats") {
    let bpm = 124.5, downbeat = 0.731
    let audio = synthesizeTrack(bpm: bpm, downbeat: downbeat, bars: 16, seed: 7)
    let onsets = TempoAnalyzer.kicks(audio, bpm: bpm)
    var errors: [Double] = []
    for b in 0..<(16 * 4) {
        let kick = downbeat + Double(b) * 60 / bpm
        if let nearest = onsets.min(by: { abs($0 - kick) < abs($1 - kick) }) { errors.append(nearest - kick) }
    }
    // Measured when this was written: 56 of 64 within 3 ms, the rest +5 to
    // +6 ms where the bass note changes (the analyser's documented bass
    // interference, under a pixel at 8 s across) and one retimed +72 ms.
    // Before the rise filter the offbeat hats were ticked too: 114 onsets.
    let within = errors.filter { abs($0) <= 0.007 }.count
    print(String(format: "     %d ticks, %d of 64 kicks within 7 ms, worst %+.2f ms",
                 onsets.count, within, (errors.map(abs).max() ?? 0) * 1000))
    check(within >= 63, "only \(within) of 64 kicks have a tick within 7 ms")
    check(onsets.count <= 64 + 4, "\(onsets.count) ticks for 64 kicks - hats getting through")
}

section("grid fit: a tempo change part way through is found, a breakdown is not") {
    // Kicks on every beat at 120 BPM for 3 minutes, then at 120.4 for 2
    // more, judged against the 120 grid: the kicks run away from it by
    // 0.4 / 120 of a beat per beat, 25 ms after about 15 s.
    let beat = 0.5
    var kicks = (0..<360).map { 0.25 + Double($0) * beat }
    let change = kicks.last! + beat
    kicks += (0..<240).map { change + Double($0) * 60 / 120.4 }
    let drifting = GridFit.summary(kicks: kicks, bpm: 120, firstBeat: 0.25, duration: 300)
    if let drift = drifting.drift {
        print(String(format: "     tempo change at %.0f s: drift from %.0f s (%+.0f → %+.0f ms), baseline %+.1f ms",
                     change, drift.from, drift.firstOffset * 1000, drift.lastOffset * 1000, (drifting.baseline ?? 0) * 1000))
        check(drift.from >= change - 1 && drift.from <= change + 45, "drift found from \(drift.from) s, change at \(change) s")
        check(drift.lastOffset < drift.firstOffset, "a faster tempo arrives earlier and earlier")
    } else {
        check(false, "the tempo change was not found")
    }
    // The same grid with a minute of silence in the middle: nothing.
    let breakdown = kicks.prefix(360).filter { $0 < 90 || $0 > 150 }
    check(GridFit.summary(kicks: Array(breakdown), bpm: 120, firstBeat: 0.25, duration: 180).drift == nil,
          "a breakdown is not a drift")
    // Every kick 20 ms late: a baseline, not a drift.
    let late = GridFit.summary(kicks: kicks.prefix(360).map { $0 + 0.020 }, bpm: 120, firstBeat: 0.25, duration: 180)
    check(abs((late.baseline ?? 0) - 0.020) < 0.0005, "baseline \(String(describing: late.baseline))")
    check(late.drift == nil, "a late grid is not a drift")
    // Off-beat events among the kicks, one per two bars - more than the
    // 12 % `TempoAnalyzer.kicks` let through on any measured track: the
    // kicks still decide where the grid sits.
    let hats = kicks.prefix(360).map { $0 + beat / 2 }.enumerated().filter { $0.offset % 8 == 0 }.map(\.element)
    let mixed = GridFit.summary(kicks: Array(kicks.prefix(360)) + hats, bpm: 120, firstBeat: 0.25, duration: 180)
    check(mixed.baseline.map { abs($0) < 0.001 } ?? false, "hats moved the baseline to \(String(describing: mixed.baseline))")
    // A bass that passes the kick test a quarter beat after two kicks in
    // three: the vector mean put such grids 10-30 ms off and offered to
    // "align" them. The kicks are on the lines; nothing is offered.
    let onLines = Array(kicks.prefix(360))
    let bass = onLines.enumerated().filter { $0.offset % 3 != 0 }.map { $0.element + beat / 4 }
    let syncopated = GridFit.summary(kicks: onLines + bass, bpm: 120, firstBeat: 0.25, duration: 180)
    check(syncopated.baseline.map { abs($0) < 0.001 } ?? false, "a syncopated bass moved the baseline to \(String(describing: syncopated.baseline))")
    check(syncopated.alignment == nil && syncopated.drift == nil, "nothing to align on a right grid")
    // The same kicks against a grid half a beat off: aligning is offered,
    // by half a beat. And the kicks 20 ms after every line: offered too -
    // after the move every kick is on a line, before it none was.
    let offBeat = GridFit.summary(kicks: onLines, bpm: 120, firstBeat: 0.25 + beat / 2, duration: 180)
    check(offBeat.alignment.map { abs(abs($0) - beat / 2) < 0.001 } ?? false, "alignment \(String(describing: offBeat.alignment))")
    check(late.alignment.map { abs($0 - 0.020) < 0.0005 } ?? false, "a grid 20 ms early is offered its 20 ms: \(String(describing: late.alignment))")
}

section("key: names and the Camelot wheel") {
    let c = MusicalKey(tonic: 0, minor: false), am = MusicalKey(tonic: 9, minor: true)
    check(c.camelot == "8B" && am.camelot == "8A" && c.name == "C" && am.name == "Am", "\(c.camelot) \(am.camelot)")
    // A fifth up is one step round the wheel.
    for tonic in 0..<12 {
        for minor in [false, true] {
            let key = MusicalKey(tonic: tonic, minor: minor)
            let fifth = MusicalKey(tonic: (tonic + 7) % 12, minor: minor)
            check(fifth.camelotNumber == key.camelotNumber % 12 + 1, "\(key.name) → \(fifth.name)")
            if minor {
                // The relative major shares the number.
                check(MusicalKey(tonic: (tonic + 3) % 12, minor: false).camelotNumber == key.camelotNumber, "\(key.name)'s relative")
            }
        }
    }
    check(Set((0..<24).map { MusicalKey(tonic: $0 % 12, minor: $0 >= 12).camelot }).count == 24, "24 distinct codes")
    check(MusicalKey(tonic: 8, minor: true).name == "G♯m" && MusicalKey(tonic: 6, minor: false).camelot == "2B", "G♯m, F♯ = 2B")
}

/// Chords, one a bar, each a triad of decaying harmonic tones over its
/// root in the bass, over a kick - a key the analysis has to find.
func synthesizeChords(_ chords: [(root: Int, minor: Bool)], bars: Int, bpm: Double = 124) -> AudioFrames {
    let sr = AudioFrames.sampleRate
    let bar = 240 / bpm
    let total = Int(Double(bars) * bar * sr)
    var mono = [Float](repeating: 0, count: total)
    func tone(_ midi: Int, from start: Double, length: Double, gain: Double) {
        let f = 440 * pow(2, Double(midi - 69) / 12)
        let a = Int(start * sr)
        for i in 0..<Int(length * sr) where a + i < total {
            let t = Double(i) / sr
            var v = 0.0
            for h in 1...5 { v += sin(2 * .pi * f * Double(h) * t) / Double(h * h) }
            mono[a + i] += Float(gain * v * exp(-t / 1.5) * min(1, t / 0.01))
        }
    }
    for b in 0..<bars {
        let chord = chords[b % chords.count]
        let start = Double(b) * bar
        let third = chord.minor ? 3 : 4
        for interval in [0, third, 7] { tone(60 + chord.root + interval, from: start, length: bar, gain: 0.08) }
        tone(36 + chord.root, from: start, length: bar, gain: 0.15)
        for beat in 0..<4 {
            let a = Int((start + Double(beat) * bar / 4) * sr)
            for i in 0..<Int(0.2 * sr) where a + i < total {
                let t = Double(i) / sr
                mono[a + i] += Float(0.5 * exp(-t / 0.08) * sin(2 * .pi * (50 * t + 3 * (1 - exp(-t / 0.03)))))
            }
        }
    }
    return AudioFrames(interleaved: mono.flatMap { [$0, $0] })
}

section("key: the analysis finds the key of a chord progression") {
    // Progressions that name their key: I–IV–V–I in C and in F♯, and the
    // descent Am–G–F–E.
    let clear: [(chords: [(root: Int, minor: Bool)], expect: String)] = [
        ([(0, false), (5, false), (7, false), (0, false)], "C"),
        ([(9, true), (7, false), (5, false), (4, false)], "Am"),
        ([(6, false), (11, false), (1, false), (6, false)], "F♯"),
    ]
    for (chords, expect) in clear {
        let found = KeyAnalyzer.analyze(synthesizeChords(chords, bars: 16))
        print("     \(expect): \(found.map { "\($0.key.name) (\($0.key.camelot)), margin \(String(format: "%.3f", $0.margin))" } ?? "none")")
        check(found?.key.name == expect && found?.isUncertain == false,
              "expected \(expect), found \(found?.key.name ?? "none") (\(found?.margin ?? 0))")
    }
    // Progressions the notes alone cannot settle - Am–F–C–G holds exactly
    // the notes of C major; in Am–Dm–E–Am the chord fifths sit where the
    // bass's overtones do - must at least say they are unsure. Measured when
    // written: C at 0.028 and A at 0.024.
    for chords: [(root: Int, minor: Bool)] in [[(9, true), (5, false), (0, false), (7, false)],
                                               [(9, true), (2, true), (4, false), (9, true)]] {
        let found = KeyAnalyzer.analyze(synthesizeChords(chords, bars: 16))
        check(found?.isUncertain == true, "an ambiguous progression read as a sure \(found?.key.name ?? "none")")
    }
    check(KeyAnalyzer.analyze(AudioFrames(interleaved: [Float](repeating: 0, count: 441_000))) == nil, "silence has no key")
    // A profile turned to D minor is D minor, with a clear lead.
    let dMinor = (0..<12).map { KeyAnalyzer.minorProfile[(($0 - 2) % 12 + 12) % 12] }
    let estimate = KeyAnalyzer.estimate(dMinor)
    check(estimate.key == MusicalKey(tonic: 2, minor: true) && !estimate.isUncertain, "\(estimate)")
    // Stored with the track, and absent in older libraries.
    var track = Track(path: "Audio/x.mp3", bookmark: nil, title: "x", artist: nil, durationSeconds: 10)
    track.key = estimate
    let decoded = try! Track.decodeLibrary(try! Track.encodeLibrary([track]))
    check(decoded.first?.key == estimate, "the key survives the library file")
    let old = Data(#"[{"id":"\#(UUID().uuidString)","path":"Audio/y.mp3"}]"#.utf8)
    check((try? Track.decodeLibrary(old))?.first?.key == nil, "an old library has no key and still loads")
}

section("grid fit: an intro beside the grid") {
    // A minute of kicks 60 ms late, then three minutes on a 120 grid; and a
    // minute at 119.8 BPM, whose kicks slide slowly off the same grid. Both
    // intros are reported, up to where the grid fits. (An intro far from the
    // tempo - 118 against 120 - has no steady kick in any window, so the bar
    // shows it grey and no note is made.)
    let beat = 0.5
    let body = 60.25
    let bodyKicks = (0..<360).map { body + Double($0) * beat }
    for (label, intro) in [("60 ms late", (0..<120).map { 0.31 + Double($0) * beat }),
                           ("119.8 BPM", (0..<119).map { body - 0.5 - Double($0) * 60 / 119.8 }.reversed())] {
        let summary = GridFit.summary(kicks: intro + bodyKicks, bpm: 120, firstBeat: 0.25, duration: 240)
        if let found = summary.intro, let to = found.to {
            print(String(format: "     intro %@ until %.0f s: reported %.0f … %.0f s", label, body, found.from, to))
            // The sliding intro meets the grid before the body starts: its
            // last windows are already within 25 ms, and count as fitting.
            check(to >= body - 20 && to <= body + 16 && found.from < 30, "\(label): \(found.from) … \(to)")
        } else {
            check(false, "\(label): the intro was not reported")
        }
        check(summary.drift == nil, "\(label): an intro is not a drift")
    }
    // A grid that fits from the start has no intro to report.
    let steady = GridFit.summary(kicks: (0..<480).map { 0.25 + Double($0) * beat }, bpm: 120, firstBeat: 0.25, duration: 240)
    check(steady.intro == nil, "no intro on a steady track")
    // An intro on the lines and a body 40 ms late, the majority: the intro
    // is not the problem, and is not reported as one.
    let lateBody = (0..<60).map { 0.25 + Double($0) * beat } + (60..<480).map { 0.29 + Double($0) * beat }
    check(GridFit.summary(kicks: lateBody, bpm: 120, firstBeat: 0.25, duration: 240).intro == nil,
          "an intro on the lines was reported")
}

section("beatgrid: the spot of the song under the timeline's playhead") {
    // testGrid: 120 BPM, bar one at 1.0 s, 2 beats of pre-roll, 120 s long.
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)   // anchor 4
    check(doc.sourceSeconds(ofTrack: trackA, atBeat: 4, grids: grids) == 1.0, "the clip's bar one is bar one of the song")
    check(doc.sourceSeconds(ofTrack: trackA, atBeat: 2, grids: grids) == 0, "its first sample is the start of the song")
    check(doc.sourceSeconds(ofTrack: trackA, atBeat: 24, grids: grids) == 11.0, "twenty beats later, ten seconds in")
    check(doc.sourceSeconds(ofTrack: trackA, atBeat: 400, grids: grids) == nil, "past the clip there is no spot")
    check(doc.sourceSeconds(ofTrack: trackB, atBeat: 24, grids: grids) == nil, "and none for a track that is not there")

    // A loop of four beats from 3 s: the playhead in its third round answers
    // a spot in the song, not in the round.
    let draft = ClipDraft.loop(region: LoopRegion(from: 3, to: 5), grid: testGrid, repeats: 8)!
    var looped = MixDocument()
    try! looped.addClip(trackID: trackA, grid: testGrid, lane: 1, startBeat: 100, grids: grids, draft: draft)
    let shape = ClipGeometry(clip: looped.clips[0], grid: testGrid)
    check(shape.bodyStart == 100, "the loop starts on the bar line 100")
    let inThird = looped.sourceSeconds(ofTrack: trackA, atBeat: 109, grids: grids)!
    check(abs(inThird - 3.5) < 1e-9, "a beat into the third round is half a second into the loop: \(inThird)")
    check(doc.clips.count == 1 && a == doc.clips[0].id, "nothing was changed by asking")
}

section("beatgrid strip: which lines are in view, and the window that crashed it") {
    // testGrid: 120 BPM (a line every 0.5 s), bar one at 1.0 s, 120 s long.
    let lines = { (from: Double, to: Double) in
        BeatLines.indices(from: from, to: to, bpm: 120, firstBeat: 1.0, duration: 120)
    }
    check(lines(1.0, 3.0) == 0...4, "five lines in two seconds: \(String(describing: lines(1.0, 3.0)))")
    check(lines(1.1, 2.9) == 1...3, "the ends fall to the lines inside the window")
    // Crash: a view left past the end of the song clamped the two ends
    // apart and built a range that started after it ended.
    check(lines(130, 160) == nil, "a window past the end of the song is no range at all")
    check(lines(-30, -5) == nil, "and one before its start")
    check(lines(5, 5) == nil && lines(9, 3) == nil, "an empty or reversed window")
    check(lines(-10, 3) == -2...4, "a window reaching back before the song starts at the song's own first line - 0.0 s is two lines before bar one")
    check(lines(110, 200) == 218...238, "one reaching past the end stops with the song: \(String(describing: lines(110, 200)))")
    check(BeatLines.indices(from: 0, to: 120, bpm: 120, firstBeat: 1, duration: 120, limit: 100) == nil,
          "more lines than can be told apart are not drawn")
    check(BeatLines.indices(from: 0, to: 10, bpm: 0, firstBeat: 0, duration: 120) != nil, "a tempo of zero is survived")
}

section("beatgrid editor: gridline indices") {
    check(BeatLines.nearestLine(to: 1.0 + 0.24, bpm: 120, firstBeat: 1.0) == 0, "0.24 s after bar one is line 0")
    check(BeatLines.nearestLine(to: 1.0 + 0.26, bpm: 120, firstBeat: 1.0) == 1, "0.26 s after bar one is line 1")
    check(BeatLines.nearestLine(to: 0.1, bpm: 120, firstBeat: 1.0) == -2, "0.1 s is line −2")
    check(BeatLines.time(ofLine: -2, bpm: 120, firstBeat: 1.0) == 0, "line −2 is at 0 s")
}

// MARK: - Decode and waveform

/// Writes a test file and returns when the writer is gone - the file is
/// only complete once the AVAudioFile has been released.
func writeTestFile(_ url: URL, sampleRate: Double, seconds: Double, frequency: Double) {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let file = try! AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
    ])
    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) {
        buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * frequency * Double(i) / sampleRate))
    }
    try! file.write(from: buffer)
}

section("audio cache: 48 kHz mono decodes to 44.1 kHz stereo") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ultramix-verify-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("tone.wav")
    writeTestFile(source, sampleRate: 48_000, seconds: 3, frequency: 1000)
    let cache = directory.appendingPathComponent("tone.f32")
    let frames = (try? AudioCache.decode(source, to: cache)) ?? 0
    check(abs(frames - 132_300) <= 64, "3 s at 44.1 kHz ≈ 132 300 frames, got \(frames)")
    guard let audio = try? AudioFrames(mapping: cache) else { check(false, "cache does not map"); return }
    check(audio.frameCount == frames, "mapped frame count")
    var peak: Float = 0
    var sidesDiffer = false
    for i in 10_000..<120_000 {
        peak = max(peak, abs(audio.samples[2 * i]))
        if audio.samples[2 * i] != audio.samples[2 * i + 1] { sidesDiffer = true }
    }
    check(abs(peak - 0.5) < 0.01, "level survives conversion: peak \(peak)")
    check(!sidesDiffer, "mono lands on both sides identically")
    let garbage = directory.appendingPathComponent("garbage.mp3")
    try! Data(repeating: 0x5A, count: 10_000).write(to: garbage)
    check((try? AudioCache.decode(garbage, to: directory.appendingPathComponent("g.f32"))) == nil, "garbage is refused")
}

section("audio cache: the way round for files the packet reader refuses") {
    // The fallback decoder has to produce exactly what the normal one does:
    // interleaved stereo float at 44.1 kHz, the same length, the same tone.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ultramix-reader-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let wav = directory.appendingPathComponent("tone.wav")
    let seconds = 3.0
    let frames = Int(AudioFrames.sampleRate * seconds)
    do {
        let format = AVAudioFormat(standardFormatWithSampleRate: AudioFrames.sampleRate, channels: 2)!
        let file = try! AVAudioFile(forWriting: wav, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for i in 0..<frames {
                buffer.floatChannelData![channel][i] =
                    Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / AudioFrames.sampleRate))
            }
        }
        try! file.write(from: buffer)
    }

    let normal = directory.appendingPathComponent("normal.f32")
    let viaReader = directory.appendingPathComponent("reader.f32")
    let a = try! AudioCache.decode(wav, to: normal)
    let b = try! AudioCache.convertWithReader(wav, into: viaReader)
    check(abs(a - frames) <= 1, "the usual way decodes \(a) frames of \(frames)")
    check(abs(b - frames) <= 1152, "the way round decodes \(b) frames of \(frames)")

    let one = try! AudioFrames(mapping: normal)
    let two = try! AudioFrames(mapping: viaReader)
    let count = min(one.frameCount, two.frameCount)
    var worst: Float = 0
    for i in stride(from: 0, to: count * 2, by: 97) {
        worst = max(worst, abs(one.samples[i] - two.samples[i]))
    }
    check(worst < 1e-5, "both ways give the same samples: worst difference \(worst)")
    check(two.frameCount > 0 && abs(two.duration - seconds) < 0.03, "and the same length: \(two.duration) s")
}

section("waveform: buckets, normalisation, pyramid") {
    let audio = synthesizeTrack(bpm: 128, downbeat: 0.5, bars: 16, seed: 9)
    let waveform = Waveform(audio: audio)
    let finest = waveform.levels[0]
    // Frames per bucket is rounded up, so the count lands a little under
    // 16 384 - within 1 %.
    check(finest.count <= Waveform.bucketCount && finest.count >= Waveform.bucketCount * 99 / 100,
          "finest level \(finest.count)")
    let peak = max(finest.maxL.max()!, -finest.minL.min()!, finest.maxR.max()!, -finest.minR.min()!)
    check(abs(peak - 1) < 1e-6, "normalised to the largest peak: \(peak)")
    check(waveform.levels.last!.count <= Waveform.coarsestCount, "pyramid reaches \(waveform.levels.last!.count)")
    let second = waveform.levels[1]
    check(second.maxL[3] == max(finest.maxL[6], finest.maxL[7]), "halving keeps the extremes")
    check(waveform.level(forColumns: 900).count >= 900, "level for 900 columns has at least 900 buckets")
    let restored = Waveform(data: waveform.data())
    check(restored?.levels[0] == finest, "storage round-trip")
}

// MARK: - Loudness

/// A 1 kHz sine at `dBFS` peak, interleaved, in either channel or both.
func tone(seconds: Double, dBFS: Double, left: Bool = true, right: Bool = true) -> [Float] {
    let amplitude = pow(10, dBFS / 20)
    let frames = Int(seconds * AudioFrames.sampleRate)
    var samples = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let value = Float(amplitude * sin(2 * Double.pi * 1000 * Double(i) / AudioFrames.sampleRate))
        if left { samples[2 * i] = value }
        if right { samples[2 * i + 1] = value }
    }
    return samples
}

section("library: the file type column") {
    func type(_ path: String) -> String {
        Track(path: path, bookmark: nil, title: "t", artist: nil, durationSeconds: 0).fileType
    }
    check(type("Audio/a.mp3") == "MP3" && type("Audio/b.M4A") == "M4A" && type("Audio/c.flac") == "FLAC",
          "extensions in capitals")
    check(type("Audio/d.wave") == "WAV" && type("Audio/e.wav") == "WAV", "both WAV spellings read WAV")
    check(type("Audio/f.aif") == "AIFF" && type("Audio/g.aiff") == "AIFF", "both AIFF spellings read AIFF")
    check(type("Audio/no extension") == "–", "no extension: a dash")
}

section("loudness: K-weighting gives BS.1770's printed coefficients at 48 kHz") {
    let (shelf, highPass) = KWeighting.coefficients(sampleRate: 48_000)
    let printed = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
    let derived = [shelf.b0, shelf.b1, shelf.b2, shelf.a1, shelf.a2]
    check(zip(printed, derived).allSatisfy { near($0, $1, 1e-8) }, "shelf \(derived)")
    check(highPass.b0 == 1 && highPass.b1 == -2 && highPass.b2 == 1
          && near(highPass.a1, -1.99004745483398, 1e-8) && near(highPass.a2, 0.99007225036621, 1e-8),
          "high-pass \(highPass.a1) \(highPass.a2)")
}

section("loudness: EBU Tech 3341 levels, the gates, storage") {
    // 1 kHz at −23 dBFS in both channels reads −23.0 LUFS.
    let stereo = LoudnessProfile(audio: AudioFrames(interleaved: tone(seconds: 20, dBFS: -23)))
    let both = stereo.integrated(fromSeconds: 0, toSeconds: 20) ?? .nan
    check(near(both, -23, 0.1), "stereo −23 dBFS: \(both) LUFS")
    check(stereo.hops.count == 200, "one hop per 100 ms: \(stereo.hops.count)")
    // One channel carries half the power: −20 dBFS in the left alone reads the same.
    let single = LoudnessProfile(audio: AudioFrames(interleaved: tone(seconds: 20, dBFS: -20, right: false)))
    let one = single.integrated(fromSeconds: 0, toSeconds: 20) ?? .nan
    check(near(one, -23, 0.1), "left only at −20 dBFS: \(one) LUFS")
    // 10 s at −36, 60 s at −23, 10 s at −36: the relative gate drops the quiet parts.
    let gated = LoudnessProfile(audio: AudioFrames(interleaved:
        tone(seconds: 10, dBFS: -36) + tone(seconds: 60, dBFS: -23) + tone(seconds: 10, dBFS: -36)))
    let whole = gated.integrated(fromSeconds: 0, toSeconds: 80) ?? .nan
    check(near(whole, -23, 0.1), "−36 / −23 / −36: \(whole) LUFS")
    let silence = LoudnessProfile(audio: AudioFrames(interleaved: [Float](repeating: 0, count: 882_000)))
    check(silence.integrated(fromSeconds: 0, toSeconds: 10) == nil, "silence is no measurement")
    check(stereo.integrated(fromSeconds: 5, toSeconds: 5.35) == nil, "nor is less than one 400 ms block")
    check(stereo.integrated(fromSeconds: -3, toSeconds: 99).map { near($0, both, 1e-9) } == true,
          "a range reaching past the file is held to it")
    check(gated.songLUFS == whole, "the song's loudness is the whole file's: \(String(describing: gated.songLUFS))")
    check(silence.songLUFS == nil, "a silent song has none")
    check(gated.integrated(fromSeconds: 0, toSeconds: .infinity) == whole, "an open end does not trap")
    check(LoudnessProfile(data: gated.data()) == gated, "storage round-trip")
    check(LoudnessProfile(data: gated.data().dropLast(4)) == nil, "a file cut short is measured again, not trusted")
}

section("loudness: where the music ends") {
    let loud = Float(pow(10, (-20 + 0.691) / 10)), faint = Float(pow(10, (-65 + 0.691) / 10))
    let hiss = Float(pow(10, (-75 + 0.691) / 10))
    let profile = LoudnessProfile(hops: Array(repeating: loud, count: 50) + [faint, faint] + Array(repeating: hiss, count: 30))
    check(abs((profile.soundEndSeconds ?? 0) - 5.2) < 1e-9, "a fade to −65 LUFS still sounds, hiss at −75 does not: \(String(describing: profile.soundEndSeconds))")
    check(LoudnessProfile(hops: Array(repeating: hiss, count: 30)).soundEndSeconds == nil, "all silence: no end")
    // Through the stored form, as the library loads it.
    check(LoudnessProfile(data: profile.data())?.soundEndSeconds == profile.soundEndSeconds, "the end survives storage")
}

section("loudness: a clip measures what it plays, with its gain; Match") {
    // 20 s at −30 dBFS, then 60 s at −23: 120 BPM, bar one on the first sample, 160 beats.
    let track = UUID()
    let grid = SourceGrid(bpm: 120, firstBeatSeconds: 0, durationSeconds: 80)
    let profile = LoudnessProfile(audio: AudioFrames(interleaved: tone(seconds: 20, dBFS: -30) + tone(seconds: 60, dBFS: -23)))
    var clip = Clip(trackID: track, lane: 0, anchorBeat: 8)
    // 197 blocks at −30, 597 at −23, 3 across the step; none under the
    // relative gate at about −34: 10·log10(3.198 / 797) − 0.691 + 0.691.
    let untrimmed = ClipLoudness.lufs(clip, grid: grid, profile: profile) ?? .nan
    check(near(untrimmed, -23.97, 0.1), "the quiet intro pulls it down: \(untrimmed)")
    clip.trimStart = 40
    let trimmed = ClipLoudness.lufs(clip, grid: grid, profile: profile) ?? .nan
    check(near(trimmed, -23, 0.1), "with the intro trimmed away: \(trimmed)")
    clip.gainDB = 3
    let louder = ClipLoudness.lufs(clip, grid: grid, profile: profile) ?? .nan
    check(near(louder - trimmed, 3, 1e-9), "the gain adds 1:1: \(louder - trimmed)")

    // Match, on profiles of steady loudness: a power of 10^((L + 0.691) / 10).
    func steady(_ lufs: Double) -> LoudnessProfile {
        LoudnessProfile(hops: [Float](repeating: Float(pow(10, (lufs + 0.691) / 10)), count: 1200))
    }
    let loud = UUID(), quiet = UUID(), faint = UUID()
    let long = SourceGrid(bpm: 120, firstBeatSeconds: 0, durationSeconds: 120)  // 240 beats
    let lookup: GridLookup = { [loud, quiet, faint].contains($0) ? long : nil }
    let profiles = [loud: steady(-8), quiet: steady(-15), faint: steady(-28)]
    var doc = MixDocument()
    doc.clips = [Clip(trackID: loud, lane: 0, anchorBeat: 0), Clip(trackID: quiet, lane: 1, anchorBeat: 200)]
    let a = doc.clips[0].id, b = doc.clips[1].id
    check(doc.matchReference(for: b, grids: lookup)?.id == a, "B mixes out of A, on the other lane")
    check(doc.matchReference(for: a, grids: lookup) == nil, "nothing plays into A or before it")
    var unchanged = doc
    unchanged.matchGain(a, grids: lookup, loudness: { profiles[$0] })
    check(unchanged == doc, "without a reference nothing changes")
    doc.matchGain(b, grids: lookup, loudness: { profiles[$0] })
    check(doc.clips[1].gainDB == 7, "−15 matched to −8 is +7 dB: \(doc.clips[1].gainDB)")

    // C comes in during B, whose gain now counts; −28 cannot reach −8.
    doc.clips.append(Clip(trackID: faint, lane: 2, anchorBeat: 400))
    let c = doc.clips[2].id
    check(doc.matchReference(for: c, grids: lookup)?.id == b, "C mixes out of B")
    doc.matchGain(c, grids: lookup, loudness: { profiles[$0] })
    check(doc.clips[2].gainDB == 12, "held at +12 dB: \(doc.clips[2].gainDB)")

    // After a gap: the clip that ended last. Muted clips are not heard.
    doc.clips.append(Clip(trackID: loud, lane: 0, anchorBeat: 1000))
    let d = doc.clips[3].id
    check(doc.matchReference(for: d, grids: lookup)?.id == c, "after a gap, the clip that ended last")
    doc.clips[2].muted = true
    check(doc.matchReference(for: d, grids: lookup)?.id == b, "a muted clip is skipped")
}

// MARK: - Engine

/// A one-clip mix of `audio` at `bpm`, optionally played at `playBPM`.
func singleClipPlan(_ audio: AudioFrames, bpm: Double, firstBeat: Double, playBPM: Double? = nil,
                    configure: (inout MixDocument) -> Void = { _ in }) -> (RenderPlan, MixDocument, GridLookup) {
    let track = UUID()
    let grid = SourceGrid(bpm: bpm, firstBeatSeconds: firstBeat, durationSeconds: audio.duration)
    let lookup: GridLookup = { $0 == track ? grid : nil }
    var doc = MixDocument()
    let id = try! doc.addClip(trackID: track, grid: grid, lane: 0, startBeat: 0, grids: lookup)
    if let playBPM {
        doc.projectBPM = playBPM
        doc.setTargetBPM(id, playBPM)
    }
    configure(&doc)
    let plan = RenderPlan(document: doc, grids: lookup, audio: { $0 == track ? audio : nil }, generation: 0)
    return (plan, doc, lookup)
}

func renderStretch(_ plan: RenderPlan, segment index: Int = 0, from: Int, count: Int, memo: Bool = true) -> [Float] {
    let stretcher = Stretcher()
    stretcher.usesMemo = memo
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    var state = StretchMemo()
    var done = 0
    while done < count {
        let n = min(512, count - done)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                stretcher.render(plan.segments[index], tempo: plan.tempo, from: from + done, count: n,
                                 left: l.baseAddress! + done, right: r.baseAddress! + done, memo: &state)
            }
        }
        done += n
    }
    return left
}

let engineTrack = synthesizeTrack(bpm: 124.5, downbeat: 0.731, bars: 40, seed: 5)

section("stretcher: ratio 1 is the source, bit for bit") {
    let (plan, _, _) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731)
    let segment = plan.segments[0]
    let from = segment.startFrame + 5000
    let count = 400_000
    let out = renderStretch(plan, from: from, count: count)
    var mismatches = 0
    for i in 0..<count {
        let source = Int(segment.nominalSourceFrame(atTimelineFrame: from + i, tempo: plan.tempo).rounded())
        if out[i] != engineTrack.samples[2 * source] { mismatches += 1 }
    }
    check(mismatches == 0, "\(mismatches) of \(count) frames differ from the source")
}

section("stretcher: kicks stay on the grid through 124.5 → 128") {
    let (plan, doc, lookup) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731, playBPM: 128)
    let segment = plan.segments[0]
    let count = segment.endFrame - segment.startFrame
    let out = renderStretch(plan, from: segment.startFrame, count: count)
    let kick = TempoAnalyzer.KickEnvelope(out)
    let flux = TempoAnalyzer.spectralFlux(out)
    let events = TempoAnalyzer.onsetEvents(flux: flux, kick: kick, period: 60 / 128)
    let anchor = Double(doc.clips[0].anchorBeat)
    let startSeconds = Double(segment.startFrame) / AudioFrames.sampleRate
    var errors: [Double] = []
    for k in 4..<(40 * 4 - 4) {
        let expected = plan.tempo.seconds(atBeat: anchor + Double(k)) - startSeconds
        guard let event = events.min(by: { abs($0.time - expected) < abs($1.time - expected) }),
              abs(event.time - expected) < 0.05 else { continue }
        errors.append((event.time - expected) * 1000)
    }
    // The analyser's own reading of a clean kick is part of each error; the
    // same reading on the unstretched source is the baseline to subtract.
    let (plain, plainDoc, _) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731)
    let plainOut = renderStretch(plain, from: plain.segments[0].startFrame, count: plain.segments[0].endFrame - plain.segments[0].startFrame)
    let plainEvents = TempoAnalyzer.onsetEvents(flux: TempoAnalyzer.spectralFlux(plainOut),
                                                kick: TempoAnalyzer.KickEnvelope(plainOut), period: 60 / 124.5)
    var baseline: [Double] = []
    let plainStart = Double(plain.segments[0].startFrame) / AudioFrames.sampleRate
    for k in 4..<(40 * 4 - 4) {
        let expected = plain.tempo.seconds(atBeat: Double(plainDoc.clips[0].anchorBeat) + Double(k)) - plainStart
        if let event = plainEvents.min(by: { abs($0.time - expected) < abs($1.time - expected) }),
           abs(event.time - expected) < 0.05 { baseline.append((event.time - expected) * 1000) }
    }
    let mean = errors.reduce(0, +) / Double(max(errors.count, 1))
    let baseMean = baseline.reduce(0, +) / Double(max(baseline.count, 1))
    let rms = (errors.map { ($0 - baseMean) * ($0 - baseMean) }.reduce(0, +) / Double(max(errors.count, 1))).squareRoot()
    let worst = errors.map { abs($0 - baseMean) }.max() ?? .infinity
    print(String(format: "     %d kicks: mean %+.2f ms (unstretched %+.2f), rms %.2f ms, worst %.2f ms",
                 errors.count, mean, baseMean, rms, worst))
    check(errors.count >= 140, "found \(errors.count) kicks")
    check(abs(mean - baseMean) < 1.0, "stretched kicks drift from the grid by \(mean - baseMean) ms on average")
    check(rms < 2.0, "kick timing rms \(rms) ms")
    _ = lookup
}

section("stretcher: the memo is only an accelerator") {
    // A ramp from 124.5 to 131 across the clip: every grain searched.
    let (plan, _, _) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731) { doc in
        let track = doc.clips[0].trackID
        doc.clips.append(Clip(trackID: track, lane: 1, anchorBeat: 160, targetBPM: 131))
    }
    // Start mid-grain, mid-way between restarts: the cold path has to walk.
    let from = plan.segments[0].startFrame + 200_000 + Stretcher.hop / 3
    let count = 300_000
    let warm = renderStretch(plan, from: from, count: count, memo: true)
    let cold = renderStretch(plan, from: from, count: count, memo: false)
    check(warm == cold, "memo changed the output")
}

section("renderer: output does not depend on block size") {
    let (plan, _, _) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731, playBPM: 127) { doc in
        doc.clips[0].automation.volume = [AutomationNode(beat: 8, value: -4), AutomationNode(beat: 24, value: -18)]
        doc.clips[0].automation.gestures = [AutomationGesture(kind: .pan, start: 4, end: 20, shape: .sine, period: 2, low: -0.8, high: 0.8)]
        doc.clips[0].automation.highPass = [AutomationNode(beat: 6, value: 0), AutomationNode(beat: 16, value: 0.7),
                                            AutomationNode(beat: 22, value: 0)]
        doc.clips[0].automation.lowPass = [AutomationNode(beat: 16, value: 1), AutomationNode(beat: 22, value: 0.4)]
    }
    let count = 600_000
    func render(blocks: Int) -> [Float] {
        let renderer = MixRenderer()
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = min(blocks, count - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    renderer.render(plan: plan, laneMask: 0b111, from: done, count: n,
                                    left: l.baseAddress! + done, right: r.baseAddress! + done)
                }
            }
            done += n
        }
        return left + right
    }
    let big = render(blocks: 100_000)
    check(render(blocks: 512) == big, "512-frame blocks differ")
    check(render(blocks: 333) == big, "333-frame blocks differ")
    check(big.contains { $0 != 0 }, "something was rendered")
}

section("output meter: short-term loudness, whatever the block size") {
    let (plan, _, _) = singleClipPlan(AudioFrames(interleaved: tone(seconds: 12, dBFS: -20)), bpm: 120, firstBeat: 0)
    let count = 441_000  // 10 s
    func render(blocks: Int) -> (output: [Float], lufs: Double?) {
        let renderer = MixRenderer()
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = min(blocks, count - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    renderer.render(plan: plan, laneMask: 0b111, from: done, count: n,
                                    left: l.baseAddress! + done, right: r.baseAddress! + done)
                }
            }
            done += n
        }
        var output = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            output[2 * i] = left[i]
            output[2 * i + 1] = right[i]
        }
        return (output, renderer.shortTermLUFS)
    }
    let big = render(blocks: 100_000)
    let small = render(blocks: 333)
    check(big.lufs != nil && big.lufs == small.lufs, "block size changes nothing: \(String(describing: big.lufs)) vs \(String(describing: small.lufs))")
    // The meter reads what the profile measures on the same output, over its last 3 s.
    let measured = LoudnessProfile(audio: AudioFrames(interleaved: big.output)).integrated(fromSeconds: 7, toSeconds: 10) ?? .nan
    check(near(big.lufs ?? .nan, measured, 0.05), "meter \(String(describing: big.lufs)), profile \(measured)")
    print("     −20 dBFS tone through a lane: \(String(format: "%.2f", big.lufs ?? .nan)) LUFS short-term")
    let renderer = MixRenderer()
    renderer.clearMeters()
    check(renderer.shortTermLUFS == nil, "silent before anything played")
}

section("loudness target: every clip at the target, its gain an offset") {
    func steady(_ lufs: Double) -> LoudnessProfile {
        LoudnessProfile(hops: [Float](repeating: Float(pow(10, (lufs + 0.691) / 10)), count: 1200))
    }
    let grid = SourceGrid(bpm: 120, firstBeatSeconds: 0, durationSeconds: 120)
    var clip = Clip(trackID: UUID(), lane: 0, anchorBeat: 0)
    let quiet = steady(-20)
    check(ClipLoudness.effectiveGainDB(clip, grid: grid, profile: quiet, target: -14) == 6, "−20 to −14 is +6 dB")
    check(near(ClipLoudness.lufs(clip, grid: grid, profile: quiet, target: -14) ?? .nan, -14, 0.01), "and it plays at −14")
    clip.gainDB = 2
    check(ClipLoudness.effectiveGainDB(clip, grid: grid, profile: quiet, target: -14) == 8, "the gain is an offset: +8 dB")
    check(ClipLoudness.effectiveGainDB(clip, grid: grid, profile: quiet, target: nil) == 2, "without a target, its own gain")
    check(ClipLoudness.effectiveGainDB(clip, grid: grid, profile: nil, target: -14) == 2, "unmeasured, its own gain")
    clip.gainDB = 0
    let faint = ClipLoudness.effectiveGainDB(clip, grid: grid, profile: steady(-40), target: -14)
    check(faint == 12, "−40 cannot reach −14: held at +12, got \(faint)")
    let tenth = ClipLoudness.effectiveGainDB(clip, grid: grid, profile: steady(-20.04), target: -14)
    check(tenth == 6.0, "to 0.1 dB: \(tenth)")

    let suite = "UltramixHarness.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    check(LoudnessTarget.current(defaults) == nil, "off unless switched on")
    defaults.set(true, forKey: LoudnessTarget.enabledKey)
    check(LoudnessTarget.current(defaults) == -14, "−14 LUFS by default")
    defaults.set(-3.0, forKey: LoudnessTarget.lufsKey)
    check(LoudnessTarget.current(defaults) == -5, "held to the range")
    defaults.removePersistentDomain(forName: suite)

    let (plain, doc, lookup) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731)
    let targeted = RenderPlan(document: doc, grids: lookup, audio: { _ in engineTrack }, generation: 0, gainDB: { _ in 6 })
    check(plain.segments[0].gain == 1, "without a gain closure, the clip's own gain")
    check(targeted.segments[0].gain == Float(Automation.gain(dB: 6)), "the plan plays the gain it is given: \(targeted.segments[0].gain)")
}

section("renderer: limiter ceiling and lane mask") {
    let (plan, _, _) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731) { doc in
        let track = doc.clips[0].trackID
        doc.clips.append(Clip(trackID: track, lane: 1, anchorBeat: doc.clips[0].anchorBeat))
        doc.clips.append(Clip(trackID: track, lane: 2, anchorBeat: doc.clips[0].anchorBeat))
        for i in 0..<3 { doc.clips[i].automation.volume = [AutomationNode(beat: 0, value: 12)] }
    }
    let renderer = MixRenderer()
    let count = 300_000
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            renderer.render(plan: plan, laneMask: 0b111, from: 0, count: count, left: l.baseAddress!, right: r.baseAddress!)
        }
    }
    let peak = max(left.map(abs).max()!, right.map(abs).max()!)
    check(peak <= MixRenderer.ceiling, "peak \(peak) above the ceiling")
    check(peak > 0.9, "the limiter holds it near the ceiling: \(peak)")
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            renderer.render(plan: plan, laneMask: 0, from: 0, count: count, left: l.baseAddress!, right: r.baseAddress!)
        }
    }
    check(!left.contains { $0 != 0 }, "no audible lanes, no sound")
}

section("clip gain: range, input, split, duplicate, file") {
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    doc.setGain(a, -40)
    check(doc.clips[0].gainDB == -24, "held to −24: \(doc.clips[0].gainDB)")
    doc.setGain(a, 20)
    check(doc.clips[0].gainDB == 12, "held to +12: \(doc.clips[0].gainDB)")
    doc.setGain(a, -1.4)
    check(doc.clips[0].gainDB == -1, "rounded to whole dB: \(doc.clips[0].gainDB)")
    doc.setGain(a, -1.6)
    check(doc.clips[0].gainDB == -2, "rounded to whole dB: \(doc.clips[0].gainDB)")

    doc.setGain(a, 0)
    doc.stepGain(a, by: -1)
    check(doc.clips[0].gainDB == -1, "one click down from 0: \(doc.clips[0].gainDB)")
    doc.clips[0].gainDB = -1.5
    doc.stepGain(a, by: 1)
    check(doc.clips[0].gainDB == -1, "a gain between steps lands on whole dB first: \(doc.clips[0].gainDB)")
    doc.setGain(a, -24)
    let atFloor = doc
    doc.stepGain(a, by: -1)
    check(doc == atFloor, "no step below −24, and nothing changed")
    doc.setGain(a, 12)
    let atCeiling = doc
    doc.stepGain(a, by: 1)
    check(doc == atCeiling, "no step above +12, and nothing changed")

    doc.setGain(a, -3)
    let span = doc.geometry(doc.clips[0], grids)!
    let right = try! doc.splitClip(a, at: ((span.bodyStart + span.bodyEnd) / 2).rounded(), grids: grids)
    check(doc.clips.map(\.gainDB) == [-3, -3], "both halves of a split keep it: \(doc.clips.map(\.gainDB))")
    let copy = try! doc.duplicateClip(right, grids: grids)
    check(doc.clips.first { $0.id == copy }?.gainDB == -3, "a duplicate keeps it")

    let restored = try! MixDocument.load(from: try! doc.fileData())
    check(restored == doc, "the gain survives a save")
    var plain = MixDocument()
    try! plain.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    check(!String(data: try! plain.fileData(), encoding: .utf8)!.contains("gainDB"), "a clip at 0 dB writes no gain")
    let old = """
    {"clips":[{"id":"\(UUID().uuidString)","trackID":"\(trackA.uuidString)","anchorBeat":8}]}
    """
    check((try? MixDocument.load(from: Data(old.utf8)))?.clips.first?.gainDB == 0, "a clip from before gain plays at 0 dB")
    let typed = """
    {"clips":[{"id":"\(UUID().uuidString)","trackID":"\(trackA.uuidString)","anchorBeat":8,"gainDB":-1.5},
              {"id":"\(UUID().uuidString)","trackID":"\(trackA.uuidString)","anchorBeat":900,"gainDB":-100}]}
    """
    let loaded = (try? MixDocument.load(from: Data(typed.utf8)))?.clips.map(\.gainDB)
    check(loaded == [-2, -24], "a typed −1.5 loads as −2, an impossible −100 as −24: \(String(describing: loaded))")
}

section("renderer: clip gain scales the clip exactly") {
    // The lane sits at −20 dB so the safety limiter never touches either
    // render: the ratio must come from the gain alone.
    func render(gainDB: Double) -> (rms: Double, peak: Float) {
        let (plan, _, _) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731) { doc in
            doc.clips[0].gainDB = gainDB
            doc.clips[0].automation.volume = [AutomationNode(beat: 0, value: -20)]
        }
        let renderer = MixRenderer()
        let count = 200_000
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(plan: plan, laneMask: 0b111, from: 0, count: count, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        var energy = 0.0
        for i in 0..<count { energy += Double(left[i] * left[i] + right[i] * right[i]) }
        return ((energy / Double(2 * count)).squareRoot(), max(left.map(abs).max()!, right.map(abs).max()!))
    }
    let unity = render(gainDB: 0)
    let quieter = render(gainDB: -6)
    check(unity.rms > 0, "something was rendered")
    check(unity.peak < MixRenderer.ceiling * 0.9, "the limiter stays out of it: peak \(unity.peak)")
    let ratio = quieter.rms / unity.rms
    print("     −6 dB clip gain renders at " + String(format: "%.5f", ratio) + "× (expected " + String(format: "%.5f", pow(10, -6.0 / 20)) + ")")
    check(near(ratio, pow(10, -6.0 / 20), 0.0005), "−6 dB is a factor of 0.501: \(ratio)")
}

// MARK: - Export

section("mastering limiter: ceiling, make-up, latency") {
    var settings = MasteringSettings()
    settings.thresholdDB = -3
    settings.ceilingDB = -0.3
    let ceiling = Float(pow(10, -0.3 / 20))
    // Noise bursts with peaks up to 4, and one single-sample spike of 10.
    var random: UInt64 = 42
    func uniform() -> Float {
        random = random &* 6364136223846793005 &+ 1442695040888963407
        return Float(random >> 40) / Float(1 << 24)
    }
    let count = 200_000
    var left = (0..<count).map { i -> Float in
        let burst: Float = (i / 5000) % 3 == 0 ? 4 : 0.3
        return (uniform() * 2 - 1) * burst
    }
    let right = left.map { -$0 * 0.7 }
    left[123_456] = 10
    let limiter = MasteringLimiter(settings)
    var outLeft = [Float](repeating: 0, count: count + limiter.latency)
    var outRight = [Float](repeating: 0, count: count + limiter.latency)
    var produced = 0
    left.withUnsafeBufferPointer { l in
        right.withUnsafeBufferPointer { r in
            outLeft.withUnsafeMutableBufferPointer { ol in
                outRight.withUnsafeMutableBufferPointer { or in
                    produced = limiter.process(left: l.baseAddress!, right: r.baseAddress!, count: count,
                                               outLeft: ol.baseAddress!, outRight: or.baseAddress!)
                    produced += limiter.flush(outLeft: ol.baseAddress! + produced, outRight: or.baseAddress! + produced)
                }
            }
        }
    }
    check(produced == count, "every frame comes out once: \(produced)")
    let peak = max(outLeft.map(abs).max()!, outRight.map(abs).max()!)
    check(peak <= ceiling, "peak \(peak) above ceiling \(ceiling)")

    // A quiet sine is only raised, by exactly threshold → ceiling (2.7 dB).
    let quiet = (0..<44_100).map { Float(0.1 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
    let second = MasteringLimiter(settings)
    var out = [Float](repeating: 0, count: quiet.count)
    var outR = [Float](repeating: 0, count: quiet.count)
    var impulse = [Float](repeating: 0, count: quiet.count)
    impulse[1000] = 0.2
    quiet.withUnsafeBufferPointer { q in
        out.withUnsafeMutableBufferPointer { o in
            outR.withUnsafeMutableBufferPointer { r in
                _ = second.process(left: q.baseAddress!, right: q.baseAddress!, count: q.count,
                                   outLeft: o.baseAddress!, outRight: r.baseAddress!)
            }
        }
    }
    let raised = out[10_000..<40_000].map(abs).max()!
    check(abs(raised - 0.1 * Float(pow(10, 2.7 / 20))) < 1e-3, "make-up: \(raised)")
    // Latency is swallowed: an impulse comes out at the index it went in.
    let third = MasteringLimiter(settings)
    var aligned = [Float](repeating: 0, count: impulse.count)
    var alignedR = [Float](repeating: 0, count: impulse.count)
    impulse.withUnsafeBufferPointer { i in
        aligned.withUnsafeMutableBufferPointer { o in
            alignedR.withUnsafeMutableBufferPointer { r in
                _ = third.process(left: i.baseAddress!, right: i.baseAddress!, count: i.count,
                                  outLeft: o.baseAddress!, outRight: r.baseAddress!)
            }
        }
    }
    check(aligned.firstIndex { $0 != 0 } == 1000, "impulse lands at 1000: \(aligned.firstIndex { $0 != 0 } ?? -1)")
}

/// Decodes a bounced file (in its own function: the reader must be gone
/// before the caller does anything else with the file).
func readBack(_ url: URL) -> (frames: Int, rate: Double, channels: Int, left: [Float]) {
    guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        return (0, 0, 0, [])
    }
    try? file.read(into: buffer)
    let n = Int(buffer.frameLength)
    return (n, file.fileFormat.sampleRate, Int(file.fileFormat.channelCount),
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n)))
}

section("bounce: WAV matches what plays") {
    let (plan, doc, lookup) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731, playBPM: 126) { doc in
        doc.clips[0].automation.volume = [AutomationNode(beat: 16, value: -4), AutomationNode(beat: 32, value: -12)]
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ultramix-bounce-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("mix.wav")
    var settings = BounceSettings()
    settings.mastering.enabled = false
    do { try Bounce.run(plan: plan, laneMask: 0b111, settings: settings, to: url) } catch {
        check(false, "bounce threw \(error)"); return
    }
    let span = Bounce.range(of: plan)
    let file = readBack(url)
    check(file.frames == span.count, "length \(file.frames) vs \(span.count)")
    check(file.rate == 44_100 && file.channels == 2, "format \(file.rate) Hz, \(file.channels) ch")
    // The same plan, rendered as playback would.
    let reference = RenderPlan(document: doc, grids: lookup, audio: { _ in engineTrack }, generation: 1)
    let renderer = MixRenderer()
    var left = [Float](repeating: 0, count: span.count)
    var scratchRight = [Float](repeating: 0, count: span.count)
    left.withUnsafeMutableBufferPointer { l in
        scratchRight.withUnsafeMutableBufferPointer { r in
            renderer.render(plan: reference, laneMask: 0b111, from: span.lowerBound, count: span.count,
                            left: l.baseAddress!, right: r.baseAddress!)
        }
    }
    var worst: Float = 0
    for i in 0..<min(file.frames, span.count) {
        worst = max(worst, abs(file.left[i] * 32768 / 32767 - left[i]))
    }
    // Rounding (½ LSB) plus dither (up to 1 LSB).
    check(worst <= 1.5 / 32767, "worst difference \(worst * 32767) LSB")
    let missing = (try? Bounce.run(plan: RenderPlan(document: MixDocument(), grids: lookup, audio: { _ in nil }, generation: 2),
                                   laneMask: 0b111, settings: settings, to: directory.appendingPathComponent("empty.wav"))) == nil
    check(missing, "an empty mix refuses to bounce")
    check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("empty.wav").path), "and leaves no file")
}

section("bounce: MP3 at 320 kbps with a LAME tag, the right length") {
    let (plan, _, _) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731, playBPM: 126)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ultramix-mp3-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("mix.mp3")
    var settings = BounceSettings()
    settings.format = .mp3
    settings.mastering.ceilingDB = BounceFormat.mp3.recommendedCeilingDB
    let started = Date()
    do { try Bounce.run(plan: plan, laneMask: 0b111, settings: settings, to: url) } catch {
        check(false, "MP3 bounce threw \(error)"); return
    }
    let elapsed = Date().timeIntervalSince(started)
    let span = Bounce.range(of: plan)
    let seconds = Double(span.count) / AudioFrames.sampleRate
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let kbps = Double(bytes) * 8 / seconds / 1000
    let head = (try? Data(contentsOf: url).prefix(2048)) ?? Data()
    let text = String(decoding: head, as: UTF8.self)
    let file = readBack(url)
    let peak = file.left.map(abs).max() ?? 0
    print(String(format: "     %.1f s mix → %d bytes (%.1f kbps) in %.2f s; decoded %d frames vs %d (%+d); peak %.3f",
                 seconds, bytes, kbps, elapsed, file.frames, span.count, file.frames - span.count, peak))
    check(file.rate == 44_100 && file.channels == 2, "format \(file.rate) Hz, \(file.channels) ch")
    check(abs(kbps - 320) < 8, "bit rate \(kbps) kbps")
    check(text.contains("Info") && text.contains("LAME"), "first frame carries the LAME Info tag")
    // Gapless: the decoder trims delay and padding by the tag. Within one
    // MP3 frame of the mix's own length.
    check(abs(file.frames - span.count) <= 1152, "decoded length off by \(file.frames - span.count) frames")
    check(peak > 0.3 && peak < 1.0, "level survives encoding: peak \(peak)")
}

section("tap tempo: bar taps with jitter and a double tap") {
    // 125 BPM → a bar every 1.92 s; taps ±12 ms around bar ones from 2.0 s.
    let jitter = [0.004, -0.011, 0.007, 0.012, -0.006, -0.002, 0.009, -0.012, 0.003, 0.0]
    var taps = jitter.enumerated().map { 2.0 + Double($0.offset) * 1.92 + $0.element }
    taps.insert(taps[4] + 0.15, at: 5)   // a nervous double tap
    guard let result = TapTempo.fit(barTaps: taps) else { check(false, "no fit"); return }
    check(abs(result.bpm - 125) < 0.2, "tempo \(result.bpm)")
    check(abs(result.firstDownbeat - 2.0) < 0.012, "bar one \(result.firstDownbeat)")
    check(result.tapsUsed == 10, "double tap dropped: \(result.tapsUsed) used")
    check(TapTempo.fit(barTaps: [1, 2.9, 4.8]) == nil, "three taps are not enough")
}

section("tap tempo: beat taps with jitter and a double tap") {
    // 87 BPM → a beat every 0.689655 s; taps ±15 ms around beats from 1.0 s.
    let jitter = [0.009, -0.015, 0.004, 0.013, -0.008, 0.0, 0.015, -0.011, 0.006, -0.004, 0.012, -0.014]
    var taps = jitter.enumerated().map { 1.0 + Double($0.offset) * 60 / 87 + $0.element }
    taps.insert(taps[6] + 0.09, at: 7)   // a double tap
    guard let result = TapTempo.fit(beatTaps: taps) else { check(false, "no fit"); return }
    check(abs(result.bpm - 87) < 0.5, "tempo \(result.bpm)")
    check(result.tapsUsed == 12, "double tap dropped: \(result.tapsUsed) used")
    check(result.bpmSpread > 0 && result.bpmSpread < 0.5, "spread \(result.bpmSpread)")
    check(TapTempo.fit(beatTaps: [1, 1.7, 2.4]) == nil, "three taps are not enough")
}

section("bpm choice: octave candidates and the suggestion") {
    func summary(_ list: [BPMChoice.Candidate]) -> String {
        list.map { "\($0.bpm)\($0.isSuggested ? "*" : "")" }.joined(separator: " ")
    }
    var list = BPMChoice.candidates(detected: 140, tapped: 70.4)
    check(list.map(\.bpm) == [70, 140, 280], "140 in three octaves: \(summary(list))")
    check(list.first(where: \.isSuggested)?.bpm == 70, "taps at 70.4 suggest 70: \(summary(list))")

    list = BPMChoice.candidates(detected: 174, tapped: 87.3)
    check(list.map(\.bpm) == [87, 174], "348 is beyond 300: \(summary(list))")
    check(list.first(where: \.isSuggested)?.bpm == 87, "taps at 87.3 suggest 87: \(summary(list))")

    list = BPMChoice.candidates(detected: 174, tapped: 176)
    check(list.first(where: \.isSuggested)?.bpm == 174, "taps at 176 confirm 174: \(summary(list))")

    list = BPMChoice.candidates(detected: 174, tapped: 120)
    check(list.map(\.bpm) == [87, 120, 174], "a tap matching no octave is offered: \(summary(list))")
    check(list.first(where: \.isSuggested)?.kind == .tap, "and suggested: \(summary(list))")

    list = BPMChoice.candidates(detected: 128, tapped: nil)
    check(list.first(where: \.isSuggested)?.kind == .detected, "no taps suggest the analysis: \(summary(list))")

    list = BPMChoice.candidates(detected: nil, tapped: 90)
    check(list.map(\.bpm) == [45, 90, 180] && list[1].kind == .tap && list[1].isSuggested,
          "without an analysis the taps are the base: \(summary(list))")
    check(BPMChoice.candidates(detected: nil, tapped: nil).isEmpty, "nothing to offer")
}

/// The curve of the clip on `lane`, read at timeline beats - its own curve,
/// so it can be read on the very beat the clip ends, where the lane already
/// rests.
func clipCurve(_ doc: MixDocument, lane: Int, _ kind: AutomationKind) -> (Double) -> Double {
    let clip = doc.clips.first { $0.lane == lane }!
    let curve = AutomationCurve(kind: kind, automation: clip.automation)
    return { curve.value(at: $0 - Double(clip.anchorBeat)) }
}

section("auto crossfade: equal power over the overlap") {
    var doc = MixDocument()
    try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)   // body 2 … 242
    try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)    // from 199.47
    let start = ClipGeometry(clip: doc.clips[1], grid: gridB).start
    let end = 242.0
    let count = (try? doc.autoCrossfade(nil, grids: grids)) ?? 0
    check(count == 1, "one transition, got \(count)")
    let out = clipCurve(doc, lane: 0, .volume)
    let into = clipCurve(doc, lane: 1, .volume)
    let middle = (start + end) / 2
    let half = -4 + 20 * log10(cos(Double.pi / 4))   // −7.01 dB
    check(abs(out(start) + 4) < 1e-9 && out(end) == Automation.silenceDB, "outgoing −4 dB → silence")
    check(abs(into(end) + 4) < 1e-9 && into(start) == Automation.silenceDB, "incoming silence → −4 dB")
    check(abs(out(middle) - half) < 1e-9 && abs(into(middle) - half) < 1e-9,
          "both at −7.01 dB half way: \(out(middle)), \(into(middle))")
    let quarter = start + (end - start) / 4
    let power = pow(10, out(quarter) / 10) + pow(10, into(quarter) / 10)
    check(abs(power - pow(10, -0.4)) < 1e-9, "power stays level at the quarter point: \(power)")
    check(doc.clips.allSatisfy { $0.automation.pan.isEmpty && $0.automation.lowPass.isEmpty && $0.automation.highPass.isEmpty }, "a crossfade writes volume only")
    check(LanePlan(document: doc, lane: 0, grids: grids).volume.value(at: 250) == -4, "lane A rests once the outgoing clip ends")
    check(LanePlan(document: doc, lane: 1, grids: grids).volume.value(at: 100) == -4, "lane B rests before the incoming clip")

    var apart = MixDocument()
    try! apart.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! apart.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 400, grids: grids)
    check((try? apart.autoCrossfade(nil, grids: grids)) == nil, "no overlap, nothing to fade")
    check(apart.clips.allSatisfy { $0.automation.isEmpty }, "and nothing written")
}


section("transitions: each style's recipe, and the curve outside stays") {
    func mix() -> MixDocument {
        var doc = MixDocument()
        try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
        try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
        return doc
    }
    let base = mix()
    let transition = base.transitions(grids)[0]
    func at(_ fraction: Double) -> Double { transition.start + fraction * (transition.end - transition.start) }
    func curve(_ style: TransitionStyle, _ kind: AutomationKind, lane: Int) -> (Double) -> Double {
        var doc = mix()
        try! doc.autoCrossfade(nil, style: style, grids: grids)
        return clipCurve(doc, lane: lane, kind)
    }

    for style in TransitionStyle.allCases {
        var doc = mix()
        try! doc.autoCrossfade(nil, style: style, grids: grids)
        for kind in AutomationKind.allCases {
            for lane in [0, 1] {
                // Each clip's own curve just outside the overlap - which for
                // one of the two lies beyond its edge, where the guard point
                // still has to hold it.
                let before = clipCurve(base, lane: lane, kind)
                let after = clipCurve(doc, lane: lane, kind)
                for beat in [transition.start - 1, transition.end + 1] {
                    check(after(beat) == before(beat),
                          "\(style.title): \(kind) on lane \(lane) at \(beat) is \(after(beat)), was \(before(beat))")
                }
            }
        }
        check(clipCurve(doc, lane: 0, .volume)(transition.end) == Automation.silenceDB,
              "\(style.title): the outgoing song is silent at the end")
        check(abs(clipCurve(doc, lane: 1, .volume)(transition.end) - Automation.defaultVolumeDB) < 1e-9,
              "\(style.title): the incoming song is at its level at the end")
        check(doc.clips[0].automation.pan.isEmpty == !(style == .stereoDrift || style == .stereoHandoff),
              "\(style.title): pan points only where the style moves pan")
    }

    check(abs(curve(.tape, .lowPass, lane: 0)(transition.end) - 0.25) < 1e-9, "Tape darkens the outgoing song")
    check(abs(curve(.air, .highPass, lane: 0)(transition.end) - 0.45) < 1e-9, "Air thins it")
    check(abs(curve(.telephone, .highPass, lane: 0)(at(0.5)) - 0.6) < 1e-9
          && abs(curve(.telephone, .lowPass, lane: 0)(at(0.5)) - 0.4) < 1e-9,
          "Telephone is a band - both ends cut - by 40 %")
    check(clipCurve(mix(), lane: 0, .lowPass)(at(0.5)) == 1, "before any style the low-pass is open")
    let reveal = curve(.filterReveal, .lowPass, lane: 1)
    check(abs(reveal(transition.start) - 0.15) < 1e-9 && abs(reveal(transition.end) - 1) < 1e-9,
          "Filter Reveal opens the incoming song")
    check(abs(curve(.stereoDrift, .pan, lane: 0)(transition.end) + 0.8) < 1e-9, "Stereo Drift moves A left")
    check(abs(curve(.stereoHandoff, .pan, lane: 1)(transition.start) - 1) < 1e-9, "Stereo Handoff brings B in from the right")
    check(abs(curve(.underwater, .volume, lane: 0)(at(0.25)) - Automation.defaultVolumeDB) < 1e-9,
          "Underwater holds the outgoing song at first")
    check(abs(curve(.soft, .volume, lane: 1)(at(0.5)) - (Automation.defaultVolumeDB + 20 * log10(0.5))) < 1e-9,
          "Soft Fade is straight in gain")

    var switched = mix()
    try! switched.autoCrossfade(nil, style: .tape, grids: grids)
    try! switched.autoCrossfade(nil, style: .soft, grids: grids)
    let filter = clipCurve(switched, lane: 0, .lowPass)
    check([0.1, 0.5, 0.9].allSatisfy { filter(at($0)) == 1 }, "no Tape filter left after switching to Soft")
}

section("transition marks: ⇧⌘X and a beatmix leave a bar, a drag draws one") {
    func mix() -> MixDocument {
        var doc = MixDocument()
        try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
        try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
        return doc
    }
    var doc = mix()
    let transition = doc.transitions(grids)[0]
    try! doc.autoCrossfade(nil, style: .crossfade, grids: grids)
    var marks = doc.placedMarks(grids)
    check(marks.count == 1 && marks[0].ref.clip == doc.clips[1].id, "one bar, on the incoming clip: \(marks)")
    check(near(marks[0].start, transition.start, 1e-9) && near(marks[0].end, transition.end, 1e-9),
          "the bar covers the overlap: \(marks[0].start)…\(marks[0].end)")
    check(marks[0].style == .crossfade, "and names its style")
    try! doc.autoCrossfade(nil, style: .tape, grids: grids)
    marks = doc.placedMarks(grids)
    check(marks.count == 1 && marks[0].style == .tape, "another style replaces the bar, not a second one")

    var beatmix = MixDocument()
    try! beatmix.addClip(trackID: trackA, grid: testGrid, beatmix: .beats16, grids: grids)
    try! beatmix.addClip(trackID: trackB, grid: gridB, beatmix: .beats16, grids: grids)
    marks = beatmix.placedMarks(grids)
    check(marks.count == 1 && marks[0].start == 224 && marks[0].end == 240 && marks[0].style == nil,
          "a beatmix's bar is its 16 beats, with no style: \(marks)")

    var drawn = mix()
    try! drawn.addMark(from: 230, to: 210, style: .soft, grids: grids)
    marks = drawn.placedMarks(grids)
    check(marks.count == 1 && marks[0].start == 210 && marks[0].end == 230, "drawn either way round: \(marks)")
    check(clipCurve(drawn, lane: 1, .volume)(210) == Automation.silenceDB
          && near(clipCurve(drawn, lane: 1, .volume)(230), Automation.defaultVolumeDB, 1e-9),
          "the style is written over the drawn range")
    check(clipCurve(drawn, lane: 0, .volume)(230) == Automation.silenceDB, "the outgoing side too")
    var refused = mix()
    let untouched = refused
    check((try? refused.addMark(from: 300, to: 320, style: .soft, grids: grids)) == nil && refused == untouched,
          "no bar where nothing overlaps")
    check((try? refused.addMark(from: 210, to: 210.5, style: .soft, grids: grids)) == nil, "nor shorter than a beat")
}

section("transition marks: moving rewrites the style, deleting clears the range") {
    var doc = MixDocument()
    try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
    let ref = try! doc.addMark(from: 210, to: 230, style: .soft, grids: grids)
    let moved = try! doc.moveMark(ref, from: 214, to: 234, currentStyle: .crossfade, grids: grids)
    let marks = doc.placedMarks(grids)
    check(marks.count == 1 && marks[0].ref == moved && marks[0].start == 214 && marks[0].end == 234
          && marks[0].style == .soft, "the bar moved and kept its style: \(marks)")
    let into = clipCurve(doc, lane: 1, .volume)
    let out = clipCurve(doc, lane: 0, .volume)
    check(near(into(212), Automation.defaultVolumeDB, 1e-9) && near(out(212), Automation.defaultVolumeDB, 1e-9),
          "nothing of the old range is left: \(into(212)), \(out(212))")
    check(into(214) == Automation.silenceDB && near(into(234), Automation.defaultVolumeDB, 1e-9)
          && out(234) == Automation.silenceDB, "the style is written over the new range")
    let before = doc
    check((try? doc.moveMark(moved, from: 300, to: 320, currentStyle: .soft, grids: grids)) == nil && doc == before,
          "a bar cannot leave the overlap")
    try! doc.applyStyle(.tape, toMark: moved, grids: grids)
    check(doc.placedMarks(grids).first?.style == .tape && clipCurve(doc, lane: 0, .lowPass)(234) < 1,
          "another style in place")

    // Delete: every kind on every clip inside, nothing outside; a movement
    // across the edge is cut and what follows keeps its rhythm.
    let anchorA = Double(doc.clips[0].anchorBeat)
    doc.clips[0].automation.setNodes(.pan, [AutomationNode(beat: 100 - anchorA, value: 0.5),
                                            AutomationNode(beat: 220 - anchorA, value: -0.5)])
    let wave = AutomationGesture(kind: .highPass, start: 180 - anchorA, end: 250 - anchorA, shape: .triangle,
                                 period: 4, low: 0, high: 0.5)
    doc.clips[0].automation.gestures = [wave]
    var locked = doc
    locked.setLocked(moved.clip, true)
    check((try? locked.removeMark(moved, grids: grids)) == nil, "a locked clip's bar stays")
    try! doc.removeMark(moved, grids: grids)
    check(doc.placedMarks(grids).isEmpty, "the bar is gone")
    for (index, clip) in doc.clips.enumerated() {
        let anchor = Double(clip.anchorBeat)
        for kind in AutomationKind.allCases {
            check(!clip.automation.nodes(kind).contains { $0.beat + anchor >= 214 - 0.02 && $0.beat + anchor <= 234 + 0.02 },
                  "no \(kind) point left inside on clip \(index)")
        }
    }
    check(doc.clips[0].automation.pan.map { $0.beat + anchorA } == [100], "the pan point outside stays")
    let pieces = doc.clips[0].automation.gestures.map { ($0.start + anchorA, $0.end + anchorA) }
    check(pieces.count == 2 && pieces[0].0 == 180 && near(pieces[0].1, 214 - MixDocument.crossfadeGuard, 1e-6)
          && pieces[1].0 == 236 && pieces[1].1 == 250, "the movement is cut around the range: \(pieces)")
    if let after = doc.clips[0].automation.gestures.last {
        check(after.value(at: 241 - anchorA) == wave.value(at: 241 - anchorA), "and keeps its rhythm after it")
    }
}

section("transition marks: split, ⌥⌫ and the file") {
    var doc = MixDocument()
    try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! doc.addClip(trackID: trackB, grid: gridB, lane: 1, startBeat: 200, grids: grids)
    try! doc.autoCrossfade(nil, grids: grids)
    let data = try! doc.fileData()
    check((try? MixDocument.load(from: data)) == doc, "a bar is saved and read back")
    var split = doc
    try! split.splitClip(split.clips[1].id, at: 260, grids: grids)
    check(split.placedMarks(grids).count == 1, "a split leaves one bar, on the half it begins on")
    try! doc.removeAutomation(onClips: [doc.clips[1].id])
    check(doc.placedMarks(grids).isEmpty, "⌥⌫ takes the bar with the points")
}

section("beatmix: three points on the grid, a cut, and a chain across the lanes") {
    var doc = MixDocument()
    let first = try! doc.addClip(trackID: trackA, grid: testGrid, beatmix: .beats16, grids: grids)
    check(doc.clips[0].id == first && doc.clips[0].automation.isEmpty, "the first clip is placed plainly")
    let end = ClipGeometry(clip: doc.clips[0], grid: testGrid).end   // 242
    try! doc.addClip(trackID: trackB, grid: gridB, beatmix: .beats16, grids: grids)
    let b = doc.clips[1]
    check(b.lane == 1 && b.anchorBeat == 224 && b.tempoAnchorBeat == 224,
          "B's bar one on the start, 16 beats before the last bar line 240: lane \(b.lane), anchor \(b.anchorBeat)")
    let out = doc.clips[0].automation.volume
    let into = b.automation.volume
    check(out.count == 3 && into.count == 3, "three points each: \(out.count), \(into.count)")
    check((out + into).allSatisfy { $0.beat == $0.beat.rounded() }, "all on whole beats")
    check(out.map(\.beat) == [220, 236, 236] && out.map(\.value) == [-4, -10, Automation.silenceDB],
          "outgoing −4 → −10, cut at 240: \(out)")
    check(into.map(\.beat) == [0, 0, 16] && into.map(\.value) == [Automation.silenceDB, -10, -4],
          "incoming silence, −10 → −4: \(into)")
    let a = clipCurve(doc, lane: 0, .volume)
    let bIn = clipCurve(doc, lane: 1, .volume)
    check(a(100) == -4 && a(232) == -7 && a(240) == Automation.silenceDB && a(241.5) == Automation.silenceDB,
          "A: level before, linear, silent from the cut to its end")
    check(bIn(223.6) == Automation.silenceDB && bIn(224.001) > -10.01 && bIn(232) == -7 && bIn(300) == -4,
          "B: silent pre-roll, then −10 rising to −4")
    let transition = doc.transitions(grids)
    check(transition.count == 1 && transition[0].end == end && transition[0].incoming == b.id,
          "an ordinary transition for ⇧⌘X: \(transition)")

    let decoded = try! MixDocument.load(from: try! doc.fileData())
    check(decoded.clips.map(\.automation) == doc.clips.map(\.automation), "the steps keep their order through a save")

    try! doc.addClip(trackID: trackA, grid: testGrid, beatmix: .beats32, grids: grids)
    check(doc.clips[2].lane == 2 && doc.clips[2].anchorBeat == 316,
          "a third one mixes out of B on lane C: lane \(doc.clips[2].lane), anchor \(doc.clips[2].anchorBeat)")
    check(doc.clips[0].automation.volume.count == 3, "A is left alone by the second beatmix")
    check(doc.clips[1].automation.volume.map(\.beat) == [0, 0, 16, 92, 124, 124],
          "B keeps its fade-in and gets its fade-out: \(doc.clips[1].automation.volume.map(\.beat))")

    var drawn = MixDocument()
    try! drawn.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    drawn.clips[0].automation.setNodes(.volume, [AutomationNode(beat: 10, value: -8), AutomationNode(beat: 230, value: 3)])
    try! drawn.addClip(trackID: trackB, grid: gridB, beatmix: .beats8, grids: grids)
    check(drawn.clips[0].automation.volume.map(\.beat) == [10, 228, 236, 236],
          "points before the start stay, points inside go: \(drawn.clips[0].automation.volume)")
    check(abs(drawn.clips[0].automation.volume[1].value - (-8 + 11 * 218 / 220.0)) < 1e-9,
          "the start holds the drawn level: \(drawn.clips[0].automation.volume[1].value)")

    var short = MixDocument()
    try! short.addClip(trackID: trackB, grid: gridB, lane: 0, startBeat: 0, grids: grids)   // 128 beats
    check((try? short.addClip(trackID: trackA, grid: testGrid, beatmix: .beats64, grids: grids)) != nil, "64 fits in 128")
    var tiny = MixDocument()
    try! tiny.addClip(trackID: trackB, grid: gridB, lane: 0, startBeat: 0, grids: grids)
    tiny.clips[0].trimEnd = 100
    let refused = (try? tiny.addClip(trackID: trackA, grid: testGrid, beatmix: .beats32, grids: grids)) == nil
    check(refused && tiny.clips.count == 1, "a clip shorter than the beatmix refuses it")
    let brief = UUID()
    let briefGrid = SourceGrid(bpm: 128, firstBeatSeconds: 0.25, durationSeconds: 2)   // 4.27 beats
    var overlay = MixDocument()
    try! overlay.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let lookup: GridLookup = { $0 == brief ? briefGrid : grids($0) }
    check((try? overlay.addClip(trackID: brief, grid: briefGrid, beatmix: .beats8, grids: lookup)) == nil
          && overlay.clips.count == 1, "a track that would end inside the last clip is refused")

    var four = MixDocument()
    try! four.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! four.addClip(trackID: trackB, grid: gridB, beatmix: .beats4, grids: grids)
    check(four.clips[1].anchorBeat == 236 && four.clips[0].automation.volume.map(\.beat) == [232, 236, 236]
          && four.clips[1].automation.volume.map(\.beat) == [0, 0, 4], "Beatmix 4: one bar, 236 … 240")

    var plain = MixDocument()
    try! plain.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)   // ends at 242
    try! plain.addClip(trackID: trackB, grid: gridB, beatmix: .noTransition, grids: grids)
    let after = ClipGeometry(clip: plain.clips[1], grid: gridB)
    check(plain.clips[1].anchorBeat == 244 && plain.clips[1].lane == 1 && after.start >= 242,
          "No Transition: on the first bar line after the end, intro included: anchor \(plain.clips[1].anchorBeat), from \(after.start)")
    check(plain.clips.allSatisfy { $0.automation.isEmpty } && plain.transitions(grids).isEmpty,
          "No Transition: no overlap and nothing written")
    // A with its music ending at 110 s: the last 10 s (20 beats) are the
    // file's silent tail, so the mix ends at beat 222, not 242.
    var quietA = testGrid
    quietA.soundEndSeconds = 110
    let quiet: GridLookup = { $0 == trackA ? quietA : grids($0) }
    var tail = MixDocument()
    try! tail.addClip(trackID: trackA, grid: quietA, lane: 0, startBeat: 0, grids: quiet)
    try! tail.addClip(trackID: trackB, grid: gridB, beatmix: .beats16, grids: quiet)
    check(tail.clips[1].anchorBeat == 204 && tail.clips[0].automation.volume.map(\.beat) == [200, 216, 216],
          "the beatmix ends on the last bar line of the music, 220: anchor \(tail.clips[1].anchorBeat), \(tail.clips[0].automation.volume.map(\.beat))")
    var tailPlain = MixDocument()
    try! tailPlain.addClip(trackID: trackA, grid: quietA, lane: 0, startBeat: 0, grids: quiet)
    try! tailPlain.addClip(trackID: trackB, grid: gridB, beatmix: .noTransition, grids: quiet)
    check(tailPlain.clips[1].anchorBeat == 224 && tailPlain.clips[1].lane == 1,
          "No Transition follows the music, not the file: anchor \(tailPlain.clips[1].anchorBeat), lane \(tailPlain.clips[1].lane)")
    var trimmed = MixDocument()
    try! trimmed.addClip(trackID: trackA, grid: quietA, lane: 0, startBeat: 0, grids: quiet)
    trimmed.clips[0].trimEnd = 40   // the body ends at 202, before the silence
    try! trimmed.addClip(trackID: trackB, grid: gridB, beatmix: .beats16, grids: quiet)
    check(trimmed.clips[1].anchorBeat == 184, "a clip trimmed before the silence ends where it is cut: \(trimmed.clips[1].anchorBeat)")
    var looped = MixDocument()
    try! looped.addClip(trackID: trackA, grid: quietA, lane: 0, startBeat: 0, grids: quiet)
    looped.clips[0].looping = true
    looped.clips[0].loopTail = 30
    try! looped.addClip(trackID: trackB, grid: gridB, beatmix: .beats16, grids: quiet)
    check(looped.clips[1].anchorBeat == 256, "a looping clip ends where its loop ends: \(looped.clips[1].anchorBeat)")

    check(BeatmixLength.allCases.map(\.title) == ["No Transition", "Beatmix 4", "Beatmix 8", "Beatmix 16", "Beatmix 32", "Beatmix 64"],
          "the beatmix lengths read in order")
}

section("beatmix at the playhead: the next four-bar line, a trim, and the rest of the mix follows") {
    // A (120 BPM, anchor 4, ends 242) with B beatmixed onto its end: B's
    // bar one on 224 on lane B, the handover ending on 240.
    func mix() -> MixDocument {
        var doc = MixDocument()
        try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
        try! doc.addClip(trackID: trackB, grid: gridB, beatmix: .beats16, grids: grids)
        return doc
    }
    var doc = mix()
    let follower = doc.clips[1].id
    let new = try! doc.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atBeat: 50, grids: grids)
    let a = doc.clips[0]
    let inserted = doc.clips.first { $0.id == new }!
    let moved = doc.clips.first { $0.id == follower }!
    check(inserted.anchorBeat == 68 && inserted.tempoAnchorBeat == 68,
          "playhead 50: A's four-bar lines are 4 + 16k, a bar ahead is 54, so 68: \(inserted.anchorBeat)")
    check(ClipGeometry(clip: a, grid: testGrid).end == 84, "A is trimmed where the beatmix ends, 84")
    check(a.automation.volume.map(\.beat) == [64, 80, 80] && a.automation.volume.map(\.value) == [-4, -10, Automation.silenceDB],
          "A gets the end-of-mix handover, in its own beats: \(a.automation.volume)")
    check(inserted.automation.volume.prefix(3).map(\.beat) == [0, 0, 16]
          && inserted.automation.volume.prefix(3).map(\.value) == [Automation.silenceDB, -10, -4], "the new clip rises in as at the end")
    // New B's music ends at 195.47 (last bar 192), A's did at 242 (240): −48.
    check(moved.anchorBeat == 176 && moved.tempoAnchorBeat == 176 && moved.automation.volume.map(\.beat) == [0, 0, 16],
          "the follower moves by −48 and keeps its fade-in: anchor \(moved.anchorBeat)")
    check(inserted.lane == 2, "the new clip takes the lane the follower does not need: \(inserted.lane)")
    // The new B ends its music at 195.47; the follower's bar one is 176.
    check(inserted.automation.volume.map(\.beat) == [0, 0, 16, 108, 124, 124]
          && inserted.automation.volume.suffix(3).map(\.value) == [-4, -10, Automation.silenceDB],
          "the new clip fades out into the follower, 176 … 192: \(inserted.automation.volume)")
    check(doc.transitions(grids).contains { $0.incoming == follower }, "the handover into the follower is a transition")
    check(doc.clips.allSatisfy { doc.fits($0, grids) }, "nothing overlaps on a lane")

    var near = mix()
    let n = try! near.insertClip(trackID: trackB, grid: gridB, beatmix: .beats8, atBeat: 47, grids: grids)
    check(near.clips.first { $0.id == n }!.anchorBeat == 52, "playhead 47: 52 is still a bar ahead")

    var overlap = mix()
    let o = try! overlap.insertClip(trackID: trackA, grid: testGrid, beatmix: .beats16, atBeat: 230, grids: grids)
    check(overlap.clips.first { $0.id == o }!.anchorBeat == 240
          && ClipGeometry(clip: overlap.clips[1], grid: gridB).end == 256
          && ClipGeometry(clip: overlap.clips[0], grid: testGrid).end == 242,
          "inside a beatmix the record that came in last is the one cut")

    // B first (anchor 4, music to 131.47), A beatmixed on at 112; A goes in
    // at 36 and runs 240 beats to 274: the follower moves +144.
    var grow = MixDocument()
    try! grow.addClip(trackID: trackB, grid: gridB, lane: 0, startBeat: 0, grids: grids)
    try! grow.addClip(trackID: trackA, grid: testGrid, beatmix: .beats16, grids: grids)
    let g = try! grow.insertClip(trackID: trackA, grid: testGrid, beatmix: .beats16, atBeat: 20, grids: grids)
    check(grow.clips.first { $0.id == g }!.anchorBeat == 36 && grow.clips[1].anchorBeat == 256 && grow.clips[1].tempoAnchorBeat == 256,
          "a longer record pushes the rest later: \(grow.clips[1].anchorBeat)")
    check(grow.clips.first { $0.id == g }!.automation.volume.map(\.beat) == [0, 0, 16, 220, 236, 236],
          "and fades out into it, 256 … 272: \(grow.clips.first { $0.id == g }!.automation.volume.map(\.beat))")
    var alone = MixDocument()
    try! alone.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let l = try! alone.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atBeat: 50, grids: grids)
    check(alone.clips.first { $0.id == l }!.automation.volume.count == 3, "with nothing after it, no fade-out")

    let before = mix()
    var refuse = before
    check((try? refuse.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atBeat: 500, grids: grids)) == nil
          && refuse == before, "nothing playing at the playhead is refused")
    check((try? refuse.insertClip(trackID: trackB, grid: gridB, beatmix: .beats64, atBeat: 180, grids: grids)) == nil
          && refuse == before, "a record with too little left is refused")
    check((try? refuse.insertClip(trackID: trackB, grid: gridB, beatmix: .noTransition, atBeat: 50, grids: grids)) == nil,
          "No Transition does not go in at the playhead")
    var lockedNext = before
    lockedNext.clips[1].locked = true
    let lockedBefore = lockedNext
    check((try? lockedNext.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atBeat: 50, grids: grids)) == nil
          && lockedNext == lockedBefore, "a locked clip in the rest of the mix stops it, and nothing changes")

    var lockedOut = MixDocument()
    try! lockedOut.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    lockedOut.clips[0].locked = true
    try! lockedOut.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atBeat: 50, grids: grids)
    check(ClipGeometry(clip: lockedOut.clips[0], grid: testGrid).end == 84 && lockedOut.clips[0].automation.isEmpty,
          "a locked record is trimmed but keeps its automation")
}
section("cue points: eight numbers, kept in seconds of the song") {
    var cues = CueRules.setting([], number: 3, seconds: 10)
    check(cues.map(\.number) == [3] && cues[0].seconds == 10, "one cue, on number 3")
    cues = CueRules.setting(cues, number: 1, seconds: 40)
    cues = CueRules.setting(cues, number: 3, seconds: 12)
    check(cues.map(\.number) == [1, 3] && CueRules.cue(cues, number: 3)?.seconds == 12,
          "setting 3 again moves it, it does not make a second: \(cues.map(\.number))")
    check(CueRules.setting(cues, number: 9, seconds: 5) == cues
          && CueRules.setting(cues, number: 0, seconds: 5) == cues, "a number no key can reach is refused")
    check(CueRules.inTimeOrder(cues).map(\.number) == [3, 1], "in time order the later number can come first")
    check(CueRules.freeNumber(cues) == 2 && CueRules.freeNumber([]) == 1, "the lowest free number")
    check(CueRules.freeNumber((1...8).map { CuePoint(number: $0, seconds: Double($0)) }) == nil, "all eight taken")
    check(CueRules.removing(cues, number: 3).map(\.number) == [1], "removing leaves the rest")
    check(CuePoint(number: 1, seconds: -3).seconds == 0, "a cue cannot sit before the file")

    // testGrid: 120 BPM, bar one at 1.0 s. A cue 9 s in is 16 beats past it.
    check(CueRules.beat(ofCue: 9, grid: testGrid, anchorBeat: 4) == 20, "a cue's beat on a clip anchored at 4")
    check(CueRules.beat(ofCue: 0.5, grid: testGrid, anchorBeat: 4) == 3, "a cue in the intro lies before bar one")
    let marks = [CuePoint(number: 1, seconds: 9), CuePoint(number: 2, seconds: 60)]
    check(CueRules.insertStart(cues: marks, grid: testGrid, anchorBeat: 4, notBefore: 0) == 20,
          "the first cue's bar line")
    check(CueRules.insertStart(cues: marks, grid: testGrid, anchorBeat: 4, notBefore: 104) == 124,
          "60 s is beat 122, which rounds to the bar line 124")
    check(CueRules.insertStart(cues: marks, grid: testGrid, anchorBeat: 4, notBefore: 200) == nil,
          "nothing left ahead of the playhead")
    check(CueRules.insertStart(cues: [CuePoint(number: 1, seconds: 9.4)], grid: testGrid,
                               anchorBeat: 4, notBefore: 0) == 20,
          "a cue dropped a little after the bar still starts on the bar")
    check(CueRules.insertStart(cues: [], grid: testGrid, anchorBeat: 4, notBefore: 0) == nil, "no cue, no beat")

    var track = Track(path: "Audio/a.wav", bookmark: nil, title: "A", artist: nil, durationSeconds: 120)
    check(track.setCue(number: 1, seconds: 9) && !track.setCue(number: 1, seconds: 9),
          "setting a cue where it already is is not an edit")
    check(track.setCue(number: 1, seconds: nil) && !track.setCue(number: 1, seconds: nil),
          "clearing one that is gone is not an edit either")
    let plain = String(data: try! Track.encodeLibrary([track]), encoding: .utf8)!
    check(!plain.contains("cuePoints"), "a track with no cues saves as it did before there were any")
    track.setCue(number: 2, seconds: 31.5)
    let saved = try! Track.encodeLibrary([track])
    check(try! Track.decodeLibrary(saved)[0].cuePoints == track.cuePoints, "cues survive a save")
    let junk = plain.replacingOccurrences(
        of: "\"durationSeconds\"",
        with: "\"cuePoints\" : [{\"number\":99,\"seconds\":5},{\"number\":2,\"seconds\":7},{\"number\":2,\"seconds\":9}],\n    \"durationSeconds\"")
    check(try! Track.decodeLibrary(Data(junk.utf8))[0].cuePoints == [CuePoint(number: 2, seconds: 7)],
          "a number out of range and a second cue on one number are dropped on load")
}
section("beatmix at a cue: the cue's bar line, the rest as at the playhead") {
    var doc = MixDocument()
    try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    check(doc.clips[0].anchorBeat == 4, "A's bar one on the first bar line its intro allows")
    let marks: CueLookup = { $0 == trackA ? [CuePoint(number: 1, seconds: 9), CuePoint(number: 2, seconds: 60)] : [] }
    try! doc.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atCueAfter: 0, cues: marks, grids: grids)
    let b = doc.clips[1]
    check(b.anchorBeat == 20 && b.tempoAnchorBeat == 20 && b.lane == 1,
          "B's bar one on the first cue's bar line: \(b.anchorBeat), lane \(b.lane)")
    check(ClipGeometry(clip: doc.clips[0], grid: testGrid).end == 36, "A is cut where the beatmix ends")
    check(doc.clips[0].automation.volume.map(\.beat) == [16, 32, 32], "A's three points, clip-local")
    check(b.automation.volume.map(\.beat) == [0, 0, 16], "B's three points from its bar one")

    var later = MixDocument()
    try! later.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! later.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atCueAfter: 100, cues: marks, grids: grids)
    check(later.clips[1].anchorBeat == 124, "the playhead at 100 takes the second cue: \(later.clips[1].anchorBeat)")

    var none = MixDocument()
    try! none.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let empty: CueLookup = { _ in [] }
    check((try? none.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atCueAfter: 0,
                                cues: empty, grids: grids)) == nil, "a record without cues refuses")
    check((try? none.insertClip(trackID: trackB, grid: gridB, beatmix: .beats16, atCueAfter: 200,
                                cues: marks, grids: grids)) == nil, "every cue behind the playhead refuses")
    check((try? none.insertClip(trackID: trackB, grid: gridB, beatmix: .noTransition, atCueAfter: 0,
                                cues: marks, grids: grids)) == nil, "no hard cut at a cue")
    check(none.clips.count == 1, "a refusal leaves the mix as it was")

    var first = MixDocument()
    try! first.insertClip(trackID: trackA, grid: testGrid, beatmix: .beats16, atCueAfter: 0,
                          cues: empty, grids: grids)
    check(first.clips.count == 1 && first.clips[0].automation.isEmpty,
          "the first track of a mix has nothing to mix out of and is placed plainly")
}
section("loop from a marked region: whole beats, repeats, and where it lands") {
    // testGrid: 120 BPM, bar one at 1.0 s, 2 beats of pre-roll, 240 beats long.
    let region = LoopRegion(from: 5.0, to: 3.0)
    check(region.startSeconds == 3 && region.endSeconds == 5, "a drag in either direction is the same region")
    check(region.beats(in: testGrid) == 4, "two seconds at 120 BPM are four beats")
    let loose = LoopRegion(from: 3.1, to: 4.9).snapped(to: testGrid)
    check(loose == region, "snapping puts both ends on the nearest gridline")
    check(LoopRegion(from: 0.1, to: 0.4).clamped(to: 0.2).endSeconds == 0.2, "clamped to the file")

    let draft = ClipDraft.loop(region: region, grid: testGrid, repeats: 8)!
    check(draft.trimStart == 6 && draft.trimEnd == 230 && draft.leadBeats == 4 && draft.looping,
          "4 beats past bar one, 2 of pre-roll: trims \(draft.trimStart)/\(draft.trimEnd), lead \(draft.leadBeats)")
    check(draft.loopTail == 28 && draft.startOffset(testGrid) == 4, "eight copies of four beats: \(draft.loopTail)")
    check(ClipDraft.loop(region: LoopRegion(from: 3, to: 3.1), grid: testGrid, repeats: 4) == nil,
          "a stretch shorter than a clip may be is no loop")
    check(ClipDraft.loop(region: LoopRegion(from: 119, to: 130), grid: testGrid, repeats: 4) == nil,
          "a region reaching past the file is refused")
    check(ClipDraft.loop(region: region, grid: testGrid, repeats: 1)!.loopTail == 0, "once is the region itself")

    var doc = MixDocument()
    try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)   // ends at 242
    try! doc.addClip(trackID: trackA, grid: testGrid, beatmix: .beats16, grids: grids, draft: draft)
    let loop = doc.clips[1]
    let shape = ClipGeometry(clip: loop, grid: testGrid)
    check(loop.anchorBeat == 220 && shape.bodyStart == 224 && shape.bodyEnd == 228,
          "the loop's first sample on the beatmix start 224, not its bar one: \(shape)")
    check(shape.end == 256 && shape.segments().count == 8, "eight copies to beat 256: \(shape.segments().count)")
    check(loop.automation.volume.map(\.beat) == [4, 4, 20],
          "the fade-in runs from where the loop starts, not from bar one: \(loop.automation.volume.map(\.beat))")
    check(doc.clips[0].automation.volume.map(\.beat) == [220, 236, 236], "the record fades out as it always does")
    check(doc.transitions(grids).count == 1, "an ordinary transition, so ⇧⌘X can replace it")

    var short = MixDocument()
    try! short.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    let twice = ClipDraft.loop(region: region, grid: testGrid, repeats: 2)!
    check((try? short.addClip(trackID: trackA, grid: testGrid, beatmix: .beats16, grids: grids,
                              draft: twice)) == nil,
          "a loop that is over before the record it mixes out of is refused")

    var here = MixDocument()
    try! here.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    try! here.insertClip(trackID: trackA, grid: testGrid, beatmix: .beats16, atBeat: 50, grids: grids, draft: draft)
    let inserted = here.clips[1]
    let insertedShape = ClipGeometry(clip: inserted, grid: testGrid)
    check(inserted.anchorBeat == 64 && insertedShape.bodyStart == 68 && insertedShape.end == 100,
          "at the playhead the loop starts on the next four-bar line 68: \(insertedShape)")
    check(ClipGeometry(clip: here.clips[0], grid: testGrid).end == 84, "the record is cut where the beatmix ends")
    check(inserted.automation.volume.map(\.beat) == [4, 4, 20], "the same fade-in, from the loop's start")

    let decoded = try! MixDocument.load(from: try! doc.fileData())
    check(decoded.clips[1].looping && decoded.clips[1].loopTail == 28 && decoded.clips[1].trimStart == 6,
          "a loop clip is an ordinary clip in the file")

    // Found in the app: the first clip of a mix goes in through another
    // door, and that door used to place the whole record whatever was asked
    // for - a loop into an empty mix played the song.
    var empty = MixDocument()
    try! empty.addClip(trackID: trackA, grid: testGrid, beatmix: .beats16, grids: grids, draft: draft)
    let first = empty.clips[0]
    let firstShape = ClipGeometry(clip: first, grid: testGrid)
    check(first.looping && first.loopTail == 28 && firstShape.bodyStart == 0 && first.anchorBeat == -4
          && first.tempoAnchorBeat == 0,
          "a loop is still a loop as the first clip, its sound and its tempo point on beat 0: \(firstShape)")
    var atPlayhead = MixDocument()
    try! atPlayhead.insertClip(trackID: trackA, grid: testGrid, beatmix: .beats16, atBeat: 0, grids: grids,
                               draft: draft)
    check(atPlayhead.clips[0].looping, "and at the playhead of an empty mix as well")
    var plain = MixDocument()
    try! plain.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    check(plain.clips[0].anchorBeat == 4 && !plain.clips[0].looping, "a record is placed exactly as before")

    // A loop keeps its place on the bar when it is dragged: what snaps is
    // its first sample, not the bar one it was cut away from.
    // A region five beats past bar one: its lead is not a whole bar, so the
    // two rules differ - the bar one would land on 152 and the loop a beat
    // later, off the grid it was cut on.
    let offbeat = ClipDraft.loop(region: LoopRegion(from: 3.5, to: 5.5), grid: testGrid, repeats: 8)!
    check(offbeat.leadBeats == 5 && offbeat.trimStart == 7, "lead \(offbeat.leadBeats)")
    var dragged = MixDocument()
    let id = try! dragged.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 40, grids: grids,
                                  draft: offbeat)
    check(ClipGeometry(clip: dragged.clips[0], grid: testGrid).bodyStart == 40, "placed on the bar line 40")
    try! dragged.moveClip(id, anchorBeat: 150, lane: 0, grids: grids)
    let moved = ClipGeometry(clip: dragged.clips[0], grid: testGrid)
    check(dragged.clips[0].anchorBeat == 151 && moved.bodyStart == 156,
          "dragged to 150 the loop starts on bar line 156, anchor \(dragged.clips[0].anchorBeat)")
    check(MixDocument.snapLead(dragged.clips[0], testGrid) == 5
          && MixDocument.snapLead(plain.clips[0], testGrid) == 0, "only a loop past bar one leads")
    var edge = doc
    edge.clips[1].trimStart = 0
    check(MixDocument.snapLead(edge.clips[1], testGrid) == 0,
          "a clip looped by dragging its edge snaps by its bar one, as it always did")
}
section("library add mode: every mode stored and read back, Add by default") {
    let all = LibraryAddMode.allCases
    check(all.count == 17 && all.first == .plain && all[1] == .end(.noTransition) && all[6] == .end(.beats64)
          && all[7] == .playhead(.beats4) && all[11] == .playhead(.beats64) && all[12] == .cue(.beats4)
          && all.last == .cue(.beats64), "menu order: \(all.map(\.rawValue))")
    check(!all.contains(.playhead(.noTransition)) && !all.contains(.cue(.noTransition)),
          "no hard cut at the playhead or at a cue")
    check(all.allSatisfy { LibraryAddMode(rawValue: $0.rawValue) == $0 } && Set(all.map(\.rawValue)).count == 17,
          "each mode reads back as itself")
    check(LibraryAddMode(rawValue: "playhead-0") == nil && LibraryAddMode(rawValue: "end-12") == nil
          && LibraryAddMode(rawValue: "cue-0") == nil && LibraryAddMode(rawValue: "") == nil,
          "unknown values are refused")
    let key = LibraryAddMode.storageKey
    let saved = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
    check(LibraryAddMode.current == .plain, "nothing stored: Add, as Return did before")
    UserDefaults.standard.set("nonsense", forKey: key)
    check(LibraryAddMode.current == .plain, "something unreadable: Add")
    LibraryAddMode.current = .playhead(.beats32)
    check(LibraryAddMode.current == .playhead(.beats32), "a choice is kept")
    UserDefaults.standard.set(saved, forKey: key)
}

// MARK: - Tags

/// A four-character atom around its content, the way an MP4 file is built.
/// The type is four *bytes*: iTunes' own atoms start with 0xA9, which is one
/// byte there and two in UTF-8.
func mp4Atom(_ type: [UInt8], _ content: [UInt8]) -> [UInt8] {
    let size = content.count + 8
    return [UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)] + type + content
}

func mp4Atom(_ type: String, _ content: [UInt8]) -> [UInt8] {
    mp4Atom(Array(type.utf8), content)
}

func beU32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

func readBE32(_ data: Data, _ at: Int) -> Int {
    (0..<4).reduce(0) { $0 << 8 | Int(data[data.startIndex + at + $1]) }
}

/// Where a four-character type sits in the file, first occurrence.
func offset(of type: String, in data: Data) -> Int? {
    let needle = Data(type.utf8)
    return data.range(of: needle).map { $0.lowerBound - data.startIndex }
}

/// An MP4 file with the moov in front of the mdat - the layout in which
/// inserting a tag moves all of the audio - with a chunk offset table that
/// points into the mdat.
func syntheticMP4(tempo: Int?) -> Data {
    let audio = [UInt8]((0..<512).map { UInt8($0 % 251) })
    var list: [UInt8] = mp4Atom([0xA9] + Array("nam".utf8),
                                mp4Atom("data", [0, 0, 0, 1] + [0, 0, 0, 0] + Array("Title".utf8)))
    if let tempo {
        list += mp4Atom("tmpo", mp4Atom("data", [0, 0, 0, 21] + [0, 0, 0, 0]
                                        + [UInt8((tempo >> 8) & 0xFF), UInt8(tempo & 0xFF)]))
    }
    let handler = mp4Atom("hdlr", [0, 0, 0, 0, 0, 0, 0, 0] + Array("mdirappl".utf8) + [UInt8](repeating: 0, count: 9))
    let udta = mp4Atom("udta", mp4Atom("meta", [0, 0, 0, 0] + handler + mp4Atom("ilst", list)))

    // Two chunks, at the start and the middle of the mdat's content. The
    // mdat's own offset depends on how big the moov turns out to be, so the
    // table is built once the rest is known.
    func build(mdatStart: Int) -> (moov: [UInt8], file: [UInt8]) {
        let chunks = [mdatStart + 8, mdatStart + 8 + 256]
        let stco = mp4Atom("stco", [0, 0, 0, 0] + beU32(chunks.count) + chunks.flatMap(beU32))
        let moov = mp4Atom("moov", mp4Atom("trak", mp4Atom("mdia", mp4Atom("minf", mp4Atom("stbl", stco)))) + udta)
        let ftyp = mp4Atom("ftyp", Array("M4A M4A mp42isom".utf8))
        return (moov, ftyp + moov + mp4Atom("mdat", audio))
    }
    // One pass to learn the size, one to write it with the right offsets.
    let first = build(mdatStart: 0)
    return Data(build(mdatStart: mp4Atom("ftyp", Array("M4A M4A mp42isom".utf8)).count + first.moov.count).file)
}

section("MP4 tag: inserted, and everything behind it moves with it") {
    let before = syntheticMP4(tempo: nil)
    guard let stcoAt = offset(of: "stco", in: before), let mdatAt = offset(of: "mdat", in: before) else {
        check(false, "the synthetic file is not shaped as expected"); return
    }
    let chunksAt = stcoAt + 4 + 4 + 4      // type, version/flags, entry count
    let chunksBefore = [readBE32(before, chunksAt), readBE32(before, chunksAt + 4)]
    // `offset(of:)` finds the type, which sits four bytes into the atom.
    check(chunksBefore == [mdatAt + 4, mdatAt + 4 + 256], "chunks point into the mdat: \(chunksBefore)")
    check(MP4Tag.readBPM(before) == nil, "no tempo to start with")

    guard let after = try! MP4Tag.writingBPM(126, into: before) else {
        check(false, "nothing written"); return
    }
    check(after.count == before.count + 26, "grew by one tmpo atom: \(after.count - before.count)")
    check(MP4Tag.readBPM(after) == 126, "reads back as 126: \(String(describing: MP4Tag.readBPM(after)))")
    let moovAt = offset(of: "moov", in: after)!
    check(readBE32(after, moovAt - 4) == readBE32(before, moovAt - 4) + 26, "the moov grew by 26")
    let chunksAfter = [readBE32(after, chunksAt), readBE32(after, chunksAt + 4)]
    check(chunksAfter == chunksBefore.map { $0 + 26 }, "every chunk offset moved by 26: \(chunksAfter)")
    // The audio itself is untouched, and still where the table says it is.
    let audioBefore = before[(before.startIndex + chunksBefore[0])...].prefix(512)
    let audioAfter = after[(after.startIndex + chunksAfter[0])...].prefix(512)
    check(Array(audioBefore) == Array(audioAfter), "the audio is where the new offsets point, byte for byte")

    // Writing the same tempo again changes nothing at all.
    check(try! MP4Tag.writingBPM(126, into: after) == nil, "the same value again is no write")
    // A different one replaces 26 bytes with 26: nothing moves this time.
    guard let changed = try! MP4Tag.writingBPM(174, into: after) else {
        check(false, "the second value was not written"); return
    }
    check(changed.count == after.count, "replacing a tempo does not change the length")
    check(MP4Tag.readBPM(changed) == 174, "and it reads back as 174")
    check([readBE32(changed, chunksAt), readBE32(changed, chunksAt + 4)] == chunksAfter, "no offset moved")

    // A file that already carries one goes down the same path from the start.
    let carried = syntheticMP4(tempo: 90)
    check(MP4Tag.readBPM(carried) == 90, "the built-in tempo reads back")
    let raised = try! MP4Tag.writingBPM(91, into: carried)!
    check(raised.count == carried.count && MP4Tag.readBPM(raised) == 91, "raised in place")
}

/// AVFoundation's own reading of the tag, so that a check is not the writer
/// agreeing with itself. Run off the main thread: this harness is on it.
func metadataBPM(_ url: URL) -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: String?
    Task.detached {
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.metadata) {
            for item in items {
                guard item.identifier == .iTunesMetadataBeatsPerMin
                        || item.identifier == .id3MetadataBeatsPerMinute else { continue }
                if let text = try? await item.load(.stringValue) { result = text }
            }
        }
        semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + 20) == .success ? result : "timed out"
}

section("tags in real files: the BPM arrives, the audio does not change") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ultramix-tags-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Two seconds of a tone, as a WAV, as an M4A, and as an MP3.
    let frames = Int(AudioFrames.sampleRate) * 2
    var left = [Float](repeating: 0, count: frames)
    for i in 0..<frames { left[i] = 0.4 * Float(sin(2 * Double.pi * 440 * Double(i) / AudioFrames.sampleRate)) }
    let wav = directory.appendingPathComponent("tone.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: AudioFrames.sampleRate, channels: 2)!
    // In its own scope: an AVAudioFile finishes its header when it goes away,
    // and afconvert would otherwise be handed an empty file.
    do {
        let file = try! AVAudioFile(forWriting: wav, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            left.withUnsafeBufferPointer {
                buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: frames)
            }
        }
        try! file.write(from: buffer)
    }
    check(readBack(wav).frames == frames, "the tone is written: \(readBack(wav).frames) frames")

    let m4a = directory.appendingPathComponent("tone.m4a")
    let convert = Process()
    convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    convert.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
    try! convert.run()
    convert.waitUntilExit()
    check(convert.terminationStatus == 0, "afconvert made an M4A")

    let mp3 = directory.appendingPathComponent("tone.mp3")
    let encoder = try! MP3Encoder(url: mp3)
    try! left.withUnsafeBufferPointer { p in
        try encoder.write(left: p.baseAddress!, right: p.baseAddress!, count: frames)
    }
    try! encoder.finish()

    for (url, expected, reads) in [(m4a, "125", "125"), (mp3, "124.50", "124.50")] {
        let name = url.lastPathComponent
        let audioBefore = readBack(url)
        let sizeBefore = (try? Data(contentsOf: url).count) ?? 0
        check(try! TagWriter.writeBPM(124.5, to: url) == .written, "\(name): written")
        check(TagWriter.readBPM(url) == expected, "\(name): reads back \(TagWriter.readBPM(url) ?? "nothing")")
        let fromAVFoundation = metadataBPM(url)
        check(fromAVFoundation == reads, "\(name): AVFoundation reads \(fromAVFoundation ?? "nothing")")
        let audioAfter = readBack(url)
        check(audioAfter.frames == audioBefore.frames && audioAfter.left == audioBefore.left,
              "\(name): the audio decodes exactly as before (\(audioBefore.frames) → \(audioAfter.frames) frames)")
        print("     \(name): \(sizeBefore) → \((try? Data(contentsOf: url).count) ?? 0) bytes, BPM \(fromAVFoundation ?? "-")")
        check(try! TagWriter.writeBPM(124.5, to: url) == .unchanged, "\(name): the same value again writes nothing")
        check(try! TagWriter.writeBPM(128, to: url) == .written, "\(name): a new value is written")
        check(readBack(url).left == audioBefore.left, "\(name): and the audio is still untouched")
    }

    check(try! TagWriter.writeBPM(124.5, to: wav) == .unsupported("WAV takes no BPM tag"),
          "a WAV is refused: \(try! TagWriter.writeBPM(124.5, to: wav))")
    check(readBack(wav).left == left, "and left alone")
}

section("ID3: foreign frames survive, versions and padding are kept") {
    // A hand-built v2.3 tag: a foreign frame, a TBPM to overwrite, padding.
    func frame(_ id: String, _ body: [UInt8], synchsafe: Bool = false) -> [UInt8] {
        let size = synchsafe
            ? [UInt8((body.count >> 21) & 0x7F), UInt8((body.count >> 14) & 0x7F),
               UInt8((body.count >> 7) & 0x7F), UInt8(body.count & 0x7F)]
            : beU32(body.count)
        return Array(id.utf8) + size + [0, 0] + body
    }
    func tag(version: UInt8, frames: [UInt8], padding: Int) -> Data {
        let length = frames.count + padding
        let header: [UInt8] = [0x49, 0x44, 0x33, version, 0, 0,
                               UInt8((length >> 21) & 0x7F), UInt8((length >> 14) & 0x7F),
                               UInt8((length >> 7) & 0x7F), UInt8(length & 0x7F)]
        return Data(header + frames + [UInt8](repeating: 0, count: padding) + Array("AUDIOAUDIO".utf8))
    }

    let foreign = frame("GEOB", [0, 1, 2, 3, 250, 251])      // what a DJ program stores
    let original = tag(version: 3, frames: foreign + frame("TBPM", [0] + Array("100".utf8)), padding: 64)
    let written = try! ID3Tag.writingBPM("124.50", into: original)!
    check(ID3Tag.readBPM(written) == "124.50", "the new tempo is in: \(ID3Tag.readBPM(written) ?? "nothing")")
    check(written.count == original.count, "the tag keeps its length, the padding absorbs the change")
    check(written.range(of: Data(foreign)) != nil, "the foreign frame came through byte for byte")
    check(written.suffix(10) == Data("AUDIOAUDIO".utf8), "the audio behind the tag is untouched")
    check(try! ID3Tag.writingBPM("124.50", into: written) == nil, "the same value again is no write")

    // v2.4 frame sizes are synchsafe; a value over 127 bytes tells them apart.
    let long = frame("COMM", [UInt8](repeating: 65, count: 200), synchsafe: true)
    let v4 = tag(version: 4, frames: long, padding: 0)
    let v4Written = try! ID3Tag.writingBPM("128.00", into: v4)!
    check(v4Written[3] == 4, "still v2.4")
    check(ID3Tag.readBPM(v4Written) == "128.00", "v2.4 reads back")
    check(v4Written.range(of: Data(long)) != nil, "the long frame kept its synchsafe length")

    // A tag this code will not edit, and one that is not there at all.
    let v2 = tag(version: 2, frames: [], padding: 0)
    var refused = false
    do { _ = try ID3Tag.writingBPM("124.50", into: v2) } catch { refused = true }
    check(refused, "ID3v2.2 is refused rather than half-converted")
    let bare = Data("AUDIOAUDIO".utf8)
    let tagged = try! ID3Tag.writingBPM("124.50", into: bare)!
    check(tagged.prefix(3) == Data("ID3".utf8) && tagged.suffix(10) == bare, "a tag is put in front of untagged audio")
    check(ID3Tag.readBPM(tagged) == "124.50", "and reads back")
}

// MARK: - Library BPM filter

section("library BPM filter: inclusive at the shown precision, bounds never cross") {
    var filter = BPMFilter(lower: 122, upper: 125)
    check(filter.matches(90) && filter.matches(nil), "off lists everything, unanalysed included")
    filter.isOn = true
    check(filter.matches(122) && filter.matches(125), "both bounds are included")
    check(filter.matches(125.004), "125.004 prints as 125.00 and is in")
    check(!filter.matches(125.006), "125.006 prints as 125.01 and is out")
    check(!filter.matches(121.99) && !filter.matches(nil), "below the range, and no tempo, are out")

    filter.setLower(127)
    check(filter.lower == 127 && filter.upper == 127, "a lower bound past the upper takes it along: \(filter.lower)…\(filter.upper)")
    filter.setUpper(120)
    check(filter.lower == 120 && filter.upper == 120, "and the other way round: \(filter.lower)…\(filter.upper)")
    filter.setUpper(1000)
    check(filter.upper == TempoMap.bpmRange.upperBound, "clamped to the tempo map")
    check(BPMFilter(lower: 130, upper: 120).upper == 130, "an init with crossed bounds is straightened")

    check(BPMFilter.stepped(122.5, by: 1) == 123 && BPMFilter.stepped(122.5, by: -1) == 122, "a step lands on a whole BPM")
    check(BPMFilter.stepped(122, by: 1) == 123 && BPMFilter.stepped(122, by: -1) == 121, "from a whole BPM it moves one")
    check(BPMFilter.stepped(40, by: -1) == 40, "a step stops at the range")
    check(BPMFilter.format(124) == "124" && BPMFilter.format(124.5) == "124.50", "formats \(BPMFilter.format(124)), \(BPMFilter.format(124.5))")
}

section("library BPM filter: half and double tempo, and around a track") {
    var filter = BPMFilter(lower: 122, upper: 125, isOn: true)
    check(!filter.matches(62) && !filter.matches(248), "without the option, octaves are out")
    filter.includesOctaves = true
    check(filter.matches(62) && filter.matches(248) && filter.matches(124), "62 and 248 are in as double and half, 124 still is")
    check(filter.matches(62.502) && !filter.matches(62.503), "an octave is compared at the shown precision: 125.004 in, 125.006 out")
    check(!filter.matches(90) && !filter.matches(nil), "other tempos and no tempo stay out")
    filter.isOn = false
    check(filter.matches(90), "off still lists everything")

    var around = BPMFilter()
    around.centre(on: 124.3)
    check(near(around.lower, 122.3, 1e-9) && near(around.upper, 126.3, 1e-9), "±2 about 124.3: \(around.lower)…\(around.upper)")
    check(BPMFilter.format(around.lower) == "122.30", "a centred bound keeps its decimals: \(BPMFilter.format(around.lower))")
    around.centre(on: 41)
    check(around.lower == 40 && around.upper == 43, "centring near the edge clamps only that side: \(around.lower)…\(around.upper)")
}

// MARK: - Beat This!

/// The model compiled once into the temporary directory. The app ships it
/// compiled by Xcode; here the .mlpackage in Resources is compiled at run
/// time, so the harness needs no build product.
func beatThisModel() -> BeatThisModel? {
    let package = URL(fileURLWithPath: "Ultramix/Resources/BeatThis_small0.mlpackage")
    let cached = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BeatThis_small0.mlmodelc")
    let files = FileManager.default
    do {
        if !files.fileExists(atPath: cached.path) {
            // Core ML compiles into the temporary directory itself, which is
            // where this keeps it; only a compile landing elsewhere is moved.
            let compiled = try MLModel.compileModel(at: package)
            if compiled.standardizedFileURL != cached.standardizedFileURL {
                try files.moveItem(at: compiled, to: cached)
            }
        }
        return try BeatThisModel(compiledURL: cached)
    } catch {
        check(false, "the Beat This! model could not be compiled: \(error)")
        return nil
    }
}

section("beat this: 44.1 kHz halves to 22.05 kHz without delay") {
    let sine = (0..<44_100).map { Float(sin(2 * .pi * 1000 * Double($0) / AudioFrames.sampleRate)) }
    let halved = BeatThisAnalyzer.downsample(sine)
    check(halved.count == 22_050, "22 050 samples out of 44 100: \(halved.count)")
    // The filter is symmetric and its delay is compensated, so output n is
    // input 2n - anything else would move every beat the network reports.
    var worst: Float = 0
    for i in 200..<(halved.count - 200) { worst = max(worst, abs(halved[i] - sine[2 * i])) }
    check(worst < 1e-5, "a 1 kHz sine survives sample for sample (worst \(worst))")

    let above = (0..<44_100).map { Float(sin(2 * .pi * 12_500 * Double($0) / AudioFrames.sampleRate)) }
    let folded = BeatThisAnalyzer.downsample(above)
    let leak = folded[300..<(folded.count - 300)].map { abs($0) }.max()!
    check(leak < 1e-4, "12.5 kHz, which would fold back to 9.5 kHz, is gone (\(leak))")
}

section("beat this: the log-mel input the network was trained on") {
    check(near(BeatThisAnalyzer.melFromHz(1000), 15, 1e-9)
          && near(BeatThisAnalyzer.hzFromMel(15), 1000, 1e-6),
          "Slaney's scale breaks at 1 kHz = 15 mel")
    check(near(BeatThisAnalyzer.melFromHz(300), 4.5, 1e-9), "below that it is linear, 200/3 Hz per mel")
    check(near(BeatThisAnalyzer.hzFromMel(BeatThisAnalyzer.melFromHz(6400)), 6400, 1e-3),
          "and round-trips above it")

    // Triangles that meet at their neighbours' centres sum to one wherever
    // two of them overlap - a filterbank scaled per band (torchaudio's
    // "slaney" norm, which beat_this does not use) would not.
    let bank = BeatThisAnalyzer.melFilterbank
    let bands = BeatThisAnalyzer.bands
    var worst = 0.0
    for k in 0..<BeatThisAnalyzer.bins {
        let hz = Double(k) * 11_025 / Double(BeatThisAnalyzer.bins - 1)
        guard hz > 60, hz < 10_000 else { continue }
        let sum = (0..<bands).reduce(0.0) { $0 + Double(bank[k * bands + $1]) }
        worst = max(worst, abs(sum - 1))
    }
    check(worst < 1e-5, "the bands overlap to exactly one (worst \(worst))")

    // One frame against a DFT written out by hand: this pins the window,
    // the 1/√1024 of torch.stft(normalized="frame_length"), the filterbank
    // and the log together. Anything else here feeds the network a
    // spectrum it was not trained on, and it cannot say so.
    let samples = (0..<22_050).map { i -> Float in
        let t = Double(i) / BeatThisAnalyzer.sampleRate
        return Float(0.5 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 1830 * t + 0.4))
    }
    let spectrum = BeatThisAnalyzer.melSpectrogram(samples)
    check(spectrum.frames == 1 + 22_050 / 441, "50 frames a second: \(spectrum.frames)")
    let frame = 20
    let size = BeatThisAnalyzer.fftSize
    var magnitudes = [Double](repeating: 0, count: BeatThisAnalyzer.bins)
    for k in 0..<BeatThisAnalyzer.bins {
        var re = 0.0, im = 0.0
        for n in 0..<size {
            // Frame 20 is centred on sample 20 · 441, so it starts 512 earlier.
            let index = frame * BeatThisAnalyzer.hop - size / 2 + n
            let value = Double(samples[index]) * (0.5 - 0.5 * cos(2 * .pi * Double(n) / Double(size)))
            re += value * cos(-2 * .pi * Double(k * n) / Double(size))
            im += value * sin(-2 * .pi * Double(k * n) / Double(size))
        }
        magnitudes[k] = (re * re + im * im).squareRoot() / Double(size).squareRoot()
    }
    var difference = 0.0
    for band in [0, 17, 60, 100, 127] {
        var sum = 0.0
        for k in 0..<BeatThisAnalyzer.bins { sum += magnitudes[k] * Double(bank[k * bands + band]) }
        difference = max(difference, abs(log1p(1000 * sum) - Double(spectrum.values[frame * bands + band])))
    }
    check(difference < 2e-3, "a frame matches a hand-written DFT to \(difference)")

    // Centring: an impulse at sample 4410 must be loudest in frame 10.
    var click = [Float](repeating: 0, count: 22_050)
    click[4410] = 1
    let clicked = BeatThisAnalyzer.melSpectrogram(click)
    let energy = (0..<clicked.frames).map { t in (0..<bands).reduce(0.0) { $0 + Double(clicked.values[t * bands + $1]) } }
    check(energy.indices.max { energy[$0] < energy[$1] } == 10, "frame t is centred on sample t · 441")
}

section("beat this: chunks, peaks and the bar vote") {
    // beat_this splits a piece into 1500-frame chunks, drops 6 frames at
    // each seam and moves the last chunk back so it ends with the track.
    check(BeatThisAnalyzer.chunkStarts(frames: 1200) == [-6], "one short chunk starts before the track")
    let starts = BeatThisAnalyzer.chunkStarts(frames: 3000)
    check(starts.first == -6 && starts.last == 3000 - 1494, "three chunks over 3000 frames: \(starts)")
    var covered = [Bool](repeating: false, count: 3000)
    for start in starts {
        for i in 6..<1494 where start + i >= 0 && start + i < 3000 { covered[start + i] = true }
    }
    check(!covered.contains(false), "and every frame is inside one of them")

    // A beat is a positive logit that is the largest within ±3 frames;
    // two frames side by side are one beat, at their mean.
    var logits = [Float](repeating: -5, count: 60)
    logits[10] = 2                      // a peak
    logits[20] = 3; logits[21] = 3      // two frames of the same peak
    logits[30] = 1; logits[32] = 2      // 32 wins, 30 is inside its window
    logits[50] = -0.5                   // a maximum, but not positive
    check(BeatThisAnalyzer.peaks(logits) == [10, 20.5, 32], "peaks: \(BeatThisAnalyzer.peaks(logits))")

    // Bar one: the network's downbeats vote on the place in the bar, and
    // the analyser moves the groove start onto it - but only on a clear
    // majority, and never further than two beats.
    let grid = TempoAnalyzer.Grid(period: 0.5, phase: 0.25)
    let bars = (0..<12).map { 0.25 + Double($0 * 4 + 1) * 0.5 }   // every bar on beat two
    let moved = BeatThisAnalyzer.barOne(grid: grid, groove: 0.25, downbeats: bars)
    check(moved.map { near($0.time, 0.75, 1e-9) && $0.agreement == 1 } == true,
          "twelve downbeats on beat two move bar one there: \(String(describing: moved))")
    let split = (0..<12).map { 0.25 + Double($0 * 2) * 0.5 }      // every other beat: 0 and 2 tie
    check(BeatThisAnalyzer.barOne(grid: grid, groove: 0.25, downbeats: split) == nil,
          "a split vote is no answer")
    check(BeatThisAnalyzer.barOne(grid: grid, groove: 0.25, downbeats: Array(bars.prefix(6))) == nil,
          "and neither are six downbeats")
}

section("beat this: the network on the synthetic tracks") {
    guard let model = beatThisModel() else { return }
    let cases: [(bpm: Double, downbeat: Double, bars: Int)] = [(124.5, 0.731, 64), (90, 3.217, 48), (174, 5.05, 96)]
    for (index, fixture) in cases.enumerated() {
        let audio = synthesizeTrack(bpm: fixture.bpm, downbeat: fixture.downbeat, bars: fixture.bars, seed: UInt64(index + 1))
        let started = Date()
        guard let result = try? BeatThisAnalyzer.analyze(audio, model: model) else {
            check(false, "\(fixture.bpm) BPM: no result")
            continue
        }
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "     %.1f BPM → %.3f, bar one %+.2f ms, confidence %.2f, %.2f s",
                     fixture.bpm, result.bpm, (result.firstBeatSeconds - fixture.downbeat) * 1000,
                     result.confidence, elapsed))
        check(abs(result.bpm - fixture.bpm) <= 0.01, "\(fixture.bpm): got \(result.bpm) BPM")
        check(abs(result.firstBeatSeconds - fixture.downbeat) <= 0.005,
              "\(fixture.bpm): bar one off by \((result.firstBeatSeconds - fixture.downbeat) * 1000) ms")
        check(result.analyser == .beatThis, "the analysis says which analyser made it")
    }
    // The 174 BPM fixture - a kick on every beat, hats between - is the one
    // the kick fit alone reads as 87: the same signal is a kick on every
    // eighth at half the tempo. This is what choosing Beat This! buys.
    let audio = synthesizeTrack(bpm: 174, downbeat: 5.05, bars: 96, seed: 3)
    let alone = try? TempoAnalyzer.analyze(audio)
    check(alone.map { abs($0.bpm - 87) <= 0.01 } == true,
          "for the record, the Ultramix analyser reads it as \(alone?.bpm ?? 0)")
}

section("beat this: which analyser a track keeps") {
    let fresh = UserDefaults(suiteName: "ultramix.verification.beatAlgorithm")!
    fresh.removeObject(forKey: BeatAlgorithm.storageKey)
    check(BeatAlgorithm.stored(in: fresh) == .beatThis, "a Mac that was never told analyses with Beat This!")
    fresh.set("ultramix", forKey: BeatAlgorithm.storageKey)
    check(BeatAlgorithm.stored(in: fresh) == .ultramix, "and follows the setting once it is there")
    fresh.removeObject(forKey: BeatAlgorithm.storageKey)

    let json = """
    {"bpm":124,"firstBeatSeconds":0.5,"confidence":0.8,"version":3}
    """.data(using: .utf8)!
    let old = try! JSONDecoder().decode(TrackAnalysis.self, from: json)
    check(old.analyser == .ultramix && !old.isOutdated, "a library from before the choice reads as Ultramix's own")

    let beatThis = TrackAnalysis(bpm: 124, firstBeatSeconds: 0.5, confidence: 0.8,
                                 version: BeatThisAnalyzer.version, algorithm: .beatThis)
    let encoded = try! JSONEncoder().encode(beatThis)
    check(try! JSONDecoder().decode(TrackAnalysis.self, from: encoded) == beatThis, "and a Beat This! analysis round-trips")
    check(!String(data: try! JSONEncoder().encode(old), encoding: .utf8)!.contains("algorithm"),
          "Ultramix's own analysis writes no algorithm key, so the file format did not change")
    check(!beatThis.isOutdated, "a Beat This! analysis is measured against Beat This!'s version, not the other's")
    check(TrackAnalysis(bpm: 124, firstBeatSeconds: 0.5, confidence: 0.8, version: 0, algorithm: .beatThis).isOutdated,
          "an older Beat This! version is analysed again")
}

// MARK: - Live

/// Three copies of the engine track chained with beatmixes, the second and
/// third at tempos of their own with a ramp into the third: enough tempo
/// history that a rebase which lost any of it would show.
func liveChain() -> (MixDocument, GridLookup, [UUID]) {
    let tracks = [UUID(), UUID(), UUID()]
    let grid = SourceGrid(bpm: 124.5, firstBeatSeconds: 0.731, durationSeconds: engineTrack.duration)
    let lookup: GridLookup = { tracks.contains($0) ? grid : nil }
    var doc = MixDocument()
    var ids: [UUID] = []
    for track in tracks { ids.append(try! doc.addClip(trackID: track, grid: grid, beatmix: .beats32, grids: lookup)) }
    doc.setTargetBPM(ids[1], 127)
    doc.setTargetBPM(ids[2], 121)
    doc.setRampStart(ids[2], to: Double(doc.clips[2].tempoAnchorBeat - 24))
    return (doc, lookup, tracks)
}

func renderMix(_ plan: RenderPlan, from: Int, count: Int, blocks: Int = 512) -> [Float] {
    let renderer = MixRenderer()
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    var done = 0
    while done < count {
        let n = min(blocks, count - done)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(plan: plan, laneMask: 0b111, from: from + done, count: n,
                                left: l.baseAddress! + done, right: r.baseAddress! + done)
            }
        }
        done += n
    }
    return left + right
}

/// FNV-1a over the samples' bits: a change anywhere changes it.
func checksum(_ samples: [Float]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for sample in samples {
        hash ^= UInt64(sample.bitPattern)
        hash = hash &* 0x100_0000_01b3
    }
    return hash
}

section("live: the mix renders exactly as before live mode existed") {
    let (doc, lookup, _) = liveChain()
    let plan = RenderPlan(document: doc, grids: lookup, audio: { _ in engineTrack }, generation: 0)
    // Measured before any live code was written: the mix path must not
    // have moved by a single bit.
    let sum = checksum(renderMix(plan, from: 0, count: plan.endFrame))
    check(plan.endFrame == 9_214_273, "length \(plan.endFrame)")
    check(sum == 0xbd7f_db51_2d83_c885, "checksum \(String(sum, radix: 16))")
}

section("live: a tempo map with an origin") {
    let plain = TempoMap(projectBPM: 120, targets: [TempoPoint(beat: 16, bpm: 126, rampStart: 8)])
    let moved = TempoMap(projectBPM: 120, targets: [TempoPoint(beat: 16, bpm: 126, rampStart: 8)], originSeconds: 1000.25)
    check(moved.seconds(atBeat: 0) == 1000.25, "beat 0 plays at the origin")
    check(near(moved.seconds(atBeat: 4), 1002.25, 1e-12), "4 beats at 120 are 2 s after it")
    for beat in stride(from: -2.0, through: 40, by: 0.37) {
        check(near(moved.seconds(atBeat: beat) - 1000.25, plain.seconds(atBeat: beat), 1e-9), "shifted at \(beat)")
        check(near(moved.beat(atSeconds: moved.seconds(atBeat: beat)), beat, 1e-9), "round trip at \(beat)")
    }
}

/// The oldest clip's end plus the bar of grace: where it is let go of.
func liveLetGo(_ doc: MixDocument, _ lookup: GridLookup) -> Double {
    doc.clips.compactMap { doc.geometry($0, lookup)?.end }.min()! + LiveSet.keepBeats
}

section("live: letting go keeps the tempo map, beat for beat") {
    var cases = 0
    for rampOffset in [nil, -8, -24, -40, -64, -96] as [Int?] {
        var (doc, lookup, _) = liveChain()
        let third = doc.clips[2].id
        if let rampOffset { doc.setRampStart(third, to: Double(doc.clips[2].tempoAnchorBeat + rampOffset)) } else { doc.removeRampStart(third) }
        let playhead = liveLetGo(doc, lookup)
        check(LiveSet.pruned(doc, playhead: playhead - 0.01, playing: true, grids: lookup) == .unchanged,
              "the first clip stays until a bar after its end")
        guard case .rebased(let next, let shift) = LiveSet.pruned(doc, playhead: playhead, playing: true, grids: lookup) else {
            check(false, "nothing let go of at ramp \(String(describing: rampOffset))"); continue
        }
        cases += 1
        check(next.clips.count == 2 && !next.clips.contains { $0.id == doc.clips[0].id }, "the first clip went")
        check(shift > 0 && shift % Clip.beatsPerBar == 0, "shift \(shift) is whole bars")
        check(Double(shift) <= playhead, "and not past the playhead")
        check(next.clips.allSatisfy { next.geometry($0, lookup)!.start >= 0 && $0.tempoAnchorBeat >= 0 },
              "nothing lands before beat 0")
        let old = doc.tempoMap(lookup)
        let new = next.tempoMap(lookup)
        var worst = 0.0
        for beat in stride(from: 0.0, through: next.endBeat(lookup) + 8, by: 0.25) {
            worst = max(worst, abs(new.seconds(atBeat: beat) - old.seconds(atBeat: beat + Double(shift))))
            check(new.bpm(atBeat: beat) == old.bpm(atBeat: beat + Double(shift)), "tempo at \(beat)")
        }
        check(worst < 1e-9, "clock differs by \(worst) s")
        let clock = old.seconds(atBeat: playhead)
        check(near(new.beat(atSeconds: clock) + Double(shift), playhead, 1e-9), "the playhead reads the same beat")
    }
    check(cases == 6, "every ramp case rebased: \(cases)")
}

section("live: the rebased plan plays what the old one would have") {
    let (doc, lookup, _) = liveChain()
    let playhead = liveLetGo(doc, lookup)
    guard case .rebased(let next, _) = LiveSet.pruned(doc, playhead: playhead, playing: true, grids: lookup) else {
        check(false, "nothing let go of"); return
    }
    let oldPlan = RenderPlan(document: doc, grids: lookup, audio: { _ in engineTrack }, generation: 0)
    let newPlan = RenderPlan(document: next, grids: lookup, audio: { _ in engineTrack }, generation: 1)
    check(newPlan.endFrame == oldPlan.endFrame, "the end stays at frame \(oldPlan.endFrame): \(newPlan.endFrame)")
    // From the moment of letting go to the end of the set.
    let from = Int((doc.tempoMap(lookup).seconds(atBeat: playhead) * AudioFrames.sampleRate).rounded())
    let count = oldPlan.endFrame - from
    let a = renderMix(oldPlan, from: from, count: count)
    let b = renderMix(newPlan, from: from, count: count)
    var worst: Float = 0
    var differing = 0
    for i in a.indices where a[i] != b[i] {
        differing += 1
        worst = max(worst, abs(a[i] - b[i]))
    }
    let dB = worst > 0 ? 20 * log10(Double(worst)) : -Double.infinity
    print("     \(count) frames after letting go: \(differing) samples differ, worst \(dB) dBFS")
    check(b.contains { $0 != 0 }, "something was rendered")
    check(dB < -120, "worst difference \(dB) dBFS")
}

section("live: what is let go of, and when") {
    let (doc, lookup, _) = liveChain()
    let end = doc.endBeat(lookup)
    // Stopped a second after the end - short of the bar of grace.
    if case .emptied(let empty) = LiveSet.pruned(doc, playhead: end + 2, playing: false, grids: lookup) {
        check(empty.clips.isEmpty && empty.timeOrigin == 0, "stopped after the end: the set starts over")
        check(empty.lanes == doc.lanes, "the lanes keep their colours")
    } else { check(false, "stopped after the end did not empty the set") }
    check(LiveSet.pruned(doc, playhead: end + 2, playing: true, grids: lookup) != .unchanged,
          "playing past every clip's end lets go of the ones a bar behind")
    check(LiveSet.pruned(MixDocument(), playhead: 50, playing: true, grids: lookup) == .unchanged, "an empty set stays")

    // A played clip whose tempo point was dragged past the next clip's
    // start still shapes the tempo there: it is kept until that is over.
    var dragged = doc
    dragged.clips[0].tempoAnchorBeat = Int(dragged.geometry(dragged.clips[1], lookup)!.start) + 8
    check(LiveSet.pruned(dragged, playhead: liveLetGo(dragged, lookup), playing: true, grids: lookup) == .unchanged,
          "a tempo point after the rebase beat holds the clip")
}

section("live: the first track goes in at the playhead of an empty set") {
    let track = UUID()
    let grid = SourceGrid(bpm: 126, firstBeatSeconds: 0.5, durationSeconds: 60)
    let lookup: GridLookup = { $0 == track ? grid : nil }
    var empty = MixDocument()
    let id = try? empty.insertClip(trackID: track, grid: grid, beatmix: .beats16, atBeat: 0, grids: lookup)
    check(id != nil && empty.clips.count == 1, "the first track is added")
    var plain = MixDocument()
    try! plain.addClip(trackID: track, grid: grid, grids: lookup)
    check(empty.clips.first?.anchorBeat == plain.clips.first?.anchorBeat && empty.projectBPM == 126,
          "as the first track always is: at the start, setting the tempo")
    check(empty.clips.first?.automation == ClipAutomation(), "with no points")
    var second = empty
    check((try? second.insertClip(trackID: track, grid: grid, beatmix: .beats16, atBeat: 5000, grids: lookup)) == nil,
          "with a clip in the mix, nothing at the playhead still refuses")
}

section("live: an empty lane goes to the bottom at once") {
    let (doc, lookup, _) = liveChain()
    check(doc.clips.map(\.lane) == [0, 1, 2], "the chain fills A, B, C in turn")
    let start = [0, 1, 2]
    func order(_ from: [Int], _ a: MixDocument, _ b: MixDocument) -> [Int] { LiveSet.compacted(from, before: a, after: b) }
    check(order(start, doc, doc) == start, "three taken lanes stay where they are")
    check(order(start, MixDocument(), MixDocument()) == start, "an empty set shows A, B, C")

    // A is let go of: it drops, B and C move up.
    guard case .rebased(let full, _) = LiveSet.pruned(doc, playhead: liveLetGo(doc, lookup), playing: true, grids: lookup) else {
        check(false, "nothing let go of"); return
    }
    check(order(start, doc, full) == [1, 2, 0], "the played lane drops, B and C move up")

    // Two clips, C free: A goes to the very bottom, below C.
    var pair = doc
    pair.clips.removeLast()
    check(order(start, doc, pair) == start, "C, just emptied, is already at the bottom")
    guard case .rebased(let one, _) = LiveSet.pruned(pair, playhead: liveLetGo(pair, lookup), playing: true, grids: lookup) else {
        check(false, "nothing let go of with two clips"); return
    }
    let moved = order(start, pair, one)
    check(moved == [1, 2, 0], "A drops below C, which was empty first: \(moved)")

    // The next beatmix goes to C, the row right under B: nothing moves.
    var refilled = one
    let track = doc.clips[2].trackID
    let added = try! refilled.addClip(trackID: track, grid: lookup(track)!, beatmix: .beats32, grids: lookup)
    check(refilled.clips.first { $0.id == added }?.lane == 2, "the next track goes to C")
    check(order(moved, one, refilled) == moved, "adding it moves no row")

    // A deleted clip empties its lane just the same.
    var deleted = doc
    deleted.clips.remove(at: 1)
    check(order(start, doc, deleted) == [0, 2, 1], "a deleted clip's lane drops too")
}

section("play mark: the lanes heard at the playhead") {
    let (doc, lookup, _) = liveChain()
    let first = doc.geometry(doc.clips[0], lookup)!
    let second = doc.geometry(doc.clips[1], lookup)!
    check(doc.soundingLanes(atBeat: first.start + 1, grids: lookup, laneMask: 0b111) == [0], "A alone at the start")
    check(doc.soundingLanes(atBeat: second.start + 1, grids: lookup, laneMask: 0b111) == [0, 1], "A and B in the beatmix")
    check(doc.soundingLanes(atBeat: second.start + 1, grids: lookup, laneMask: 0b110) == [1], "a muted lane is not heard")
    var muted = doc
    muted.clips[1].muted = true
    check(muted.soundingLanes(atBeat: second.start + 1, grids: lookup, laneMask: 0b111) == [0], "nor a muted clip")
    check(doc.soundingLanes(atBeat: -8, grids: lookup, laneMask: 0b111).isEmpty, "nothing before the first clip")
}

/// A live set of one clip at 124 BPM, the playhead halfway through it, and
/// a second track at 128 waiting in the library.
func liveMidTrack() -> (MixDocument, GridLookup, playhead: Double, next: UUID, nextGrid: SourceGrid) {
    let first = UUID(), next = UUID()
    let slow = SourceGrid(bpm: 124, firstBeatSeconds: 0.5, durationSeconds: 200)
    let fast = SourceGrid(bpm: 128, firstBeatSeconds: 0.5, durationSeconds: 200)
    let lookup: GridLookup = { $0 == first ? slow : $0 == next ? fast : nil }
    var doc = MixDocument()
    try! doc.addClip(trackID: first, grid: slow, grids: lookup)
    let shape = doc.geometry(doc.clips[0], lookup)!
    return (doc, lookup, (shape.start + shape.end) / 2, next, fast)
}

section("live: adding while playing leaves the past alone") {
    let (doc, lookup, playhead, next, fast) = liveMidTrack()
    let clock = doc.tempoMap(lookup).seconds(atBeat: playhead)
    let adds: [(String, (inout MixDocument) throws -> Void)] = [
        ("beatmix 32", { _ = try $0.addClip(trackID: next, grid: fast, beatmix: .beats32, grids: lookup) }),
        ("no transition", { _ = try $0.addClip(trackID: next, grid: fast, beatmix: .noTransition, grids: lookup, stepTempo: true) }),
        ("at playhead", { _ = try $0.insertClip(trackID: next, grid: fast, beatmix: .beats16, atBeat: playhead, grids: lookup) }),
    ]
    let oldPlan = RenderPlan(document: doc, grids: lookup, audio: { _ in engineTrack }, generation: 0)
    let upTo = Int((clock * AudioFrames.sampleRate).rounded())
    let before = renderMix(oldPlan, from: 0, count: upTo)
    var report: [String] = []
    for (name, add) in adds {
        var raw = doc
        try! add(&raw)
        let jumped = raw.tempoMap(lookup).beat(atSeconds: clock) - playhead
        let kept = LiveSet.protectPast(raw, old: doc, playhead: playhead)
        let moved = kept.tempoMap(lookup).beat(atSeconds: clock) - playhead
        report.append(String(format: "%@ %+.3f → %+.1e", name, jumped, moved))
        // No Transition steps its own tempo where the new song starts, so
        // it never reached back; the two beatmixes did, by beats.
        if name != "no transition" {
            check(abs(jumped) > 0.5, "\(name): the unprotected add moved the playhead (\(jumped) beats)")
        }
        check(!LiveSet.clockMoved(kept, old: doc, playhead: playhead, grids: lookup), "\(name): protected, the clock stays")
        // Every beat up to the playhead keeps its time, not just the one.
        for beat in stride(from: 0.0, through: playhead, by: 0.5) {
            // To rounding: the longer map sums what the shorter extrapolated.
            check(near(kept.tempoMap(lookup).seconds(atBeat: beat), doc.tempoMap(lookup).seconds(atBeat: beat), 1e-9),
                  "\(name) at \(beat)")
        }
        let plan = RenderPlan(document: kept, grids: lookup, audio: { _ in engineTrack }, generation: 1)
        check(renderMix(plan, from: 0, count: upTo) == before, "\(name): what played renders bit for bit the same")
    }
    print("     playhead moves, unprotected → protected (beats): " + report.joined(separator: ", "))
}

section("live: No Transition steps the tempo where the new song starts") {
    let (doc, lookup, playhead, next, fast) = liveMidTrack()
    var added = doc
    let id = try! added.addClip(trackID: next, grid: fast, beatmix: .noTransition, grids: lookup, stepTempo: true)
    added = LiveSet.protectPast(added, old: doc, playhead: playhead)
    let map = added.tempoMap(lookup)
    let old = doc.clips[0], new = added.clips.first { $0.id == id }!
    let oldEnd = added.geometry(old, lookup)!.end
    let newStart = added.geometry(new, lookup)!.start
    check(newStart >= oldEnd - 1e-9, "no overlap: \(newStart) after \(oldEnd)")
    var drift = 0.0
    for beat in stride(from: 0.0, to: oldEnd - 1, by: 1) { drift = max(drift, abs(map.bpm(atBeat: beat) - 124)) }
    check(drift == 0, "the playing song stays at 124 to its end (off by \(drift))")
    check(map.bpm(atBeat: (newStart + 1e-9).rounded(.up) + 1) == 128, "the new one plays at its own 128")
    var plain = doc
    let p = try! plain.addClip(trackID: next, grid: fast, beatmix: .noTransition, grids: lookup)
    check(plain.clips.first { $0.id == p }!.rampStartBeat == nil, "a mix's No Transition is as it was")
}

section("live: Auto's beatmix 4 - no pause, each song at its own tempo") {
    let (doc, lookup, playhead, next, fast) = liveMidTrack()
    var added = doc
    let id = try! added.addClip(trackID: next, grid: fast, beatmix: LiveSet.autoBeatmix, grids: lookup, stepTempo: true)
    added = LiveSet.protectPast(added, old: doc, playhead: playhead)
    check(!LiveSet.clockMoved(added, old: doc, playhead: playhead, grids: lookup), "the clock stays")
    let map = added.tempoMap(lookup)
    let oldClip = added.clips[0], newClip = added.clips.first { $0.id == id }!
    let oldEnd = MixDocument.soundEnd(oldClip, added.geometry(oldClip, lookup)!, lookup(oldClip.trackID)!)
    let newStart = added.geometry(newClip, lookup)!.start
    check(newStart < oldEnd, "the new track comes in before the old one ends: no pause")
    let start = Double(newClip.anchorBeat)
    // It ends on the last bar line of the old track's sound; the fade-out
    // silences the fraction of a beat after it.
    let lastBar = (oldEnd / 4).rounded(.down) * 4
    check(lastBar - start == 4, "one bar, ending on the old track's last bar line: \(lastBar - start) beats")
    var drift = 0.0
    for beat in stride(from: 0.0, to: start - 1, by: 1) { drift = max(drift, abs(map.bpm(atBeat: beat) - 124)) }
    check(drift == 0, "the playing song keeps 124 up to the beatmix (off by \(drift))")
    check(map.bpm(atBeat: start) == 128, "from the beatmix on, the new song's 128")
    check(!newClip.automation.volume.isEmpty, "with the beatmix's fade-in")
}

section("live: Auto picks the next track") {
    let ids = (0..<6).map { _ in UUID() }
    let noGrid = ids[3]
    func next(_ last: UUID?, _ inSet: Set<UUID>) -> UUID? {
        LiveSet.autoNext(order: ids, lastAdded: last, inSet: inSet, hasGrid: { $0 != noGrid })
    }
    check(next(ids[0], [ids[0]]) == ids[1], "the one after the last added")
    check(next(ids[1], [ids[1], ids[2]]) == nil || next(ids[1], [ids[1], ids[2]]) == ids[4],
          "skips a track in the set and one without a grid")
    check(next(ids[1], [ids[1], ids[2]]) == ids[4], "B, C in the set, D has no grid: E")
    check(next(ids[5], [ids[5]]) == nil, "the end of the list: nothing, no starting over")
    check(next(UUID(), [ids[0]]) == ids[1], "a last track no longer listed: the first one not in the set")
    check(next(nil, []) == ids[0], "nothing added yet: the top of the list")

    let (doc, lookup, playhead, _, _) = liveMidTrack()
    check(LiveSet.needsAuto(doc, playhead: playhead, grids: lookup), "one clip playing, nothing waiting: Auto adds")
    check(!LiveSet.needsAuto(doc, playhead: -10, grids: lookup), "stopped before the clip, it is still waiting")
    check(!LiveSet.needsAuto(MixDocument(), playhead: 0, grids: lookup), "an empty set is left empty")
}

section("live: three clips at most") {
    check(LiveSet.refusal(before: 2, after: 3) == nil, "the third is allowed")
    check(LiveSet.refusal(before: 3, after: 4) != nil, "the fourth is not")
    check(LiveSet.refusal(before: 2, after: 4) != nil, "nor two at once past three")
    check(LiveSet.refusal(before: 3, after: 3) == nil, "editing a full set is allowed")
    check(LiveSet.refusal(before: 3, after: 2) == nil, "and so is deleting")
}

section("live: fifty tracks later, nothing has grown") {
    let track = UUID()
    let grid = SourceGrid(bpm: 124.5, firstBeatSeconds: 0.731, durationSeconds: engineTrack.duration)
    let lookup: GridLookup = { $0 == track ? grid : nil }
    var doc = MixDocument()
    var clock = 0.0
    var largestBeat = 0.0
    var lets = 0
    for n in 0..<50 {
        var next = doc
        let id = try! next.addClip(trackID: track, grid: grid, beatmix: .beats32, grids: lookup)
        next.setTargetBPM(id, [124.5, 127, 121, 125][n % 4])
        check(LiveSet.refusal(before: doc.clips.count, after: next.clips.count) == nil, "track \(n) fits")
        doc = next
        // Once the set is full, play on until the oldest clip is let go of,
        // as the timer would. Before that the playhead waits at the start:
        // a beatmix writes its tempo point behind the end of the mix, and a
        // playhead already past it would see the clock move under it.
        guard doc.clips.count == LiveSet.clipLimit else { continue }
        let playhead = liveLetGo(doc, lookup)
        let before = doc.tempoMap(lookup)
        let seconds = before.seconds(atBeat: playhead)
        check(seconds >= clock, "the clock never runs backwards")
        clock = seconds
        guard case .rebased(let rebased, let shift) = LiveSet.pruned(doc, playhead: playhead, playing: true, grids: lookup) else {
            check(false, "track \(n): nothing let go of"); continue
        }
        lets += 1
        let after = rebased.tempoMap(lookup)
        check(near(after.beat(atSeconds: seconds) + Double(shift), playhead, 1e-9), "track \(n): the playhead did not move")
        doc = rebased
        largestBeat = max(largestBeat, doc.endBeat(lookup))
    }
    print("     \(lets) rebases, largest beat \(Int(largestBeat)), clock \(Int(clock)) s")
    check(doc.clips.count <= LiveSet.clipLimit, "\(doc.clips.count) clips")
    check(lets >= 45, "\(lets) rebases")
    check(largestBeat < 1000, "beats stay small: \(largestBeat)")
    // Fifty 78-second tracks overlapping by 32 beats: about 51 minutes.
    check(clock > 2900, "and the set really ran on: \(clock) s")
}

// MARK: - Audio cache

section("audio cache limit: the audio used longest ago goes first") {
    let gb = 1_000_000_000
    let ids = (0..<5).map { _ in UUID() }
    func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + n * 86_400) }
    // 0 used longest ago, 4 most recently; 1 GB each.
    let entries = ids.enumerated().map { AudioCacheLimit.Entry(id: $1, bytes: gb, lastUse: day(Double($0))) }
    check(AudioCacheLimit.evictions(entries, limit: 5 * gb, keeping: []) == [], "exactly at the limit: nothing goes")
    check(AudioCacheLimit.evictions(entries, limit: 3 * gb, keeping: []) == [ids[0], ids[1]], "two oldest go")
    check(AudioCacheLimit.evictions(entries, limit: 3 * gb - 1, keeping: []) == [ids[0], ids[1], ids[2]],
          "a byte over means one more")
    check(AudioCacheLimit.evictions(entries, limit: 3 * gb, keeping: [ids[0]]) == [ids[1], ids[2]],
          "a pinned track is skipped, the next oldest go instead")
    check(AudioCacheLimit.evictions(entries, limit: 0, keeping: Set(ids)) == [], "all pinned: nothing goes, even over the limit")
    check(AudioCacheLimit.evictions(entries, limit: gb, keeping: [ids[4], ids[3]]) == [ids[0], ids[1], ids[2]],
          "pinned alone exceed the limit: everything else goes")
    // Input order does not matter.
    check(AudioCacheLimit.evictions(entries.reversed(), limit: 3 * gb, keeping: []) == [ids[0], ids[1]], "order of the listing")
    // A big old file can make room alone.
    var mixed = entries
    mixed[0] = AudioCacheLimit.Entry(id: ids[0], bytes: 3 * gb, lastUse: day(0))
    check(AudioCacheLimit.evictions(mixed, limit: 5 * gb, keeping: []) == [ids[0]], "one big file is enough")
    // Settings: unknown values fall back to the default.
    let defaults = UserDefaults(suiteName: "ultramix.verify.cache")!
    defaults.removePersistentDomain(forName: "ultramix.verify.cache")
    check(AudioCacheLimit.current(defaults) == 5 * gb, "default 5 GB")
    defaults.set(20, forKey: AudioCacheLimit.storageKey)
    check(AudioCacheLimit.current(defaults) == 20 * gb, "20 GB chosen")
    defaults.set(7, forKey: AudioCacheLimit.storageKey)
    check(AudioCacheLimit.current(defaults) == 5 * gb, "a value not offered falls back")
    defaults.removePersistentDomain(forName: "ultramix.verify.cache")
}

section("audio cache limit: lifted, nothing is ever given back") {
    let gb = 1_000_000_000
    let defaults = UserDefaults(suiteName: "ultramix.verify.nolimit")!
    defaults.removePersistentDomain(forName: "ultramix.verify.nolimit")
    check(!AudioCacheLimit.isLifted(defaults), "in place unless it is taken away")
    check(AudioCacheLimit.effective(defaults) == AudioCacheLimit.current(defaults),
          "in place: the chosen size applies")
    defaults.set(20, forKey: AudioCacheLimit.storageKey)
    check(AudioCacheLimit.effective(defaults) == 20 * gb, "in place: 20 GB chosen")

    defaults.set(true, forKey: AudioCacheLimit.noLimitKey)
    check(AudioCacheLimit.isLifted(defaults), "lifted when it is chosen")
    check(AudioCacheLimit.effective(defaults) == .max, "lifted: no limit at all")
    // Which is what makes the eviction a no-op, however much is there.
    let entries = (0..<5).map {
        AudioCacheLimit.Entry(id: UUID(), bytes: 100 * gb, lastUse: Date(timeIntervalSince1970: Double($0)))
    }
    check(AudioCacheLimit.evictions(entries, limit: .max, keeping: []) == [], "500 GB and nothing goes")
    check(AudioCacheLimit.current(defaults) == 20 * gb,
          "the chosen size is remembered for when the limit is back")

    defaults.set(false, forKey: AudioCacheLimit.noLimitKey)
    check(AudioCacheLimit.effective(defaults) == 20 * gb, "back in place, at the size that was chosen")
    // 500 GB against 20: even the last one alone is over, so all five go.
    check(AudioCacheLimit.evictions(entries, limit: AudioCacheLimit.effective(defaults), keeping: []).count == 5,
          "and it evicts again, down to nothing when nothing is pinned")
    defaults.removePersistentDomain(forName: "ultramix.verify.nolimit")
}

section("read-ahead: covers every source frame a render reads") {
    // A ramp from 124.5 to 131 on a second clip, and a first clip played at
    // 127: every grain searched, restarts walked cold.
    let (plan, doc, lookup) = singleClipPlan(engineTrack, bpm: 124.5, firstBeat: 0.731, playBPM: 127) { doc in
        let track = doc.clips[0].trackID
        doc.clips.append(Clip(trackID: track, lane: 1, anchorBeat: 160, targetBPM: 131))
    }
    check(plan.segments.count >= 2, "\(plan.segments.count) segments")
    // Audio with everything outside `keep` turned to NaN: a single read
    // outside shows as NaN or as a different splice.
    func spoiled(_ keep: [Range<Int>]) -> AudioFrames {
        var samples = [Float](repeating: .nan, count: engineTrack.frameCount * 2)
        for range in keep {
            for f in range { samples[2 * f] = engineTrack.samples[2 * f]; samples[2 * f + 1] = engineTrack.samples[2 * f + 1] }
        }
        return AudioFrames(interleaved: samples)
    }
    let count = 88_200  // 2 s
    var windows = 0
    var narrowCaught = 0
    for (index, segment) in plan.segments.enumerated() {
        // Mid-grain and between restarts, at the start, and near the end.
        for from in [segment.startFrame, segment.startFrame + 200_000 + Stretcher.hop / 3,
                     (segment.startFrame + segment.endFrame) / 2 + 777, segment.endFrame - count / 2] {
            let spans = ReadAhead.spans(plan, from: from, count: count).filter { $0.audio === engineTrack }
            let spoiledAudio = spoiled(spans.map(\.frames))
            let other = RenderPlan(document: doc, grids: lookup, audio: { _ in spoiledAudio }, generation: 0)
            for memo in [false, true] {
                let reference = renderStretch(plan, segment: index, from: from, count: count, memo: memo)
                let result = renderStretch(other, segment: index, from: from, count: count, memo: memo)
                check(result == reference, "segment \(index) from \(from) memo \(memo): a read outside the spans")
            }
            windows += 1
            // Not vacuous: the tempo map's own positions, without the
            // margins, are not enough.
            let a = max(from, segment.startFrame), b = min(from + count, segment.endFrame)
            let low = Int(segment.nominalSourceFrame(atTimelineFrame: a, tempo: plan.tempo).rounded(.down))
            let high = Int(segment.nominalSourceFrame(atTimelineFrame: b, tempo: plan.tempo).rounded(.up))
            let narrow = spoiled([max(0, low)..<min(engineTrack.frameCount, high)])
            let narrowPlan = RenderPlan(document: doc, grids: lookup, audio: { _ in narrow }, generation: 0)
            if renderStretch(narrowPlan, segment: index, from: from, count: count, memo: false)
                != renderStretch(plan, segment: index, from: from, count: count, memo: false) { narrowCaught += 1 }
        }
    }
    check(windows == 4 * plan.segments.count, "\(windows) windows")
    // Not every window needs the margins (one at the end of a segment
    // reads nothing past the map), but most do - so the check above can
    // catch a span too short.
    print("     without the margins \(narrowCaught) of \(windows) windows render differently")
    check(narrowCaught * 4 >= windows * 3, "without margins the spoiled render differs: \(narrowCaught) of \(windows)")
    // Ten seconds ahead is about 3.5 MB per clip, and nothing outside the
    // window's segments.
    let ahead = ReadAhead.spans(plan, from: plan.segments[0].startFrame, count: ReadAhead.frames)
    check(ahead.count == 1, "\(ahead.count) spans at the start")
    if let span = ahead.first {
        let seconds = Double(span.frames.count) / AudioFrames.sampleRate
        check(seconds > 10 && seconds < 11, "10 s ahead reads \(seconds) s of source at 127/124.5")
    }
    check(ReadAhead.spans(plan, from: plan.endFrame + 100_000, count: ReadAhead.frames).isEmpty, "past the end: nothing")
}

section("read-ahead: prefetch touches a mapped file and leaves it as it was") {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ultramix-prefetch-\(UUID().uuidString).f32")
    defer { try? FileManager.default.removeItem(at: url) }
    let samples = (0..<(200_000 * 2)).map { Float($0 % 1000) / 1000 }
    samples.withUnsafeBytes { try! Data($0).write(to: url) }
    let mapped = try! AudioFrames(mapping: url)
    check(mapped.frameCount == 200_000, "\(mapped.frameCount) frames")
    _ = mapped.prefetch(0..<200_000)
    _ = mapped.prefetch(-50..<10)           // clamped, no crash
    _ = mapped.prefetch(199_990..<500_000)   // past the end, clamped
    _ = mapped.prefetch(10..<10)
    var same = true
    for i in Swift.stride(from: 0, to: samples.count, by: 997) where mapped.samples[i] != samples[i] { same = false }
    check(same, "contents unchanged")
    check(AudioFrames(interleaved: [0, 0]).prefetch(0..<1) == 0, "owned audio: nothing to do")
}

section("import copy: on unless switched off; absolute paths are references") {
    let defaults = UserDefaults(suiteName: "ultramix.verify.importcopy")!
    defaults.removePersistentDomain(forName: "ultramix.verify.importcopy")
    check(ImportCopy.current(defaults), "copies by default")
    defaults.set(false, forKey: ImportCopy.storageKey)
    check(!ImportCopy.current(defaults), "off when switched off")
    defaults.removePersistentDomain(forName: "ultramix.verify.importcopy")
    let copied = Track(path: "Audio/Song.mp3", bookmark: nil, title: "Song", artist: nil, durationSeconds: 0)
    let referred = Track(path: "/Volumes/T7/Musik/Song.mp3", bookmark: Data([1]), title: "Song", artist: nil, durationSeconds: 0)
    check(!copied.isReference && referred.isReference, "a relative path is a copy, an absolute one a reference")
    // The bookmark is the permission to read a reference: it survives the
    // library file.
    let back = try! Track.decodeLibrary(try! Track.encodeLibrary([referred]))
    check(back.first?.bookmark == Data([1]) && back.first?.path == referred.path, "bookmark and path round-trip")
}

section("audio routing: defaults are the old setup; a split only when the pairs differ") {
    let defaults = UserDefaults(suiteName: "ultramix.verify.routing")!
    defaults.removePersistentDomain(forName: "ultramix.verify.routing")
    let fresh = AudioRouting.current(defaults)
    check(fresh == AudioRouting(deviceUID: nil, mainPair: 0, auditionPair: 0), "defaults: system output, 1-2 / 1-2")
    let benq = OutputDevice(id: 47, uid: "benq", name: "BenQ", channels: 2)
    let rig = OutputDevice(id: 90, uid: "rig", name: "AudioFuse 16Rig", channels: 20,
                           channelNames: (1...16).map { "Out \($0)" } + ["Phones 1 L", "Phones 1 R", "Phones 2 L", "Phones 2 R"])
    check(!fresh.isSplit(devices: [benq, rig], systemDefault: benq), "defaults are not split")
    let main = fresh.route(.main, devices: [benq, rig], systemDefault: benq)
    check(main == AudioRouting.Route(device: nil, pair: 0, channels: 2), "defaults route to the system output, 1-2")

    defaults.set("", forKey: AudioRouting.deviceKey)
    check(AudioRouting.current(defaults).deviceUID == nil, "an empty uid is the system output")
    defaults.set("rig", forKey: AudioRouting.deviceKey)
    defaults.set(0, forKey: AudioRouting.mainKey)
    defaults.set(8, forKey: AudioRouting.auditionKey)
    let cue = AudioRouting.current(defaults)
    check(cue.isSplit(devices: [benq, rig], systemDefault: benq), "1-2 and 17-18 on the 16Rig are split")
    let audition = cue.route(.audition, devices: [benq, rig], systemDefault: benq)
    check(audition.device?.uid == "rig" && audition.pair == 8 && audition.channels == 20, "audition on the Rig, pair 8")
    check(!cue.isMissing(in: [benq, rig]), "connected")

    // Unplugged: the system output on 1-2 for both, so not split - the
    // old rules come back - and the choice is kept.
    check(cue.isMissing(in: [benq]), "missing when unplugged")
    check(cue.route(.audition, devices: [benq], systemDefault: benq) == AudioRouting.Route(device: nil, pair: 0, channels: 2),
          "unplugged: audition falls back to the system output, 1-2")
    check(!cue.isSplit(devices: [benq], systemDefault: benq), "unplugged: not split")
    check(AudioRouting.current(defaults).deviceUID == "rig", "the choice stays stored")
    // No device list at all (no default either): still a stereo pair.
    check(cue.route(.main, devices: [], systemDefault: nil).channels == 2, "nothing known: 2 channels")

    // Same pair chosen twice on the Rig: not split.
    defaults.set(8, forKey: AudioRouting.mainKey)
    check(!AudioRouting.current(defaults).isSplit(devices: [rig], systemDefault: benq), "same pair twice is not split")
    defaults.removePersistentDomain(forName: "ultramix.verify.routing")
}

section("audio routing: pairs, labels and the channel map") {
    check(AudioRouting.pairCount(channels: 2) == 1, "2 channels: 1 pair")
    check(AudioRouting.pairCount(channels: 20) == 10, "20 channels: 10 pairs")
    check(AudioRouting.pairCount(channels: 5) == 2, "odd last channel not offered")
    check(AudioRouting.pairCount(channels: 1) == 1, "mono: one pair")
    check(AudioRouting.channelMap(pair: 0, channels: 2) == [0, 1], "1-2 on a stereo device")
    check(AudioRouting.channelMap(pair: 1, channels: 6) == [-1, -1, 0, 1, -1, -1], "3-4 of 6")
    check(AudioRouting.channelMap(pair: 8, channels: 20) == Array(repeating: -1, count: 16) + [0, 1, -1, -1], "17-18 of 20")
    check(AudioRouting.pairLabel(0, names: []) == "1–2", "no names: numbers")
    check(AudioRouting.pairLabel(0, names: ["", ""]) == "1–2", "empty names: numbers")
    check(AudioRouting.pairLabel(0, names: ["1", "2"]) == "1–2", "plain numbers are not names (Mac mini speakers)")
    check(AudioRouting.pairLabel(1, names: ["a", "b", "Phones 1 L", "Phones 1 R"]) == "3–4 · Phones 1", "L/R folded")
    check(AudioRouting.pairLabel(0, names: ["Main Left", "Main Right"]) == "1–2 · Main", "Left/Right folded")
    check(AudioRouting.pairLabel(0, names: ["Out 1", "Out 2"]) == "1–2 · Out 1 / Out 2", "different names both shown")
    check(AudioRouting.pairLabel(2, names: ["x"]) == "5–6", "names missing for the pair")
}

// MARK: - Lane knobs

section("lane knobs: the parser finds CCs in what a controller sends") {
    var parser = MIDIStreamParser()
    // Running status, Clock between the data bytes, a message split across
    // two packets, and a note that is not a CC.
    var got = parser.feed([0xB0, 21, 10, 22, 0xF8, 20, 0x90, 60])
    got += parser.feed([100, 0xB3, 7])
    got += parser.feed([127, 0xF0, 1, 2, 0xF7, 0xB0, 21])
    let changes = got.compactMap(\.controlChange)
    check(changes == [MIDIControlChange(channel: 1, controller: 21, value: 10),
                      MIDIControlChange(channel: 1, controller: 22, value: 20),
                      MIDIControlChange(channel: 4, controller: 7, value: 127)], "\(changes)")
    check(got.count == 5, "note and SysEx are messages too, not CCs: \(got.count)")
    // The feed ended on B0 21: half a CC, which waits for its value.
    check(parser.feed([5]).compactMap(\.controlChange) == [MIDIControlChange(channel: 1, controller: 21, value: 5)],
          "the value in the next packet completes it")
}

section("lane knobs: neutral does nothing, the ends are where they should be") {
    for function in KnobFunction.allCases {
        let rest = KnobState(function: function, value: function.neutral)
        check(LaneKnobMath.filterPosition(rest) == 0, "\(function) neutral filter")
        let g = LaneKnobMath.gains(rest)
        check(g.left == 1 && g.right == 1, "\(function) neutral gains \(g)")
    }
    check(LaneKnobMath.filterPosition(KnobState(function: .lowPass, value: 0)) == -1, "LPF 0 closes fully")
    check(LaneKnobMath.filterPosition(KnobState(function: .highPass, value: 127)) == 1, "HPF 127 closes fully")
    check(LaneKnobMath.filterPosition(KnobState(function: .lowPass, value: 126)) < 0, "LPF 126 is a filter")
    check(LaneKnobMath.gains(KnobState(function: .volume, value: 0)) == (0, 0), "VOL 0 is silence")
    check(near(LaneKnobMath.gains(KnobState(function: .volume, value: 64)).left, 0.2540, 0.0001), "VOL 64 ≈ −11.9 dB")
    let hardLeft = LaneKnobMath.gains(KnobState(function: .pan, value: 0))
    check(hardLeft.left == 1 && near(hardLeft.right, 0, 1e-15), "PAN 0 is left only \(hardLeft)")
    let hardRight = LaneKnobMath.gains(KnobState(function: .pan, value: 127))
    check(hardRight.right == 1 && near(hardRight.left, 0, 1e-15), "PAN 127 is right only \(hardRight)")
    check(LaneKnobMath.gains(KnobState(function: .pan, value: 200)) == hardRight, "values held to 127")
}

section("lane knobs: six knobs in one word") {
    var knobs: [KnobState] = []
    for slot in 0..<LaneKnobMath.slotCount {
        knobs.append(KnobState(function: KnobFunction.allCases[slot % 4], value: [0, 127, 64, 1, 126, 99][slot]))
    }
    let word = LaneKnobMath.pack(knobs)
    for slot in 0..<LaneKnobMath.slotCount {
        check(LaneKnobMath.unpack(word, slot: slot) == knobs[slot], "slot \(slot)")
    }
    check(LaneKnobMath.slot(lane: 2, knob: 1) == 5, "C2 is the sixth")
}

section("lane knobs: learn, forget, and what is kept") {
    var setup = KnobSetup.standard
    check(setup.slots.map(\.function) == [.lowPass, .highPass, .lowPass, .highPass, .lowPass, .highPass], "defaults")
    let cc21 = MIDIControlChange(channel: 1, controller: 21, value: 90)
    setup.learn(slot: 0, from: cc21)
    check(setup.slots(matching: cc21) == [0], "A1 learned")
    setup.learn(slot: 3, from: cc21)
    check(setup.slots(matching: cc21) == [3], "one CC turns one knob: A1 gave it up")
    check(!setup.slots[0].isAssigned, "A1 is unassigned again")
    check(setup.slots(matching: MIDIControlChange(channel: 2, controller: 21, value: 0)).isEmpty, "another channel is another CC")
    check(setup.slots[3].label == "CC 21 · Ch 1", setup.slots[3].label)
    setup.slots[3].function = .pan

    let defaults = UserDefaults(suiteName: "ultramix.verify.knobs")!
    defaults.removePersistentDomain(forName: "ultramix.verify.knobs")
    check(KnobSetup.load(defaults) == .standard, "nothing stored: the defaults")
    setup.save(defaults)
    check(defaults.data(forKey: KnobSetup.storageKey) != nil, "stored as Data")
    check(KnobSetup.load(defaults) == setup, "round trip")
    defaults.set("{}", forKey: KnobSetup.storageKey)
    check(KnobSetup.load(defaults) == .standard, "a String in its place: the defaults, not a crash")
    setup.forget(slot: 3)
    check(!setup.slots[3].isAssigned && setup.slots[3].function == .pan, "forget keeps the function")
    defaults.removePersistentDomain(forName: "ultramix.verify.knobs")
}

func renderMix(_ plan: RenderPlan, from: Int, count: Int, knobs: LaneKnobValues?, laneMask: Int = 0b111) -> [Float] {
    let renderer = MixRenderer()
    renderer.knobs = knobs
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    var done = 0
    while done < count {
        let n = min(512, count - done)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(plan: plan, laneMask: laneMask, from: from + done, count: n,
                                left: l.baseAddress! + done, right: r.baseAddress! + done)
            }
        }
        done += n
    }
    return left + right
}

section("lane knobs: at rest the mix is bit-identical; turned, they act on their lane") {
    let (doc, lookup, _) = liveChain()
    let plan = RenderPlan(document: doc, grids: lookup, audio: { _ in engineTrack }, generation: 0)
    // Where lanes A and B overlap, so two lanes sound.
    let from = plan.endFrame / 3
    let count = 441_000
    let plain = renderMix(plan, from: from, count: count, knobs: nil)
    check(plain.contains { $0 != 0 }, "the range is not silent")

    func knobs(_ set: (inout [KnobState]) -> Void) -> LaneKnobValues {
        var states = KnobSetup.standard.slots.map { KnobState(function: $0.function, value: $0.function.neutral) }
        set(&states)
        return LaneKnobValues(states)
    }
    let resting = renderMix(plan, from: from, count: count, knobs: knobs { _ in })
    check(resting == plain, "neutral knobs change not one bit")

    // Lane A's volume to 0: after the glide, exactly lanes B and C.
    let silentA = renderMix(plan, from: from, count: count, knobs: knobs {
        $0[0] = KnobState(function: .volume, value: 0)
    })
    let withoutA = renderMix(plan, from: from, count: count, knobs: nil, laneMask: 0b110)
    var worst: Float = 0
    for i in 0..<count where i >= 44_100 {
        worst = max(worst, abs(silentA[i] - withoutA[i]), abs(silentA[count + i] - withoutA[count + i]))
    }
    check(worst < 1e-5, "VOL 0 on A leaves B and C: worst \(worst)")
    check(silentA != plain, "VOL 0 did something")

    // A low-pass at 0 on every lane: far less of the energy is high
    // frequency. Measured as the first difference's share of the energy,
    // so the filter's make-up gain does not count.
    func roughness(_ samples: [Float]) -> Double {
        var diff = 0.0, energy = 0.0
        for i in 44_101..<count {
            let d = Double(samples[i] - samples[i - 1])
            diff += d * d
            energy += Double(samples[i]) * Double(samples[i])
        }
        return diff / energy
    }
    let dark = renderMix(plan, from: from, count: count, knobs: knobs {
        for slot in [0, 2, 4] { $0[slot] = KnobState(function: .lowPass, value: 0) }
    })
    // The synthetic track is a sine kick under noise hats, and the kick
    // lies below the low-pass's 90 Hz: what goes is the hats.
    let ratio = roughness(dark) / roughness(plain)
    check(ratio < 0.2, "LPF 0 removes the highs: \(ratio)")
    print("     LPF 0: high-frequency share \(String(format: "%.4f", ratio))× of the open lane's")

    // A high-pass at 127 on every lane: the kick, nearly all the energy, goes.
    func energy(_ samples: [Float]) -> Double {
        samples[44_100..<count].reduce(0) { $0 + Double($1) * Double($1) }
    }
    let thin = renderMix(plan, from: from, count: count, knobs: knobs {
        for slot in [1, 3, 5] { $0[slot] = KnobState(function: .highPass, value: 127) }
    })
    let kept = energy(thin) / energy(plain)
    check(kept < 0.05, "HPF 127 removes the kick: \(kept)")
    print("     HPF 127: \(String(format: "%.4f", kept))× of the energy kept")

    // Pan hard left on every lane: the right channel falls silent.
    let left = renderMix(plan, from: from, count: count, knobs: knobs {
        for slot in [1, 3, 5] { $0[slot] = KnobState(function: .pan, value: 0) }
    })
    let rightPeak = left[(count + 44_100)...].map(abs).max() ?? 1
    check(rightPeak < 1e-5, "PAN 0 empties the right: \(rightPeak)")
}

section("automation filters: LPF and HPF each on their own, as the knobs") {
    let (doc, lookup, _) = liveChain()
    let from = RenderPlan(document: doc, grids: lookup, audio: { _ in engineTrack }, generation: 0).endFrame / 3
    let count = 441_000
    func rendered(_ kind: AutomationKind?, _ value: Double) -> [Float] {
        var drawn = doc
        if let kind {
            for i in drawn.clips.indices {
                drawn.clips[i].automation.setNodes(kind, [AutomationNode(beat: -1000, value: value)])
            }
        }
        let plan = RenderPlan(document: drawn, grids: lookup, audio: { _ in engineTrack }, generation: 0)
        return renderMix(plan, from: from, count: count, knobs: nil)
    }
    let plain = rendered(nil, 0)
    check(rendered(.lowPass, 1) == plain && rendered(.highPass, 0) == plain,
          "an open low-pass and an off high-pass change not one bit")
    func roughness(_ samples: [Float]) -> Double {
        var diff = 0.0, energy = 0.0
        for i in 44_101..<count {
            let d = Double(samples[i] - samples[i - 1])
            diff += d * d
            energy += Double(samples[i]) * Double(samples[i])
        }
        return diff / energy
    }
    func energy(_ samples: [Float]) -> Double {
        samples[44_100..<count].reduce(0) { $0 + Double($1) * Double($1) }
    }
    let dark = rendered(.lowPass, 0)
    check(roughness(dark) / roughness(plain) < 0.2, "LPF 0 removes the highs: \(roughness(dark) / roughness(plain))")
    let thin = rendered(.highPass, 1)
    check(energy(thin) / energy(plain) < 0.05, "HPF 1 removes the kick: \(energy(thin) / energy(plain))")
    // The same position law as the knobs: a drawn 0.5 is a knob at 63.5.
    check(AutomationKind.filterPosition(lowPass: 0.5) == LaneKnobMath.filterPosition(KnobState(function: .lowPass, value: 127))
          - 0.5 && AutomationKind.filterPosition(highPass: 1) == LaneKnobMath.filterPosition(KnobState(function: .highPass, value: 127)),
          "drawn and knob filters share one law")
}

section("preview cycle: wraps sample-exact, and a seek is not lost") {
    // A ramp, so every sample names its own frame: frame f holds f / 10 000.
    let length = 10_000
    let ramp = AudioFrames(interleaved: (0..<length).flatMap { [Float($0) / 10_000, Float($0) / 10_000] })
    let core = PreviewCore()
    core.audio.store(UnsafeRawPointer(Unmanaged.passUnretained(ramp).toOpaque()), ordering: .releasing)
    let gain = Float(pow(10, Automation.defaultVolumeDB / 20))
    let format = AVAudioFormat(standardFormatWithSampleRate: AudioFrames.sampleRate, channels: 2)!
    let block = core.makeRenderBlock()
    func render(_ count: Int) -> [Int] {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        var silence: ObjCBool = false
        var stamp = AudioTimeStamp()
        _ = block(&silence, &stamp, AVAudioFrameCount(count), buffer.mutableAudioBufferList)
        let left = buffer.floatChannelData![0]
        return (0..<count).map { Int((left[$0] / gain * 10_000).rounded()) }
    }
    core.position.store(90, ordering: .releasing)
    core.loop.store(PreviewCore.packLoop(start: 100, end: 110), ordering: .releasing)
    core.playing.store(true, ordering: .releasing)
    let frames = render(30)
    check(frames == Array(90..<110) + Array(100..<110), "into the loop, then round: \(frames)")
    check(render(5) == Array(100..<105), "the next block carries on inside it")
    core.loop.store(PreviewCore.packLoop(start: 50, end: 54), ordering: .releasing)
    check(render(6) == [50, 51, 52, 53, 50, 51], "ends moved while it plays: past the new end it jumps back at once")
    core.seekTarget.store(5000, ordering: .releasing)
    core.loop.store(0, ordering: .releasing)
    check(render(3) == [5000, 5001, 5002], "a seek handed over reaches the next block")
    check(core.position.load(ordering: .acquiring) == 5003 && core.seekTarget.load(ordering: .acquiring) == -1,
          "and is used up")
    check(PreviewCore.packLoop(start: 10, end: 10) == 0 && PreviewCore.packLoop(start: 20, end: 10) == 0,
          "an empty or reversed stretch is no cycle")
    core.position.store(length - 3, ordering: .releasing)
    _ = render(8)
    check(!core.playing.load(ordering: .acquiring), "without a cycle it still stops at the end of the song")
}

section("rec: knob values as automation, and a touch pass on the clip") {
    check(KnobFunction.lowPass.automationValue(0) == 0 && KnobFunction.lowPass.automationValue(127) == 1
          && KnobFunction.highPass.automationValue(127) == 1, "filters over their whole range")
    check(KnobFunction.pan.automationValue(64) == 0 && KnobFunction.pan.automationValue(0) == -1
          && KnobFunction.pan.automationValue(127) == 1, "pan centred exactly at 64")
    check(KnobFunction.volume.automationValue(0) == Automation.silenceDB
          && KnobFunction.volume.automationValue(127) == Automation.maxVolumeDB, "volume from silence to +12 dB")
    check(abs(Automation.faderTravel(dB: KnobFunction.volume.automationValue(90)) - 90.0 / 127) < 1e-9,
          "volume along the fader taper, as drawing")
    check(KnobFunction.volume.automationKind == .volume && KnobFunction.lowPass.automationKind == .lowPass,
          "each knob writes its own kind")

    // testGrid clip on lane 0 from startBeat 0: anchor 4, visible 2 … 242.
    var doc = MixDocument()
    let a = try! doc.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    doc.clips[0].automation.lowPass = [AutomationNode(beat: 6, value: 0.9), AutomationNode(beat: 20, value: 0.7),
                                       AutomationNode(beat: 60, value: 0.5)]
    doc.clips[0].automation.gestures = [AutomationGesture(kind: .lowPass, start: 30, end: 34, shape: .sine,
                                                          period: 1, low: 0, high: 1)]
    let pass = stride(from: 10.0, through: 30.0, by: 0.01).map { AutomationNode(beat: $0 + 4, value: 0.3) }
    check(doc.writeTouch(clip: a, kind: .lowPass, samples: pass, returnTo: nil, grids: grids), "written")
    let nodes = doc.clips[0].automation.lowPass
    check(nodes.first == AutomationNode(beat: 6, value: 0.9) && nodes.last == AutomationNode(beat: 60, value: 0.5),
          "what lies outside the pass stays")
    check(!nodes.contains(AutomationNode(beat: 20, value: 0.7)), "what lay under it is replaced")
    check(nodes.count == 4, "a steady knob is two points, not two thousand: \(nodes.count)")
    check(doc.clips[0].automation.gestures.isEmpty, "a gesture the pass crosses is removed")
    let again = doc
    doc.writeTouch(clip: a, kind: .lowPass, samples: pass, returnTo: nil, grids: grids)
    check(doc == again, "writing the same pass twice changes nothing")
    doc.writeTouch(clip: a, kind: .lowPass, samples: pass, returnTo: 0.6, grids: grids)
    check(doc.clips[0].automation.lowPass.contains(AutomationNode(beat: 30.25, value: 0.6)),
          "letting go returns to the old curve a quarter beat later")

    let moving = stride(from: 0.0, through: 4.0, by: 0.05).map { AutomationNode(beat: 40 + $0, value: $0 / 4) }
    var sweep = MixDocument()
    let s = try! sweep.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    sweep.writeTouch(clip: s, kind: .highPass, samples: moving, returnTo: nil, grids: grids)
    let written = sweep.clips[0].automation.highPass
    check(written.count > 20 && written.first?.value == 0 && written.last?.value == 1,
          "a moving knob keeps its movement: \(written.count) points")

    var outside = MixDocument()
    let o = try! outside.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    check(!outside.writeTouch(clip: o, kind: .pan, samples: [AutomationNode(beat: 300, value: 1)], returnTo: nil,
                              grids: grids) && outside.clips[0].automation.isEmpty,
          "past the clip's end nothing is written")
    outside.writeTouch(clip: o, kind: .pan, samples: [AutomationNode(beat: 240, value: 1), AutomationNode(beat: 250, value: 1)],
                       returnTo: nil, grids: grids)
    check(outside.clips[0].automation.pan.map(\.beat) == [236], "only the part inside the region")
    var locked = MixDocument()
    let l = try! locked.addClip(trackID: trackA, grid: testGrid, lane: 0, startBeat: 0, grids: grids)
    locked.setLocked(l, true)
    check(!locked.writeTouch(clip: l, kind: .volume, samples: pass, returnTo: nil, grids: grids), "a locked clip is not written")
}

section("lane knobs: a CC from a MIDI source reaches the knobs") {
    let defaults = UserDefaults(suiteName: "ultramix.verify.midi")!
    defaults.removePersistentDomain(forName: "ultramix.verify.midi")
    var client = MIDIClientRef()
    var source = MIDIEndpointRef()
    let name = "Ultramix Verify Controller"
    guard MIDIClientCreateWithBlock("UltramixVerify" as CFString, &client, nil) == noErr,
          MIDISourceCreate(client, name as CFString, &source) == noErr else {
        check(false, "could not create a virtual source")
        return
    }
    let input = MIDIControllerInput(defaults: defaults)
    var heard: [MIDIControlChange] = []
    input.onControlChange = { heard.append($0) }
    func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    settle { input.sources.contains { $0.name == name } }
    guard let found = input.sources.first(where: { $0.name == name }) else {
        check(false, "the virtual source is not listed: \(input.sources.map(\.name))")
        return
    }
    func send(_ bytes: [UInt8]) {
        var packet = MIDIPacket()
        packet.length = UInt16(bytes.count)
        withUnsafeMutableBytes(of: &packet.data) { $0.copyBytes(from: bytes) }
        var list = MIDIPacketList(numPackets: 1, packet: packet)
        MIDIReceived(source, &list)
    }
    send([0xB0, 21, 50])
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    check(heard.isEmpty, "not chosen: not heard")

    input.setController(found, on: true)
    check(defaults.stringArray(forKey: MIDIControllerInput.storageKey) == [name], "remembered by name")
    send([0xB0, 21, 50, 22, 0xF8, 60])
    send([0x93, 60, 100])
    settle { heard.count >= 2 }
    check(heard == [MIDIControlChange(channel: 1, controller: 21, value: 50),
                    MIDIControlChange(channel: 1, controller: 22, value: 60)], "\(heard)")

    input.setController(found, on: false)
    heard = []
    send([0xB0, 21, 51])
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    check(heard.isEmpty, "released: not heard")
    MIDIEndpointDispose(source)
    MIDIClientDispose(client)
    defaults.removePersistentDomain(forName: "ultramix.verify.midi")
}

// MARK: - Wheel zoom

section("wheel zoom: a line is 1.2×, the hand decides the direction, the beat stays put") {
    check(near(WheelZoom.factor(deltaY: 1, precise: false, inverted: false), 1.2, 1e-12), "one notch away: 1.2× in")
    check(near(WheelZoom.factor(deltaY: -1, precise: false, inverted: false), 1 / 1.2, 1e-12), "one notch back: out")
    check(near(WheelZoom.factor(deltaY: -1, precise: false, inverted: true), 1.2, 1e-12),
          "natural scrolling turns the delta round, not the zoom")
    check(near(WheelZoom.factor(deltaY: 40, precise: true, inverted: false), 1.2, 1e-12), "40 points on a trackpad are a notch")
    check(near(WheelZoom.factor(deltaY: 10, precise: true, inverted: false), pow(1.2, 0.25), 1e-12), "and 10 a quarter of one")
    check(near(WheelZoom.factor(deltaY: 25, precise: false, inverted: false), pow(1.2, 4), 1e-12), "a fast spin: four lines at most")
    check(near(WheelZoom.factor(deltaY: -1000, precise: true, inverted: false), pow(1.2, -4), 1e-12), "the same zooming out")
    check(WheelZoom.factor(deltaY: 0, precise: true, inverted: false) == 1, "no delta, no zoom")

    // Beat 100 under x = 400 at 8 px a beat; zoomed to 9.6 it is still there.
    let pad = Double(12)
    let before = 100 * 8 + pad - 400
    let after = WheelZoom.scrollX(keeping: 100, at: 400, pixelsPerBeat: 9.6, leadingPad: pad)
    check(near((400 + after - pad) / 9.6, 100, 1e-9), "beat under the pointer after: \((400 + after - pad) / 9.6)")
    check(after > before, "zooming in scrolls on so the beat stays")
    check(WheelZoom.scrollX(keeping: 1, at: 600, pixelsPerBeat: 4, leadingPad: pad) == 0, "never before the start")
}

// MARK: - Key shift

/// `samples` (interleaved stereo) shifted by `semitones`, as the cache gets it.
func keyShifted(_ samples: [Float], semitones: Float) -> [Float] {
    var out: [Float] = []
    out.reserveCapacity(samples.count)
    samples.withUnsafeBufferPointer { input in
        try! KeyShifter.shift(input.baseAddress!, frames: samples.count / 2, channels: 2, semitones: semitones,
                              sampleRate: AudioFrames.sampleRate) { block, count in
            out.append(contentsOf: UnsafeBufferPointer(start: block, count: count))
        }
    }
    return out
}

func stereoSine(_ hz: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
    let frames = Int(seconds * AudioFrames.sampleRate)
    var samples = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let v = Float(amplitude * sin(2 * Double.pi * hz * Double(i) / AudioFrames.sampleRate))
        samples[2 * i] = v
        samples[2 * i + 1] = v
    }
    return samples
}

/// The left channel's frequency between two times, from its upward zero
/// crossings, each placed between samples by linear interpolation.
func zeroCrossingHz(_ samples: [Float], from: Double, to: Double) -> Double {
    let rate = AudioFrames.sampleRate
    var crossings: [Double] = []
    for i in Int(from * rate)..<Int(to * rate) {
        let a = samples[2 * i], b = samples[2 * i + 2]
        if a < 0 && b >= 0 { crossings.append(Double(i) + Double(-a / (b - a))) }
    }
    guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
    return Double(crossings.count - 1) / ((last - first) / rate)
}

section("key shift: the modified real FFT is the half-bin DFT, and comes back ×N") {
    check(ModifiedRealFFT.fastComplexSize(above: 1323) == 1536, "6 × 256")
    check(ModifiedRealFFT.fastComplexSize(above: 112) == 128, "7 × 16 is not fast: 8 × 16")
    check(ModifiedRealFFT.fastSize(above: 2646) == 3072, "\(ModifiedRealFFT.fastSize(above: 2646))")
    for n in [96, 6144] {
        let fft = ModifiedRealFFT(size: n)
        var generator = SplitMix(seed: UInt64(n))
        let x = (0..<n).map { _ in generator.uniform(-1, 1) }
        var real = [Float](repeating: 0, count: n / 2), imag = real
        fft.forward(x, real: &real, imag: &imag)
        var worst = 0.0, peak = 0.0
        for k in stride(from: 0, to: n / 2, by: n / 2 / 16) {
            var sr = 0.0, si = 0.0
            for t in 0..<n {
                let phase = -2 * Double.pi * Double(t) * (Double(k) + 0.5) / Double(n)
                sr += Double(x[t]) * cos(phase)
                si += Double(x[t]) * sin(phase)
            }
            worst = max(worst, hypot(sr - Double(real[k]), si - Double(imag[k])))
            peak = max(peak, hypot(sr, si))
        }
        check(worst / peak < 1e-5, "N = \(n): relative error \(worst / peak)")
        var back = [Float](repeating: 0, count: n)
        fft.inverse(real: real, imag: imag, &back)
        let roundTrip = (0..<n).map { abs(Double(back[$0]) / Double(n) - Double(x[$0])) }.max()!
        check(roundTrip < 1e-5, "N = \(n): round trip \(roundTrip)")
    }
}

section("key shift: the STFT gives back what it was given") {
    let shifter = KeyShifter(channels: 2, sampleRate: AudioFrames.sampleRate)
    let stft = shifter.stft
    // Signalsmith's default preset at 44.1 kHz.
    check(stft.blockSamples == 5292 && stft.interval == 1323, "\(stft.blockSamples) / \(stft.interval)")
    check(stft.fftSamples == 6144 && stft.bands == 3072, "\(stft.fftSamples) / \(stft.bands)")
    check(shifter.inputLatency == 2646 && shifter.outputLatency == 2646, "window peak mid-block")
    check(near(Double(stft.binToFreq(0)), 0.5 / 6144, 1e-9), "bins sit half a bin up")

    // Analysed and synthesised without a change, every interval: the input,
    // one block less one interval later.
    let probe = STFTProbe(channels: 2, blockSamples: 5292, interval: 1323)
    let interval = 1323, frames = 1323 * 40
    var generator = SplitMix(seed: 9)
    let x = (0..<frames * 2).map { _ in generator.uniform(-0.5, 0.5) }
    let y = probe.roundTrip(x, frames: frames)
    let delay = 5292 - interval
    var worst: Float = 0
    for n in (2 * 5292)..<frames {
        for c in 0..<2 { worst = max(worst, abs(y[2 * n + c] - x[2 * (n - delay) + c])) }
    }
    check(worst < 1e-5, "worst reconstruction error \(worst)")
}

/// Drives a bare ShiftSTFT the way the shifter does, without touching the
/// spectra.
nonisolated struct STFTProbe {
    let stft: ShiftSTFT

    init(channels: Int, blockSamples: Int, interval: Int) {
        stft = ShiftSTFT(channels: channels, blockSamples: blockSamples, interval: interval,
                         extraInputHistory: interval + 1)
    }

    func roundTrip(_ x: [Float], frames: Int) -> [Float] {
        let channels = stft.channels, interval = stft.interval
        var y = [Float](repeating: 0, count: frames * channels)
        var chunk = [Float](repeating: 0, count: interval)
        var k = 0
        while (k + 1) * interval <= frames {
            for c in 0..<channels {
                for i in 0..<interval { chunk[i] = x[(k * interval + i) * channels + c] }
                stft.writeInput(channel: c, length: interval, chunk)
            }
            stft.moveInput(interval)
            for c in 0..<channels { stft.analyse(channel: c) }
            stft.synthesise()
            for c in 0..<channels {
                stft.readOutput(channel: c, length: interval, into: &chunk)
                for i in 0..<interval { y[(k * interval + i) * channels + c] = chunk[i] }
            }
            stft.moveOutput(interval)
            k += 1
        }
        return y
    }
}

section("key shift: the same samples as Signalsmith Stretch's C++") {
    // Two sines a channel, a second long, up 3 semitones. The values were
    // rendered by signalsmith-stretch 1.3.2 (with linear on Accelerate),
    // `exact()`. A phase vocoder feeds its own output back, so the two
    // implementations drift apart over seconds by float rounding alone -
    // the C++ against itself on another FFT drifts the same way - but at the
    // start they agree to the last bits of a Float.
    let frames = 44_100
    var x = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let t = Double(i) / 44_100
        x[2 * i] = Float(0.3 * sin(2 * Double.pi * 220 * t) + 0.2 * sin(2 * Double.pi * 330 * t + 0.5))
        x[2 * i + 1] = Float(0.25 * sin(2 * Double.pi * 277.18 * t) + 0.15 * sin(2 * Double.pi * 440 * t + 1.0))
    }
    let y = keyShifted(x, semitones: 3)
    check(y.count == x.count, "as long as the input")
    let reference: [(Int, Float, Float)] = [
        (0, -0.0492536, -0.0541194),
        (1000, -0.2993565, -0.0513189),
        (2000, -0.3961422, -0.2409333),
        (3000, -0.4163466, 0.1422523),
        (4000, -0.3712362, -0.0818179),
    ]
    for (i, left, right) in reference {
        check(abs(y[2 * i] - left) < 2e-5 && abs(y[2 * i + 1] - right) < 2e-5,
              "frame \(i): \(y[2 * i]), \(y[2 * i + 1]) against \(left), \(right)")
    }
}

section("key shift: in tune, at the same level, in the same place") {
    // A 440 Hz sine against equal temperament, and against what the C++
    // original measures on the same sine: its peak estimate sits a few cents
    // off for some notes (+3 cents at +2), which the port reproduces to the
    // hundredth of a hertz - and which is below what anyone hears.
    let sine = stereoSine(440, seconds: 3)
    // Fine tunes too: half a semitone, a quarter down, and cents on a key.
    let cases: [(Float, Double, Double)] = [
        (2, 493.8833, 494.7816), (-3, 369.9944, 370.0073), (6, 622.2540, 622.8948),
        (0.5, 452.8930, 453.7522), (-0.25, 433.6918, 433.6246), (2.15, 498.1811, 498.1603),
    ]
    for (semitones, hz, original) in cases {
        let y = keyShifted(sine, semitones: semitones)
        check(y.count == sine.count, "\(semitones): length kept")
        let measured = zeroCrossingHz(y, from: 0.5, to: 2.5)
        let cents = 1200 * log2(measured / hz)
        check(abs(cents) < 5, "\(semitones) semitones: \(measured) Hz, \(cents) cents from \(hz)")
        check(abs(measured - original) < 0.01, "\(semitones) semitones: \(measured) Hz, the C++ measures \(original)")
        func rms(_ v: [Float]) -> Double {
            let mid = v[(2 * 44_100)..<(4 * 44_100)]
            return (mid.reduce(0) { $0 + Double($1 * $1) } / Double(mid.count)).squareRoot()
        }
        let level = 20 * log10(rms(y) / rms(sine))
        check(abs(level) < 0.5, "\(semitones) semitones: level \(level) dB")
    }

    // Clicks every half second: each comes out smeared over the window,
    // but centred where it was - the beatgrid does not move.
    let rate = 44_100
    var clicks = [Float](repeating: 0, count: rate * 4 * 2)
    let positions = stride(from: rate / 2, to: rate * 4 - rate / 4, by: rate / 2).map { $0 + 123 }
    for p in positions { clicks[2 * p] = 0.8; clicks[2 * p + 1] = 0.8 }
    let shiftedClicks = keyShifted(clicks, semitones: 3)
    var worst = 0.0
    for p in positions {
        var weighted = 0.0, total = 0.0
        for i in (p - rate / 8)..<(p + rate / 8) {
            let e = Double(shiftedClicks[2 * i] * shiftedClicks[2 * i])
            weighted += e * Double(i - p)
            total += e
        }
        check(total > 1e-3, "click at \(p) came through: energy \(total)")
        worst = max(worst, abs(weighted / total))
    }
    check(worst < 44, "click energy centred within 1 ms, worst \(worst / 44.1) ms")
    print("     clicks centred within \(String(format: "%.3f", worst / 44.1)) ms")
}

section("key shift: a pure function of its input; silence stays silence") {
    var generator = SplitMix(seed: 3)
    var x = stereoSine(311, seconds: 2.5, amplitude: 0.3)
    for i in 0..<x.count { x[i] += generator.uniform(-0.05, 0.05) }
    // Digital silence in the middle, longer than two blocks, and at the end.
    for i in (2 * 44_100)..<(2 * 66_150) { x[i] = 0 }
    let first = keyShifted(x, semitones: -2)
    let second = keyShifted(x, semitones: -2)
    check(first == second, "two renders are bit-identical")
    check(first.allSatisfy(\.isFinite), "no NaN or infinity")
    let silent = keyShifted([Float](repeating: 0, count: 44_100 * 2), semitones: 5)
    check(silent.allSatisfy { $0 == 0 }, "silence in, silence out")
    let short = [Float](repeating: 0.25, count: 1000 * 2)
    check(keyShifted(short, semitones: 1) == short, "shorter than a block: passed through as it is")
    check(keyShifted(x, semitones: 0) == x, "no shift: the input itself")

    // A render nobody wants any more stops, and leaves nothing behind.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ultramix-shift-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("cancelled.f32")
    let long = AudioFrames(interleaved: stereoSine(97, seconds: 120, amplitude: 0.4))
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome = "not run"
    let task = Task.detached {
        do {
            try KeyShifter.render(long, semitones: 2, to: destination)
            outcome = "rendered"
        } catch is CancellationError {
            outcome = "cancelled"
        } catch {
            outcome = "\(error)"
        }
        done.signal()
    }
    task.cancel()
    done.wait()
    check(outcome == "cancelled", "cancelled render: \(outcome)")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
    check(left.isEmpty, "nothing left behind: \(left)")
    try? FileManager.default.removeItem(at: folder)

    let start = Date()
    _ = keyShifted(stereoSine(97, seconds: 30, amplitude: 0.4), semitones: 1)
    print("     30 s of stereo shifted in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
}

section("key shift: the clip, its file, the plan and the key it makes") {
    // A clip saves its shift only when it has one, and loads it held to range.
    var clip = Clip(trackID: UUID(), lane: 0, anchorBeat: 0)
    let plain = String(data: try! JSONEncoder().encode(clip), encoding: .utf8)!
    check(!plain.contains("keyShift"), "no key shift, no key")
    clip.keyShift = -3
    let shifted = try! JSONDecoder().decode(Clip.self, from: try! JSONEncoder().encode(clip))
    check(shifted.keyShift == -3, "round trip: \(shifted.keyShift)")
    var json = String(data: try! JSONEncoder().encode(clip), encoding: .utf8)!
    json = json.replacingOccurrences(of: "\"keyShift\":-3", with: "\"keyShift\":11")
    check(try! JSONDecoder().decode(Clip.self, from: Data(json.utf8)).keyShift == 6, "held to ±6")
    check(!plain.contains("fineTune"), "no fine tune, no key")
    clip.fineTune = 15
    check(try! JSONDecoder().decode(Clip.self, from: try! JSONEncoder().encode(clip)).fineTune == 15, "fine tune round trip")
    for (stored, loaded) in [(13, 15), (-12, -10), (80, 50), (-51, -50), (2, 0)] {
        let text = String(data: try! JSONEncoder().encode(clip), encoding: .utf8)!
            .replacingOccurrences(of: "\"fineTune\":15", with: "\"fineTune\":\(stored)")
        let got = try! JSONDecoder().decode(Clip.self, from: Data(text.utf8)).fineTune
        check(got == loaded, "fine tune \(stored) loads as \(loaded), got \(got)")
    }
    check(PitchShift(semitones: 2, cents: 15).label == "+2 +15 ct" && PitchShift(semitones: 0, cents: -25).label == "-25 ct"
          && PitchShift(semitones: -3, cents: 0).label == "-3", "labels")
    check(PitchShift(semitones: -1, cents: 50).amount == -0.5 && PitchShift.none.isNone, "amount in semitones")

    // Steps, split and duplicate.
    let track = UUID()
    let grid = SourceGrid(bpm: 124, firstBeatSeconds: 0, durationSeconds: 60)
    let lookup: GridLookup = { $0 == track ? grid : nil }
    var doc = MixDocument()
    let id = try! doc.addClip(trackID: track, grid: grid, lane: 0, startBeat: 0, grids: lookup)
    doc.stepKeyShift(id, by: 4)
    doc.stepKeyShift(id, by: 4)
    check(doc.clips[0].keyShift == 6, "stops at +6")
    doc.setKeyShift(id, -2)
    let right = try! doc.splitClip(id, at: 32, grids: lookup)
    check(doc.clips.allSatisfy { $0.keyShift == -2 }, "both halves of a split keep the shift")
    doc.stepFineTune(id, by: 3)
    check(doc.clips.first { $0.id == id }?.fineTune == 15, "three clicks: 15 cents")
    for _ in 0..<20 { doc.stepFineTune(id, by: -1) }
    check(doc.clips.first { $0.id == id }?.fineTune == -50, "stops at −50")
    doc.setFineTune(id, 22)
    check(doc.clips.first { $0.id == id }?.fineTune == 20, "typed between steps: onto the nearest")
    doc.setFineTune(right, 20)
    let copy = try! doc.duplicateClip(right, grids: lookup)
    check(doc.clips.first { $0.id == copy }.map { $0.keyShift == -2 && $0.fineTune == 20 } == true, "a copy keeps the shift")
    let halves = try! doc.splitClip(copy, at: 96, grids: lookup)
    check(doc.clips.first { $0.id == halves }?.fineTune == 20, "a split keeps the fine tune")
    for c in doc.clips { doc.setFineTune(c.id, 0) }

    // The plan plays the shifted audio, and the plain audio until it is there.
    let original = AudioFrames(interleaved: [Float](repeating: 0.1, count: 44_100 * 60 * 2))
    let up = AudioFrames(interleaved: [Float](repeating: 0.2, count: 44_100 * 60 * 2))
    let waiting = RenderPlan(document: doc, grids: lookup, audio: { _ in original }, generation: 0)
    check(waiting.segments.allSatisfy { $0.audio === original }, "no shift rendered yet: the clip plays as it is")
    let ready = RenderPlan(document: doc, grids: lookup, audio: { _ in original }, generation: 0,
                           shiftedAudio: { $1 == PitchShift(semitones: -2, cents: 0) ? up : nil })
    check(ready.segments.allSatisfy { $0.audio === up }, "rendered: the shifted file")
    doc.setKeyShift(id, 0)
    let mixed = RenderPlan(document: doc, grids: lookup, audio: { _ in original }, generation: 0,
                           shiftedAudio: { _, _ in up })
    check(mixed.segments.filter { $0.audio === original }.count == 1
          && mixed.segments.filter { $0.audio === up }.count == mixed.segments.count - 1,
          "a clip without a shift keeps its plain audio")
    // A fine tune alone is a shift too, looked up with its cents.
    doc.setFineTune(id, -25)
    let detuned = RenderPlan(document: doc, grids: lookup, audio: { _ in original }, generation: 0,
                             shiftedAudio: { $1 == PitchShift(semitones: 0, cents: -25) ? up : nil })
    check(detuned.segments.filter { $0.audio === up }.count == 1, "a fine tune without a key shift plays its own render")

    // The key it makes.
    let c = MusicalKey(tonic: 0, minor: false), am = MusicalKey(tonic: 9, minor: true)
    check(c.transposed(by: 2).name == "D" && c.transposed(by: 2).camelot == "10B", "C + 2 = D, 10B")
    check(c.transposed(by: -1).name == "B" && c.transposed(by: 12) == c, "down wraps, an octave is the same key")
    check(am.transposed(by: 7).camelot == "9A", "a fifth up is one step round the wheel")

    // The cache file of a shift, and whose it is.
    let name = CacheSweep.shiftedName(track, pitch: PitchShift(semitones: 2, cents: 0))
    check(name == "\(track.uuidString).k+2.sw1.f32", "whole semitones keep their old name: \(name)")
    check(CacheSweep.shiftedName(track, pitch: PitchShift(semitones: -5, cents: 0)).hasSuffix(".k-5.sw1.f32"), "minus sign")
    check(CacheSweep.shift(in: name).map { $0.id == track && $0.pitch == PitchShift(semitones: 2, cents: 0) } == true, "parsed back")
    for pitch in [PitchShift(semitones: 2, cents: -15), PitchShift(semitones: 0, cents: 25), PitchShift(semitones: -6, cents: -50)] {
        let fine = CacheSweep.shiftedName(track, pitch: pitch)
        check(CacheSweep.shift(in: fine).map { $0.id == track && $0.pitch == pitch } == true, "\(fine) parsed back")
    }
    check(CacheSweep.shiftedName(track, pitch: PitchShift(semitones: 0, cents: 25)).hasSuffix(".k0c+25.sw1.f32"), "cents alone")
    check(CacheSweep.shift(in: "\(track.uuidString).k+2c0.sw1.f32") == nil, "c0 is never written, so not ours")
    check(CacheSweep.shift(in: "\(track.uuidString).k+2c.sw1.f32") == nil, "no number, no shift")
    check(CacheSweep.shift(in: "\(track.uuidString).k+2.ss1.f32") == nil, "another tag is not ours to play")
    check(CacheSweep.shift(in: "\(track.uuidString).f32") == nil, "the plain audio is not a shift")
    let gone = UUID()
    let names = [CacheSweep.shiftedName(track, pitch: PitchShift(semitones: 1, cents: 0)),
                 CacheSweep.shiftedName(gone, pitch: PitchShift(semitones: -1, cents: 10)),
                 ".\(CacheSweep.shiftedName(track, pitch: PitchShift(semitones: 3, cents: 0))).\(UUID().uuidString).partial"]
    check(Set(CacheSweep.orphans(among: names, keeping: [track])) == Set(names[1...]), "a removed track's shifts go")
}

// MARK: - Summary

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
