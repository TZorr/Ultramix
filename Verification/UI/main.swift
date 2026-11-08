import AppKit
import SwiftUI
import Observation
@testable import Ultramix

nonisolated(unsafe) var usageInvalidated = false

@Observable @MainActor final class BenchState {
    let library: Library
    let mix: MixSession
    let live: MixSession
    var tab = AppTab.mix
    var session: MixSession { tab == .mix ? mix : live }
    init(_ library: Library) {
        self.library = library
        mix = MixSession(library: library)
        live = MixSession(library: library, live: true)
    }
}

struct BenchView: View {
    let state: BenchState
    var body: some View {
        ContentView(session: state.session, library: state.library, workspaceName: "Benchmark",
                    tab: Binding(get: { state.tab }, set: { state.tab = $0 }))
    }
}

@main struct Perf {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = try Workspace.prepare(at: root)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep the fixture independent of saved app preferences without writing them.
        UserDefaults.standard.setVolatileDomain(["showLibrary": true, "showInspector": true],
                                                forName: UserDefaults.argumentDomain)
        let trackCount = Int(ProcessInfo.processInfo.environment["TRACKS"] ?? "1000") ?? 1000
        precondition(trackCount > 0, "TRACKS must be positive")
        let frames = 180 * 44_100
        var tracks = (0..<trackCount).map { i -> Track in
            var track = Track(path: "Audio/\(i).wav", bookmark: nil, title: "Track \(i)", artist: "Benchmark", durationSeconds: 180)
            track.state = .failed
            track.manualBPM = 120
            track.manualFirstBeatSeconds = 0
            return track
        }
        tracks[0].stems = TrackStems(tag: StemSeparator.tag, frames: frames)
        let id = tracks[0].id
        let level = WaveformLevel(minL: .init(repeating: -0.5, count: 128), maxL: .init(repeating: 0.5, count: 128),
                                  rmsL: .init(repeating: 0.25, count: 128), minR: .init(repeating: -0.5, count: 128),
                                  maxR: .init(repeating: 0.5, count: 128), rmsR: .init(repeating: 0.25, count: 128))
        let wave = Waveform(finest: level, framesPerBucket: frames / 128)
        try wave.data().write(to: workspace.cache.appendingPathComponent("\(id.uuidString).wave"))
        for stem in Stem.allCases {
            try wave.data().write(to: workspace.cache.appendingPathComponent(StemFiles.waveformName(id, stem)))
        }
        for name in ["\(id.uuidString).f32"] + Stem.stored.map({ StemFiles.cachedName(id, $0) }) {
            let file = workspace.cache.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(frames * 8))
            try handle.close()
        }
        for stem in Stem.stored {
            FileManager.default.createFile(atPath: workspace.stems.appendingPathComponent(StemFiles.storedName(id, stem)).path, contents: nil)
        }
        try Track.encodeLibrary(tracks).write(to: workspace.libraryFile)
        let library = Library(workspace: workspace)
        let state = BenchState(library)
        defer { state.mix.shutdown(); state.live.shutdown(); library.shutdown() }
        let clip = Clip(trackID: id, lane: 0, anchorBeat: 0)
        state.mix.perform { $0.clips.append(clip) }
        state.mix.selection = [clip.id]
        state.mix.setLaneExpanded(0, true)
        state.mix.selectedPart = .drums
        state.mix.beatgridRequest = BeatgridRequest(id: id)
        let host = NSHostingView(rootView: BenchView(state: state))
        host.frame = CGRect(x: 0, y: 0, width: 1440, height: 880)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        // The window stays off screen; exercise the SwiftUI/AppKit graph directly.
        func flush(_ seconds: Double = 0.005) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
            host.layoutSubtreeIfNeeded()
        }
        flush(0.5)
        withObservationTracking { _ = state.mix.usedTracks } onChange: { usageInvalidated = true }
        func measure(_ name: String, _ edit: (Int) -> Void) {
            var model: [Double] = [], total: [Double] = []
            for i in 0..<8 {
                let start = DispatchTime.now().uptimeNanoseconds
                edit(i)
                let changed = DispatchTime.now().uptimeNanoseconds
                flush()
                let end = DispatchTime.now().uptimeNanoseconds
                model.append(Double(changed - start) / 1_000_000)
                total.append(Double(end - start) / 1_000_000)
            }
            model.sort()
            total.sort()
            print(String(format: "%@: model median %.2f ms; update median %.2f ms; worst %.2f ms",
                         name, (model[3] + model[4]) / 2, (total[3] + total[4]) / 2, total.last!))
        }
        measure("stem selection") { i in state.mix.selectedPart = Stem.allCases[i % 4] }
        measure("stem mute") { i in state.mix.perform { $0.setPartMuted(clip.id, .drums, i % 2 == 0) } }
        measure("gain") { i in state.mix.perform { $0.stepGain(clip.id, by: i % 2 == 0 ? -1 : 1) } }
        measure("key") { i in state.mix.perform { $0.stepKeyShift(clip.id, by: i % 2 == 0 ? 1 : -1) } }
        measure("mode switch") { i in state.tab = i % 2 == 0 ? .live : .mix }
        precondition(state.mix.document.clips == [clip] && state.live.document.clips.isEmpty,
                     "The benchmark changed or mixed up document contents")
        precondition(!usageInvalidated, "Control edits invalidated the entire library's track-usage observation")
        precondition(state.mix.usedTracks == [id] && state.live.usedTracks.isEmpty)
        func checkUsage(_ expected: Set<UUID>, _ edit: () -> Void) {
            let previous = state.mix.usedTracks
            usageInvalidated = false
            withObservationTracking { _ = state.mix.usedTracks } onChange: { usageInvalidated = true }
            edit()
            precondition(state.mix.usedTracks == expected, "Track membership did not follow the document")
            precondition(usageInvalidated == (previous != expected), "Track-usage observation changed unnecessarily or missed an edit")
        }
        let duplicate = Clip(trackID: id, lane: 1, anchorBeat: 0)
        checkUsage([id]) { state.mix.perform { $0.clips.append(duplicate) } }
        checkUsage([id]) { state.mix.perform { $0.clips.removeAll { $0.id == duplicate.id } } }
        let other = Clip(trackID: UUID(), lane: 1, anchorBeat: 0)
        checkUsage([id, other.trackID]) { state.mix.perform { $0.clips.append(other) } }
        checkUsage([id]) { state.mix.perform { $0.clips.removeAll { $0.id == other.id } } }
        checkUsage([id, other.trackID]) { state.mix.undo() }
        checkUsage([id]) { state.mix.redo() }
        precondition(state.mix.document.clips == [clip])
        print("Document preservation, track membership, undo/redo and observation checks passed")
        // Test fixed viewports rather than NSHostingView's automatic window minimum.
        host.sizingOptions = []
        for width in [1000.0, 1440.0, 1900.0] {
            window.setContentSize(NSSize(width: width, height: 880))
            flush(0.05)
            precondition(abs(host.frame.width - width) <= 1, "The requested viewport was not exercised")
        }
        print("Layout smoke checks completed at 1000, 1440 and 1900 points; control visibility needs a visual check")
        window.contentView = nil
    }
}
