//
//  ContentView.swift
//  Ultramix
//
//  The main window: transport on top, timeline filling the middle, the
//  selected clip's details along the bottom, and the library as an inspector
//  on the right that can be put away.
//
//  The beatgrid editor opens as a pane under the timeline rather than a sheet
//  over it: cue points and loops are made to be put into the timeline, so the
//  timeline has to stay in sight. Its top edge is draggable, its height kept
//  per Mac, and E folds it to a bar and back.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var session: MixSession
    @Bindable var library: Library
    var workspaceName: String
    /// Mix or Live; `session` is the one in front.
    @Binding var tab: AppTab

    @State private var showLibrary = true
    @AppStorage("pixelsPerBeat") private var pixelsPerBeat = 6.0
    @AppStorage("beatgridHeight") private var editorHeight = 320.0
    @AppStorage("followPlayhead") private var follow = true
    @State private var drawStyle: DrawStyle = .nodes
    @State private var period = 1.0

    /// The library's selection in the order the tracks were added to it -
    /// the button cannot see the table's sort.
    private var librarySelection: [UUID] {
        library.tracks.map(\.id).filter { library.selection.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(session: session, pixelsPerBeat: $pixelsPerBeat, follow: $follow,
                         tool: $session.tool, drawStyle: $drawStyle, period: $period)
            Divider()
            TimelinePanel(session: session, library: library, pixelsPerBeat: $pixelsPerBeat,
                          follow: follow, tool: session.tool, drawStyle: drawStyle, period: period)
                // A timeline of its own per tab: its scroll position and a
                // half-drawn gesture belong to one document, not both.
                .id(ObjectIdentifier(session))
            if let request = session.beatgridRequest {
                let hidden = session.beatgridHidden
                Divider()
                if hidden {
                    CollapsedEditorBar(title: library.track(request.id)?.displayName ?? "") {
                        session.beatgridHidden = false
                    } close: {
                        session.beatgridRequest = nil
                    }
                } else {
                    EditorResizeHandle(height: $editorHeight) {
                        session.toggleBeatgrid()
                    }
                }
                // Kept in the hierarchy while folded away, only with no
                // height: an `if` would throw the editor away, and with it
                // the mark, the zoom and the kicks it measured.
                BeatgridEditor(trackID: request.id, session: session, library: library,
                               preview: session.preview, correctBPM: request.correctBPM,
                               hidden: hidden, hide: { session.toggleBeatgrid() }) {
                    session.beatgridRequest = nil
                }
                // Another track opened in the pane is another editor: its
                // selected line, its zoom and its mark start afresh.
                .id(request.id)
                // The pane gives way when the window is short, down to a
                // usable strip; the clip rows below never do. With a fixed
                // height the clip rows were the ones pushed off the bottom
                // of a 797-point window.
                .frame(minHeight: hidden ? 0 : 170, maxHeight: hidden ? 0 : editorHeight)
                .clipped()
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)
            }
            Divider()
            ClipBar(session: session, library: library)
                .fixedSize(horizontal: false, vertical: true)
        }
        .overlay(alignment: .bottom) {
            if let progress = library.tagProgress {
                TagProgressOverlay(title: "Writing BPM into the song files…",
                                   done: progress.done, total: progress.total) {
                    library.cancelTagWriting()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let progress = library.cacheFill {
                TagProgressOverlay(title: "Decoding every song…",
                                   done: progress.done, total: progress.total) {
                    library.cancelCacheFill()
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: library.tagProgress)
        .animation(.easeInOut(duration: 0.2), value: library.cacheFill)
        .inspector(isPresented: $showLibrary) {
            LibraryPanel(session: session, library: library)
                .inspectorColumnWidth(min: 300, ideal: 390, max: 620)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Two documents side by side, not a mode: switching costs
                // neither anything, and the live set plays on behind the mix.
                Picker("Tab", selection: $tab) {
                    ForEach(AppTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Mix edits and saves a mix (⌘1). Live plays a set of up to three clips that lets go of what has played and is never saved (⌘2); it plays on while you look at the mix.")
            }
            ToolbarItem(placement: .primaryAction) {
                // Click adds the library's selection at the end of the mix
                // with the current beatmix; the arrow picks another length,
                // adds with it at once, and makes it the current one. The
                // transitions stay in the clip bar and the Clip menu - this
                // button used to repeat them.
                Menu {
                    ForEach(BeatmixLength.allCases) { length in
                        Button(length.title) { session.addTracks(librarySelection, beatmix: length) }
                    }
                } label: {
                    Label(session.beatmixLength.title, systemImage: "text.line.last.and.arrowtriangle.forward")
                } primaryAction: {
                    session.addTracks(librarySelection, beatmix: session.beatmixLength)
                }
                .disabled(library.selection.isEmpty)
                .help("Add the tracks selected in the library at the end of the mix - \(session.beatmixLength.title); the arrow picks another")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showLibrary.toggle()
                } label: {
                    Label("Library", systemImage: "music.note.list")
                }
                .help("Show or hide the library")
            }
        }
        .navigationTitle(session.title)
        .navigationSubtitle(session.isLive ? "\(workspaceName) — \(session.liveSubtitle)"
                            : session.isDirty ? "\(workspaceName) — Edited" : workspaceName)
        .sheet(isPresented: $session.showBounce) {
            BounceSheet(session: session)
        }
        .alert("Ultramix", isPresented: Binding(
            get: { session.message != nil || library.lastError != nil || library.notice != nil },
            set: { if !$0 { session.message = nil; library.lastError = nil; library.notice = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(session.message ?? library.lastError ?? library.notice ?? "")
        }
    }
}


/// The beatgrid pane's top edge. A drag makes the pane taller or shorter;
/// the timeline above gives and takes the room. Dragged well below the
/// shortest pane, it folds the pane down to its bar, as dragging Logic's
/// editor shut does - the height it had is kept for when it comes back.
///
/// The drag is measured in window coordinates. The handle sits on the pane
/// and moves with it: measured in its own coordinates, every change of
/// height moved the point the next change was measured from, and the pane
/// shook up and down under the pointer.
private struct EditorResizeHandle: View {
    @Binding var height: Double
    let fold: () -> Void
    @State private var base: Double?

    static let range = 200.0...760.0
    /// How far past the shortest pane a drag has to go to fold it.
    static let foldBeyond = 80.0

    var body: some View {
        ZStack {
            Color.clear.frame(height: 7)
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 3)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = base ?? height
                    if base == nil { base = height }
                    height = min(max(start - Double(value.translation.height), Self.range.lowerBound),
                                 Self.range.upperBound)
                }
                .onEnded { value in
                    if let start = base, start - Double(value.translation.height) < Self.range.lowerBound - Self.foldBeyond {
                        height = start
                        fold()
                    }
                    base = nil
                }
        )
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Resize the beatgrid editor")
    }
}

/// The beatgrid pane folded away: one line that says which track is still
/// open in it. A click anywhere on it unfolds the pane; ✕ closes it.
private struct CollapsedEditorBar: View {
    let title: String
    let show: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
            Text("Beatgrid").foregroundStyle(.secondary)
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close the beatgrid editor")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { show() }
        .help("Show the beatgrid editor again (E)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Beatgrid editor, hidden: \(title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { show() }
    }
}
