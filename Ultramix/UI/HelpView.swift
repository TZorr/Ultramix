//
//  HelpView.swift
//  Ultramix
//
//  The help window (Help › Ultramix Help, ⌘?): the basics of building a mix,
//  and every shortcut in one place.
//
//  A SwiftUI window rather than an Apple Help Book: a help book is a separate
//  HTML bundle that has to be rebuilt and re-registered on every change, and
//  the help viewer caches it so stubbornly that an updated page often does not
//  appear until the Mac restarts.
//
//  Keep it in step with the code: when a gesture or a key changes, the table
//  here changes with it.
//

import SwiftUI

enum HelpTopic: String, CaseIterable, Identifiable {
    case start, library, clips, tempo, automation, beatgrid, bounce, live, scanner, workspace, settings, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Getting Started"
        case .library: "Library"
        case .clips: "Timeline and Clips"
        case .tempo: "Tempo"
        case .automation: "Automation"
        case .beatgrid: "Beatgrid and BPM"
        case .bounce: "Bounce"
        case .live: "Live"
        case .scanner: "BPM Scanner"
        case .workspace: "Working Directory"
        case .settings: "Settings"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .start: "sparkles"
        case .library: "music.note.list"
        case .clips: "rectangle.split.3x1"
        case .tempo: "metronome"
        case .automation: "slider.horizontal.3"
        case .beatgrid: "waveform"
        case .bounce: "square.and.arrow.up"
        case .live: "dot.radiowaves.left.and.right"
        case .scanner: "tag"
        case .workspace: "externaldrive"
        case .settings: "gearshape"
        case .shortcuts: "command"
        }
    }
}

