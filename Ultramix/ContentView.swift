//
//  ContentView.swift
//  Ultramix
//
//  The main window: the library as a sidebar on the left, the timeline in the
//  middle with its own bar above the ruler, the selected clip's inspector on
//  the right, and the transport in the window's toolbar. Library and inspector
//  can each be put away.
//
//  The beatgrid editor opens as a drawer under the timeline rather than a
//  sheet over it: cue points and loops are made to be put into the timeline,
//  so the timeline has to stay in sight. Its top edge is draggable, its height
//  kept per Mac, and E folds it to a bar and back.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var session: MixSession
    @Bindable var library: Library
    var workspaceName: String
    /// Mix or Live; `session` is the one in front.
    @Binding var tab: AppTab

    @AppStorage("showLibrary") private var showLibrary = true
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("pixelsPerBeat") private var pixelsPerBeat = 6.0
    @AppStorage("beatgridHeight") private var editorHeight = 320.0
    @AppStorage("followPlayhead") private var follow = true
    @AppStorage("tempoFolded") private var tempoFolded = false
    @State private var drawStyle: DrawStyle = .nodes
    @State private var period = 1.0

    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { showLibrary ? .all : .detailOnly },
                set: { showLibrary = $0 != .detailOnly })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columns) {
            LibraryPanel(session: session, library: library)
                .windowSurface()
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 460)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 360, ideal: 1000)
        }
        .inspector(isPresented: $showInspector) {
            ClipInspector(session: session, library: library)
                .windowSurface()
                .inspectorColumnWidth(min: 270, ideal: 300, max: 380)
        }
        .toolbarSurface()
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
            // One group in the middle: the transport, where the playhead is,
            // and what comes out. Only the inspector's switch is at the right.
            // Two items side by side rather than one: where the middle column
            // is too narrow for both, the meter goes into the overflow menu
            // and the transport stays - as one item, both went.
            ToolbarItem(placement: .principal) {
                TransportControls(session: session)
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 12) {
                    Divider().frame(height: 22)
                    OutputMeter(session: session)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the clip inspector")
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

    /// The middle column: the timeline's bar, the timeline, the beatgrid
    /// drawer, and the status line.
    private var detail: some View {
        VStack(spacing: 0) {
            TimelineBar(session: session, pixelsPerBeat: $pixelsPerBeat, follow: $follow,
                        tool: $session.tool, drawStyle: $drawStyle, period: $period)
                .yieldsWidth()
            Divider()
            TimelinePanel(session: session, library: library, pixelsPerBeat: $pixelsPerBeat,
                          follow: follow, tool: session.tool, drawStyle: drawStyle, period: period,
                          tempoFolded: $tempoFolded)
                // A timeline of its own per tab: its scroll position and a
                // half-drawn gesture belong to one document, not both.
                .id(ObjectIdentifier(session))
            if let request = session.beatgridRequest {
                let hidden = session.beatgridHidden
                if hidden {
                    Divider()
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
                // Another track opened in the drawer is another editor: its
                // selected line, its zoom and its mark start afresh.
                .id(request.id)
                .yieldsWidth()
                // The drawer gives way when the window is short, down to a
                // usable strip; the status line below never does.
                .frame(minHeight: hidden ? 0 : 220, maxHeight: hidden ? 0 : editorHeight)
                .clipped()
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)
            }
            Divider()
            StatusLine(session: session, library: library)
                .yieldsWidth()
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
        // A bar of its own, darker than the timeline and the drawer, with a
        // grip in the middle: the drawer's edge has to be seen to be found.
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 9)
            Capsule().fill(.secondary.opacity(0.7)).frame(width: 44, height: 3)
        }
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
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

extension View {
    /// Lays a row of the middle column out at its own width, but asks
    /// nothing of the column for it: what does not fit is cut off on the
    /// right.
    ///
    /// The window is split three ways - library, timeline, inspector - and
    /// the split view gives the middle what the other two leave. A row of
    /// fixed-size controls wider than that made the middle column's minimum
    /// larger than the room there was; the split view and SwiftUI then
    /// pushed the width back and forth until AppKit gave up ("more Update
    /// Constraints in Window passes than there are views") and the app
    /// crashed - reliably, by making the window narrower than about 1300
    /// points.
    func yieldsWidth() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
    }
}