struct HelpView: View {
    @State private var topic: HelpTopic? = .start

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $topic) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text((topic ?? .start).title).font(.largeTitle.weight(.semibold))
                    content(topic ?? .start)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Ultramix Help")
    }

    // MARK: - Topics

    @ViewBuilder
    private func content(_ topic: HelpTopic) -> some View {
        switch topic {
        case .start: start
        case .library: library
        case .clips: clips
        case .tempo: tempo
        case .automation: automation
        case .beatgrid: beatgrid
        case .bounce: bounce
        case .live: live
        case .scanner: scanner
        case .workspace: workspace
        case .settings: settings
        case .shortcuts: shortcuts
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("Ultramix builds a DJ mix on a beat-based timeline: three lanes, one tempo for the whole mix, and every transition audible while you shape it. The finished set is bounced to WAV or MP3.")
            HelpHeading("A mix in six steps")
            HelpSteps([
                "**Choose a working directory** when Ultramix starts. Everything for your mixes lives in it.",
                "**Add tracks** to the library: drop files or folders on it, or use + (⇧⌘I). Each track is analysed for tempo, bar one and key in the background.",
                "**Put tracks on the timeline**: drag them onto a lane, or double-click them to add each after the last. Clips snap to bar lines, so their beats line up.",
                "**Shape the transitions**: slide clips over each other on different lanes, then apply a transition (⇧⌘X) - Crossfade, Tape Fade, Filter Reveal and more - or draw volume, pan, low-pass and high-pass by hand.",
                "**Set the tempo**: each clip has a tempo point; drag it up or down, and the mix ramps between them.",
                "**Bounce** the mix (⌘B) to WAV or MP3.",
            ])
            HelpHeading("The window")
            HelpKeys([
                ("Top", "Transport, position, tempo and level; Rec; the **tool** (Clips, Volume, Pan, LPF, HPF); follow and zoom."),
                ("Middle", "The ruler, the **tempo** strip and the lanes **A, B, C**, each with mute (M) and solo (S) and two knobs. Click a lane's colour bar to change its colour."),
                ("Bottom", "The selected clip, in two rows: which track, where it sits, its beatgrid, Lock and the Move mode on top; its tempo, gain, loop, mute and crossfade below."),
                ("Beatgrid pane", "Opened between the timeline and the clip rows for one track, with its own waveform, cue points and loop marking; E folds it to a bar and back. See Beatgrid and BPM."),
                ("Right", "The library. The Library toolbar button shows and hides it; the Beatmix button beside it adds the selected tracks at the end of the mix."),
            ])
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("Imported songs are copied into the working directory and analysed for tempo, bar one and key. The BPM column is tinted where a tempo was corrected by hand.")
            HelpKeys([
                ("Drop / +", "Add files or folders (MP3, AAC/M4A, WAV, AIFF, FLAC)."),
                ("Double-click  /  Return", "Add the selected tracks the way the ⏎ menu at the bottom of the library says: Add (after the last clip, 32 beats over it, no points), No Transition, a Beatmix at the end, or At Playhead: Beatmix (one track; into an empty mix or live set it simply goes in first). Add until you choose another."),
                ("Space (in the list)", "Play or stop the mix, as in the timeline. A click in the list gives it the keyboard: ↑ ↓, Return and Space act there until you click the timeline."),
                ("Drag onto a lane", "Add the track at that lane and position."),
                ("Search", "Every word you type, anywhere in artist, title and folder."),
                ("BPM range", "Tick BPM under the search to list only tracks from one tempo to the other, both included. Type a bound or step it a whole BPM; changing a bound switches the range on. Unanalysed tracks are hidden while it is on. It starts off at every launch and remembers its bounds."),
                ("½×2×", "Also list tracks whose half or double tempo is in the BPM range - a 62 BPM track for 122-125."),
                ("⌖ (BPM row)", "Around Selection: set the BPM range to ±2 BPM about the selected track's tempo and switch it on."),
                ("↑ ↓", "Step through the list; while a preview plays, each track is auditioned as you reach it."),
                ("Play (bottom)", "Audition the selected track; the slider seeks. Auditioning pauses the mix - unless Settings › Audio Output gives Audition an output of its own (headphones), where it plays beside the mix and the live set."),
                ("Right-click", "No Transition, Beatmix 4 to 64 (see Timeline and Clips › Beatmix), At Playhead: Beatmix 4 to 64 (one track), Edit Beatgrid…, Correct BPM…, Analyse Again (with the analyser chosen in Settings), Write BPM to File, Remove from Library."),
                ("Key", "The key the analysis hears, as its Camelot code and name (8A Am): the same number, or one either side with the same letter, mixes in key. Dimmed where another key fits almost as well. Click the header to sort round the wheel. It is an estimate - check by ear."),
                ("Right-click the header", "Show or hide columns: BPM, Time, Key, LUFS (the whole song's loudness, before any trim or gain) and Type (the file format). Drag a header to reorder, drag its edge to resize. Ultramix remembers the layout on this Mac."),
            ])
            HelpHeading("Status icons")
            HelpKeys([
                ("●", "The track is in the mix (it cannot be removed from the library)."),
                ("✎", "Beatgrid corrected by hand."),
                ("?", "Low confidence (below 35 %) - worth checking the beatgrid."),
                ("⚠︎", "The file could not be read."),
            ])
        }
    }

    private var clips: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("In the **Clips** tool you arrange the mix. A clip is pinned by its bar one, which snaps to a bar line, so bars stay aligned whatever the intros hold. Two clips cannot overlap on the same lane.")
            HelpHeading("Mouse")
            HelpKeys([
                ("Click a clip", "Select it. The playhead stays where it is."),
                ("Click in empty space", "Move the playhead there, and clear the selection."),
                ("⇧-click", "Add a clip to the selection, or take it out."),
                ("Double-click a clip", "Open its track's beatgrid."),
                ("Drag a clip", "Move it - to the nearest step of the Move mode (a bar line in Full), and to another lane. The whole selection moves together, with the automation drawn on it. A locked clip, or one in the selection, does not move."),
                ("Drag a clip's edge", "Trim it, on quarter beats. On a looping clip the edge extends the loop."),
                ("Drag in empty space", "Nothing - no rectangle, and the playhead stays."),
                ("Click or drag the ruler", "Move the playhead."),
                ("Click a lane's colour bar", "Choose the lane's colour: a swatch, or any colour from the colour well. It is saved with the mix and undoable."),
                ("Pinch", "Zoom."),
            ])
            HelpHeading("Keys")
            HelpKeys([
                ("⌫  /  ⌘⌫", "Delete the selected clips - with the automation drawn on them, including what lies over their trimmed-away part."),
                ("⌥⌫", "Delete only the automation drawn on the selected clips, including what lies over their trimmed-away part; the clips stay."),
                ("← →", "Scroll the timeline; ⇧ scrolls a whole screen."),
                ("⌥← ⌥→", "Move the selected clips a beat, whatever the Move mode. With no clip selected, or a locked clip among them: nothing."),
                ("B  /  ⌘T", "Split the selected clips at the playhead, on the nearest beat."),
                ("⌘D", "Duplicate: to the lane below, above, or next to it."),
                ("L  /  ⌘L", "Loop on or off."),
                ("M  /  ⌃⌘M", "Mute the clip."),
                ("⇧⌘X", "Apply the current transition to the selection's overlaps - or to every transition, with nothing selected."),
                ("Lock (bottom)", "Lock the selected clip: it cannot be dragged, nudged or moved to another lane, and its automation cannot be changed - no points placed, moved or deleted, no movements drawn, ⌥⌫ leaves it, a transition writes only the other clip, and a beatmix adds the next track without fading it. It shows a lock in its title. Trim, gain, tempo, loop, mute, split and delete still work. Saved with the mix; a split or duplicate keeps it. To guard only against moving clips, set Move to Off."),
                ("Move (bottom)", "What dragging a clip snaps to, for every clip: Off - dragging does not move clips; Free - any beat; Half - every half bar; Full - bar lines. Remembered on this Mac."),
                ("Gain − / + (bottom)", "Make the selected clip quieter or louder, 1 dB per click, from −24 to +12 dB. 0 dB plays it as it is. The gain comes before the lane's volume, pan and filters, so fades drawn on it keep working, and a split or duplicate keeps it. A clip with a gain shows it in its title. With the loudness target on, the gain is an offset from the target."),
                ("LUFS (bottom)", "How loud the selected clip plays: integrated loudness (EBU R128) of the part of the song it plays, trims included, with the gain it plays with. The lane's volume, pan and filters are not included. It follows every gain step and trim at once."),
                ("Match (bottom)", "Set the gain, to the whole dB, so the clip is as loud as the clip it mixes out of - the one on another lane playing where it starts - or, with none, the clip that ended last before it. Muted clips are skipped. One undo step; at the end of the gain range it gets as close as it can. Off while the loudness target is on."),
                ("Loudness target (Settings)", "Optional: every clip plays at one loudness, −14 LUFS unless you type another, to 0.1 dB and within −24 … +12 dB of gain. Playback and bounce follow it; the gains in the mix are kept, so switching it off brings them back. It belongs to this Mac, not to the mix."),
                ("LUFS S (top)", "Short-term loudness of the output while playing: the last 3 seconds, after the limiter. It reads about 4 dB below the clip bar's LUFS, because a lane without drawn volume rests at −4 dB - headroom for three lanes summed - and the clip bar leaves the lane out."),
            ])
            HelpText("The plain keys (Space, Tab, B, L, M, + and −, ⌫, arrows) act while the timeline has focus - click it first. Everything is undoable with ⌘Z.")
            HelpHeading("Transitions")
            HelpText("Where a clip on one lane comes in while a clip on another lane is still playing, a transition covers exactly that overlap. Pick one from the Crossfade button's arrow in the clip bar or Clip › Transition; clicking the button or ⇧⌘X applies the current one - to the selected clip's overlaps, or to every transition with nothing selected.")
            HelpKeys(TransitionStyle.allCases.map { ($0.title, $0.summary) })
            HelpText("A transition is written as ordinary volume, pan, low-pass and high-pass points you can reshape afterwards. It replaces the points of those kinds inside the overlap - including ones you drew there - so switching from one transition to another leaves nothing of the first behind.")
            HelpHeading("Beatmix")
            HelpText("A beatmix adds a track and makes its transition in one go. Right-click tracks in the library and choose a Beatmix length, or use the Beatmix button at the top right: a click adds the selected tracks with the current choice, its arrow picks another. No Transition, in the same list, puts the track right after the end instead. Several tracks are chained in the library's order, as one undo step.")
            HelpKeys(BeatmixLength.allCases.map { ($0.title, $0.summary) })
            HelpText("The end of the mix is where the music ends, not the file: silence at the end of a track (below −70 LUFS) does not count, unless the clip loops or is trimmed before it. The beatmix ends on the last bar line the last clip's music reaches, and the new clip's bar one lands where it starts, on another lane. Each clip gets three volume points on whole beats: the outgoing clip goes from its level down by 6 dB and is cut to silence at the end; the incoming clip starts 6 dB below its level and rises to it. Reshape the points by hand, or replace them with a transition (⇧⌘X).")
            HelpText("At Playhead: Beatmix 4 to 64 (library right-click, one track) puts the track into the mix at the playhead instead of at the end. The beatmix starts on the next four-bar line of the record playing there, counted from its bar one and at least one bar ahead, so it can be chosen while the mix plays. The new track's bar one lands there, on another lane. The playing record gets the same three points and is trimmed where the beatmix ends. Every clip that starts later moves by whole bars, so the rest of the mix follows the new track as it followed the old one. The new track also fades out into the next clip, with the same three points: from that clip's bar one to the last bar line of the new track's music.")
        }
    }

    private var tempo: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("The mix has one tempo map. Each clip has a **tempo point** in the tempo strip: the tempo the mix reaches there. Between points the tempo ramps, changing only on beat boundaries, and every clip follows through pitch-preserving time-stretching.")
            HelpKeys([
                ("Drag a point up / down", "Change its tempo, 0.1 BPM per point; with ⇧, 0.01 BPM."),
                ("⌥-drag a point", "Move it to another bar inside its clip."),
                ("Double-click a point", "Back to the track's own tempo."),
                ("Click in the strip", "Set where the ramp into the next point begins - a ◆ on the nearest bar. Until there the old tempo holds."),
                ("Drag a ◆", "Move the ramp start."),
                ("Double-click a ◆", "Remove it: the ramp runs from the previous point again."),
                ("Tempo field (bottom)", "Type the tempo for the selected clip's point, then **Set** or Return."),
                ("Native", "Go back to the track's own tempo."),
            ])
            HelpText("A ramp start belongs to its clip and moves with it.")
            HelpText("A clip is marked when the mix asks it to play below half or above double its own tempo - beyond what stretching does well.")
        }
    }

    private var automation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("Choose **Volume**, **Pan**, **LPF** or **HPF** as the tool to draw on a clip. Automation belongs to the clip and exists only inside it: it moves with the clip, to another lane too, is copied with it, and is deleted with it. Outside every clip a lane rests at −4 dB, centre, both filters out. A point dragged past a clip's edge stops on the edge. Trimming a clip hides the automation over the cut-off part, and extending the clip again brings it back. **LPF** is a low-pass: at the top it is open, lower down it closes towards 90 Hz. **HPF** is a high-pass: at the bottom it is off, higher up it cuts from below, up to 12 kHz. A clip can have both - a band. (Mixes saved before 2026-09-21 had one filter for both; they open without it.)")
            HelpHeading("Recording the knobs")
            HelpText("Switch on **Rec** (the red circle beside Play, or ⌘R) and play the mix: a lane knob you turn - with the mouse or a MIDI controller - writes its movement into the clip under the playhead on its lane, as LPF, HPF, Pan or Volume points over the lane's whole range. It writes while you turn it, and half a second after you stop it lets go and the curve returns to what was drawn there before (Touch). Only inside a clip; a locked clip is not written. While Rec is on you hear the knobs through the automation they write, and when the mix stops the knobs you turned go back to neutral, so nothing counts twice. One run from Play to Stop is one Undo.")
            HelpHeading("Nodes")
            HelpKeys([
                ("Click on a clip", "Place a point, on sixteenth notes. Hold ⌘ to place it freely. A click beside a clip places nothing."),
                ("Drag a point", "Move it, within its clip."),
                ("Drag in empty space", "Select points with a rectangle - across several clips, too."),
                ("⌫", "Delete the selected points and movements."),
                ("⌥-click a point", "Delete it."),
                ("Double-click a point", "Reset it to its resting value: −4 dB, centre, filter out."),
            ])
            HelpHeading("Step, Sine, Triangle")
            HelpKeys([
                ("Drag on a clip", "Draw a repeating movement across the range you drag, cut to the clip. Where you start and where you end set its two levels."),
                ("Period", "The length of one cycle, from 1/16 to bars."),
                ("⇧-drag", "Select with a rectangle."),
                ("⌥-click a movement", "Delete it."),
            ])
            HelpText("Inside a movement's range the movement wins over points.")
        }
    }

    private var beatgrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("Open the beatgrid editor from the library (the chart button at the bottom, or right-click › Edit Beatgrid…) or from a clip (double-click it). **Beatgrid** at the bottom opens the clip or the library track you picked last - a track not yet in the mix too - and pressed again folds the pane away and back. It opens as a pane under the timeline, above the clip's two rows, so the mix stays in sight; drag its top edge to make it taller. **E**, the **Beatgrid** button again, or dragging the top edge well down folds it to a one-line bar that keeps the track, the mark and the span - click the bar or press E again to bring it back. ✕ or Escape closes it. Every change is saved as a correction at once and the mix follows; re-analysis never overwrites it, and **Use Analysis** goes back.")
            HelpText("**Analyser (Settings › Beat Detection).** *Beat This!* is the default: it runs a neural network (Beat This!, CPJKU, small model, MIT) that decides the tempo, whether a beat is on or off the beat, and bar one; the kick fit of the Ultramix analysis then places the lines. *Ultramix* is the app's own analysis on its own, without the network. The choice applies to songs imported afterwards, to right-click › Analyse Again and to **Analyse near**; songs already analysed keep their grid. The line above the editor names Beat This! when it made the grid.")
            HelpKeys([
                ("Click", "Select the nearest gridline (yellow). **Play** starts on it, and ← → step a beat. Play stops the timeline."),
                ("Cycle", "With a stretch marked, Play goes round it until stopped. While it plays, ← → move the stretch's start a beat, ⌥← ⌥→ its end; with ⇧ a bar. The loop follows at once."),
                ("⌥-click a kick", "Put bar one there."),
                ("Span", "How much of the song the strip shows, either side of the middle: ±2, ±5, ±15 or ±30 seconds, picked at the right. Changing it holds the spot being played, or the middle of the view; the bar under the waveform scrolls."),
                ("◎ (beside the span)", "Show the spot of the song that lies under the timeline's playhead. Available while a clip of this song is there."),
                ("Red ticks", "The kicks the analyser hears. On a right grid they sit on the lines; a steady gap means bar one or the tempo is off. A kick that is quiet in the bass - a filtered intro - may get no tick."),
                ("Bar under the waveform", "The whole track, eight bars a cell: green where the kicks sit on the grid, yellow and red as they move off it, grey where there is no steady kick. The outline is the part shown above; click to show another part."),
                ("Align to Kicks", "Shown when the kicks sit early or late on the whole track and moving bar one would put clearly more of them on the lines: moves bar one onto them."),
                ("Intro warning", "Shown when the kicks sit beside the grid at the start, for at least 24 bars, before the grid fits - an intro played differently or in another tempo. **Show** goes there."),
                ("Drift warning", "Shown when the kicks move away from the grid part way through and stay away - a tempo change or an edit. One tempo per track cannot follow it; fit the grid to the part you mix. **Show** goes there."),
                ("Tempo field", "Type a tempo and apply it with **Set** or Return; Escape discards it. Nothing changes while you type, and a change of more than a quarter asks first."),
                ("−0.01 / +0.01", "Nudge the tempo."),
                ("−10 / −1 / +1 / +10 ms", "Nudge bar one."),
                ("◀ Beat  /  Beat ▶", "Move bar one a whole beat - when the grid's one is really the two."),
                ("Metronome", "Click along with the preview to hear the grid."),
                ("Analyse near", "Analyse again, searching only close to the tempo shown."),
            ])
            HelpHeading("Cue points")
            HelpText("Up to eight marks per song, saved with the track: where the next record comes in. Press **1**…**8** to set one where the song is - what is being heard while it plays, the selected gridline while it does not - and press the same number again to go there; **⌥1**…**⌥8** takes one away, and so does ⌥-clicking its button. Drag a flag along the top of the strip to move it. They are set by hand and no analysis ever writes them.")
            HelpText("To use one: select the next track in the library and pick **At Cue: Beatmix N** from its right-click menu, or from the ⏎ menu at the bottom of the library. The beatmix starts at the next cue point of the record being mixed out of - the one playing at the playhead, or the one the mix ends on - rounded to that record's nearest bar line and at least a bar ahead of the playhead. Everything else is the beatmix at the playhead: the old record is cut where the beatmix ends and the rest of the mix follows.")
            HelpHeading("Loops")
            HelpText("Drag across the waveform, or the bar above it, to mark a stretch; drag its ends to resize it, drag the middle of the bar to move it, and **I** and **O** set its start and end where the song is. It snaps to gridlines, with ⌥ for the spot itself. A click on the empty bar clears it.")
            HelpText("**Loop at End** and **Loop at Playhead** then put that stretch into the mix as a looping clip, repeated as often as the **×** menu says, with the beatmix the toolbar is set to. The loop is an ordinary clip: its edges can be dragged, its automation drawn, and ⇧⌘X replaces its transition. The mark itself is not saved - it belongs to the loop being made, not to the record.")
            HelpHeading("How the analysis decides")
            HelpKeys([
                ("Tempo", "Measured from the whole track and fitted through the kicks, to about a millisecond. A measured tempo within a hair of a whole or half BPM - one that moves the grid's ends by 10 ms or less and fits as well - is taken as that round tempo: 127 rather than 126.997."),
                ("Octave", "Half and double tempo are the same pulse to the analysis. In a near tie it leans to the middle of the dance range, so a fast track (174) can come out at half, and a slow one at double. Correct BPM puts it right."),
                ("Bar one", "Where the kick starts to play steadily, and which beat after it brings the most change - bass and chords move on the one. ◀ Beat / Beat ▶ fixes a one that landed on the two."),
                ("Key", "From the notes of the whole track against the 24 keys; see Library › Key."),
                ("New versions", "When an update improves the analysis, tracks are analysed again at launch. Corrections made by hand are kept."),
            ])
            HelpHeading("Correct BPM")
            HelpText("For a tempo an octave out - 87 where the song is 174, or 180 where it is 90. Play the song, tap along on every beat for a few seconds with **T** or the Tap button, and the measured tempo is offered at half, as it is and at double, with the one nearest your taps already chosen. ÷2 and ×2 step by hand; Return uses it.")
            HelpHeading("BPM into the files")
            HelpText("File › Write BPM to All Files writes the tempo into the songs in the working directory - an MP3's ID3 tag to two decimals, an M4A's tag as a whole number. Write BPM to Original Files… does the same to the files you imported from. Nothing else in the files changes, and it only happens on command.")
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("Ultramix › Settings… (⌘,). The settings belong to this Mac, not to a working directory: the same drive on another Mac does not repaint the app there, nor play its mixes at another level.")
            HelpHeading("Appearance")
            HelpText("System, light or dark, and the accent colour. Ultramix draws the tempo curve, the selection rectangle and everything selected with this colour, and tints its own controls with it. The menu bar and the system's own panels keep the system colour.")
            HelpHeading("Beat Detection")
            HelpText("Used for songs imported from now on and for Analyse Again. Beat This!, the default, is a neural network (CPJKU, small model) that decides the tempo, the beat and bar one; Ultramix's kick fit then places the lines. It answers the musical questions - half or double tempo, on or off the beat, which beat is the one - that the kick fit alone cannot. Songs already analysed keep their grid, and a grid corrected by hand is never replaced.")
            HelpHeading("Loudness")
            HelpText("Each clip plays at the target's integrated loudness, −30 to −5 LUFS, measured over the part of its song it plays. The gain − / + buttons then shift a clip from the target, and Match is off. The gains in the mix are kept: switch this off and they play as before. A bounce made on this Mac uses it; the mix file does not store it.")
            HelpHeading("Library")
            HelpText("On, every song is copied into the Audio folder: the working directory holds everything, and the drive works on another Mac. Off, songs outside the working directory are read where they lie - no second copy when they are on the same drive already. They must stay there then: their decoded audio is given back under the cache limit and decoded again from the original, and the permission to read them belongs to this Mac. A song moved on the same drive is still found. The import panel can change this for one import; songs already imported stay as they are.")
            HelpText("**Keep every song decoded** takes the cache limit away: every song is decoded to 32-bit float once and kept, so nothing is decoded and nothing is given back while the music plays - the steadiest playback the drive allows. It applies to every song, copied or read where it lies. Switching it on decodes the whole library in one go, with a bar at the foot of the window and a Stop; it asks first and says how many songs and how many gigabytes. The song files themselves are never touched - the decoded audio is a bare stream of samples and carries no tags, so titles and tempos stay where they belong. Switching it off puts the chosen size back, and what is over it is given back as before.")
            HelpHeading("Audio Cache")
            HelpText("Every song is decoded once to 32-bit float for analysis and playback - about 10 MB a minute, eight times the song file - and kept in the working directory's Cache folder. Above the size chosen the songs used longest ago give their decoded audio back; it is decoded again, in under a second, when the mix, the live set or the library needs it. Songs in the open mix and live set are always kept, even above the limit. Waveforms and loudness stay either way.")
            HelpText("The choice is greyed out while every song is kept decoded: nothing is given back then, so the size decides nothing.")
            HelpHeading("Audio Output")
            HelpKeys([
                ("Interface", "The audio interface both outputs are on. System Output follows the output chosen in System Settings - the default."),
                ("Main Mix", "The stereo pair for the mix and the live set."),
                ("Audition", "The stereo pair for the library, the beatgrid editor and the BPM scanner - headphones, typically."),
            ])
            HelpText("On the same output nothing changes: an audition pauses the mix, and none plays over a running live set. On different outputs you audition in the headphones while the mix or the live set plays on; playing the mix no longer stops an audition. The mix and the live set still never play at once - both are on the main output. An interface that is unplugged falls back to the system output on 1–2 and is used again when it is back.")
            HelpHeading("MIDI Controller")
            HelpText("Every lane header has two knobs, six in all. Each one is a Low-Pass, High-Pass, Pan or Volume, chosen here or in its right-click menu, and shows the value 0…127 its controller sends. They act while the mix or the live set plays, on top of the clip automation - except while Rec is on, when they write it instead (see Automation); a bounce never hears them and a mix never stores them, and they start where they do nothing at every launch: Low-Pass and Volume at 127, High-Pass at 0, Pan at 64.")
            HelpKeys([
                ("Controller", "Tick the MIDI inputs to listen to. A ticked controller that is unplugged is picked up again when it is back. Rescan looks again."),
                ("Learn", "Click Learn beside a knob, then move a control on the controller: its CC number and channel are the knob's from now on. A CC learned for one knob is taken from any other. The × forgets it."),
                ("Function", "A knob that gets a new function starts where that function does nothing. The controller's own knob then jumps the first time it is moved."),
                ("In the lane header", "Drag a knob up or down to turn it; double-click puts it back where it does nothing."),
            ])
        }
    }

    private var bounce: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("File › Bounce Mix… (⌘B) renders the mix with the same engine as playback, faster than real time, and shows the file in Finder when it is done. Muted and soloed lanes are bounced the way you hear them.")
            HelpKeys([
                ("WAV", "16-bit with dither."),
                ("MP3", "320 kbps constant bit rate, with a gapless tag. The ceiling drops to −1 dB."),
                ("Mastering limiter", "Threshold raises the mix, Ceiling caps every peak; release follows the music unless you set it."),
            ])
            HelpText("The settings are remembered. Bounces go to the working directory's Bounces folder by default.")
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("The Live tab holds a set of its own beside the mix: the same timeline, the same beatmixes, and nothing piles up. It holds at most three clips, lets go of what has played, and is never saved.")
            HelpKeys([
                ("Mix | Live  (⌘1 / ⌘2)", "Switch tabs with the toolbar switch or the Transport menu, at any time. Each tab keeps its own document; the live set plays on while you look at or edit the mix."),
                ("One output", "While the live set plays, the mix cannot be played - both would be heard on the main output. Playing the live set pauses the mix. Tracks cannot be auditioned either, unless Audition has an output of its own in Settings › Audio Output: then you audition in the headphones while the set plays on."),
                ("Three clips", "The one playing and the ones waiting to its right - two during a beatmix, one waiting. A fourth is refused until the oldest has played; so is a split or a duplicate that would make four. Add as in a mix: a beatmix at the end, At Playhead, double-click, or drag onto a lane. At Playhead where nothing plays - stopped before the first track, or between two - adds the track at the end with the same beatmix."),
                ("Auto (under the library)", "Whenever nothing waits in the set, the next track of the list as it is on screen - its sort, search and BPM range - goes in with a Beatmix 4 - one bar over the end of the playing track, so there is no pause - and the set never runs empty. It takes the one after the track added last, skips tracks in the set, and never starts a set by itself. Next: shows what it will take. At the end of the list it switches itself off. Off at every launch."),
                ("BPM order", "Sorts the list by tempo, slowest first, so Auto goes up the tempo scale. Switching it off brings the previous sort back; clicking a column header switches it off."),
                ("Tempo while it plays", "Adding a track never changes the tempo of what has already played: a beatmix glides to the new tempo from the next bar, and No Transition and Auto keep each song at its own tempo and step where the new one begins."),
                ("▶ in a lane header", "A clip on that lane is heard at the playhead - two during a beatmix. It shows which lane is playing, wherever the rows have moved it; in a mix too."),
                ("Lane order", "A lane goes to the very bottom the moment it is empty - when its track is let go of, deleted or dragged to another lane - and the others move up in their order. So the next beatmix lands in the row right under the last track, and adding a track moves nothing. A lane keeps its name, colour, mute and solo; only its position changes."),
                ("Letting go", "A bar after a clip ends it leaves the timeline, and the set moves back by whole bars so the beats start again from a small number. The tempo and the sound do not change, and the picture stays where it was. Undo starts over each time."),
                ("When the set ends", "Stopped after the last clip, the set is empty again, ready for the next track."),
                ("Not in Live", "New, Open, Save and Bounce belong to the mix and work in its tab. Quitting asks only about the mix."),
            ])
        }
    }

    private var scanner: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("File › Scan Files for BPM… (⇧⌘B) opens a window of its own. Drop songs, folders or a selection from Music on it, and the tempo is measured and written into the files where they are - nothing is copied, no library and no working directory needed.")
            HelpKeys([
                ("Drop / Choose Files…", "Add songs to scan."),
                ("Sort by BPM", "Tempo groups in a playlist stand out."),
                ("Double-click", "Correct the tempo by tapping; the tag is rewritten."),
                ("Measure tagged files again", "Off: songs that already carry a BPM keep it."),
                ("Right-click", "Correct BPM…, Show in Finder."),
            ])
            HelpText("Music keeps its own copy of what a song's tags said and does not read the file again by itself, so a tempo written afterwards may not show there straight away.")
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpText("Ultramix asks for a working directory every time it starts - the last one is preselected - and File › Switch Working Directory… changes it. Paths are stored relative to it, so the same drive works on another Mac.")
            HelpKeys([
                ("Ultramix Library.json", "The library: tracks, tempo and key analysis, corrections."),
                ("Audio", "Copies of the imported songs."),
                ("Mixes", "Saved mixes (.ultramix). File › Open Mix lists them, newest first."),
                ("Bounces", "WAV and MP3 exports."),
                ("Cache", "Decoded audio, waveforms and loudness - safe to delete; it is rebuilt."),
            ])
            HelpText("**Eject an external drive before unplugging it.** Ultramix closes the working directory when the drive is ejected; pulling the cable while a mix is open can crash it.")
            HelpText("Appearance, accent colour, the beat analyser and the loudness target are in Settings (⌘,) and stay with the Mac.")
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading("Transport")
            HelpKeys([
                ("Space", "Play / Pause"),
                ("⌘R", "Rec on / off: record the lane knobs (Mix tab)"),
                ("Home", "Go to start"),
                ("⌘1  /  ⌘2", "Mix tab / Live tab"),
                ("Tab  /  ⇧Tab", "Next / previous tool: Clips, Volume, Pan, LPF, HPF"),
                ("+  /  −", "Zoom in / out (numeric keypad or main keys); hold to repeat"),
            ])
            HelpHeading("Clips tool")
            HelpKeys([
                ("⌫  or  ⌘⌫", "Delete selected clips and their automation, trimmed part included"),
                ("⌥⌫", "Delete only the selected clips' automation, trimmed part included"),
                ("← →", "Scroll"),
                ("⇧← ⇧→", "Scroll a whole screen"),
                ("⌥← ⌥→", "Move selected clips a beat"),
                ("B  or  ⌘T", "Split at playhead"),
                ("⌘D", "Duplicate"),
                ("L  or  ⌘L", "Loop"),
                ("M  or  ⌃⌘M", "Mute clip"),
                ("⇧⌘X", "Apply the current transition"),
                ("⇧-click", "Add to the selection"),
            ])
            HelpHeading("Automation tools")
            HelpKeys([
                ("⌫", "Delete selected points and movements"),
                ("⌥-click", "Delete one point or movement"),
                ("Double-click", "Reset a point"),
                ("⌘ while placing", "Place without snapping"),
                ("⇧-drag", "Select (Step, Sine, Triangle)"),
            ])
            HelpHeading("Tempo strip")
            HelpKeys([
                ("Drag", "Change tempo, 0.1 BPM per point"),
                ("⇧-drag", "Change tempo, 0.01 BPM per point"),
                ("⌥-drag", "Move the tempo point"),
                ("Double-click a point", "Reset to the track's own tempo"),
                ("Click", "Set a ramp start ◆"),
                ("Double-click a ◆", "Remove the ramp start"),
            ])
            HelpHeading("Files and editing")
            HelpKeys([
                ("⌘N", "New Mix"),
                ("⌘O", "Open…"),
                ("⌘S  /  ⇧⌘S", "Save  /  Save As…"),
                ("⇧⌘I", "Add Tracks to Library…"),
                ("⇧⌘B", "Scan Files for BPM…"),
                ("⌘B", "Bounce Mix…"),
                ("⌘Z  /  ⇧⌘Z", "Undo  /  Redo"),
                ("⌘,", "Settings"),
                ("⌘?", "This help"),
            ])
            HelpHeading("Library and beatgrid")
            HelpKeys([
                ("↑ ↓", "Step through the library"),
                ("T", "Tap in Correct BPM"),
                ("Return", "Use the chosen tempo / Done"),
                ("← →", "Beatgrid editor: select the gridline before / after"),
                ("1 … 8", "Beatgrid editor: set a cue point, or go to it"),
                ("⌥1 … ⌥8", "Beatgrid editor: take that cue point away"),
                ("I  /  O", "Beatgrid editor: mark begins / ends here"),
                ("P", "Beatgrid editor: play from the selected gridline, or round the stretch with Cycle"),
                ("← →  /  ⌥← ⌥→", "Beatgrid editor, Cycle playing: move the stretch's start / end a beat (⇧: a bar)"),
                ("E", "Fold the beatgrid editor down to a bar, and back - or drag its top edge well down"),
                ("Esc", "Close the beatgrid editor"),
            ])
        }
    }
}

// MARK: - Building blocks

private struct HelpHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .padding(.top, 8)
    }
}

/// A paragraph. The text is a localized key so `**bold**` renders.
private struct HelpText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(LocalizedStringKey(text))
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
    }
}

private struct HelpSteps: View {
    let steps: [String]
    init(_ steps: [String]) { self.steps = steps }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                    HelpText(step)
                }
            }
        }
    }
}

/// Two columns: what you press or where, and what it does.
private struct HelpKeys: View {
    let rows: [(String, String)]
    init(_ rows: [(String, String)]) { self.rows = rows }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(verbatim: row.0)
                        .fontWeight(.medium)
                        .frame(minWidth: 150, alignment: .leading)
                    HelpText(row.1)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
            }
        }
    }
}
