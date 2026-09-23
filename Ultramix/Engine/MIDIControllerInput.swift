//
//  MIDIControllerInput.swift
//  Ultramix
//
//  Listening to MIDI controllers so their Control Changes can turn the lane
//  knobs. Listening only: no output port, no thru, no SysEx, and one input
//  port carries every chosen controller. CoreMIDI needs no sandbox
//  entitlement.
//
//  Each of these was a bug before it was a rule:
//  - Controllers are remembered **by name**, not by CoreMIDI's unique id, and
//    an unplugged one stays *wanted*, so plugging it back in reconnects it.
//  - CoreMIDI's notifications are filtered to the three that can change the
//    list, and a burst of them costs one enumeration.
//  - One parser per source: running status makes a bare data pair meaningful
//    only after its own device's status byte.
//  - The refCon handed to CoreMIDI per source is never freed - a read block
//    may still hold it when the source is disconnected.
//
//  In Engine rather than App so the harness can drive it through a virtual
//  source.
//

import CoreMIDI
import Foundation
import Observation
import os

/// One source that can be listened to.
struct MIDISourceInfo: Identifiable, Hashable {
    /// CoreMIDI's unique id, which survives re-enumeration where an index
    /// does not.
    let id: Int32
    let name: String
    let endpoint: MIDIEndpointRef
}

@Observable
final class MIDIControllerInput {
    static let shared = MIDIControllerInput()

    /// UserDefaults key: the chosen controllers' names, `[String]`.
    nonisolated static let storageKey = "midiControllers"

    /// Everything that could be listened to, as CoreMIDI lists it now.
    private(set) var sources: [MIDISourceInfo] = []
    /// The sources that are open, by unique id.
    private(set) var connectedIDs: Set<Int32> = []
    /// The names chosen in Settings - open or not. See the file header.
    private(set) var wantedNames: Set<String> = []
    /// What went wrong last, if anything.
    private(set) var lastError: String?

    /// Every Control Change that arrives from a connected controller, on
    /// the main actor. Everything else a controller sends is dropped here.
    @ObservationIgnored var onControlChange: ((MIDIControlChange) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var port = MIDIPortRef()
    @ObservationIgnored private var parsers: [Int32: MIDIStreamParser] = [:]
    /// The endpoint each open connection was made to - kept, because a
    /// source that has vanished is no longer in `sources` to look it up.
    @ObservationIgnored private var endpoints: [Int32: MIDIEndpointRef] = [:]
    @ObservationIgnored private var tokens: [Int32: UnsafeMutablePointer<Int32>] = [:]
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private let log = Logger(subsystem: "TZorr.Ultramix", category: "midi")

    /// The open controllers' names, in the order CoreMIDI lists them.
    var connectedNames: [String] {
        sources.filter { connectedIDs.contains($0.id) }.map(\.name)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wantedNames = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
        start()
        refresh()
    }

    deinit {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Creates the client and the one input port. Logged either way: in the
    /// sandbox, "not allowed" and "nothing plugged in" look the same on
    /// screen.
    private func start() {
        let clientStatus = MIDIClientCreateWithBlock("Ultramix" as CFString, &client) { [weak self] notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved:
                break
            default:
                return
            }
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        guard clientStatus == noErr else {
            fail("Could not create the MIDI client (OSStatus \(clientStatus)).")
            return
        }
        // The read block runs on a CoreMIDI thread and hops to the main actor
        // once per packet list, not once per message: a knob sweep is a
        // burst, and a hop each would be scheduling to no purpose.
        let portStatus = MIDIInputPortCreateWithBlock(client, "Ultramix Controllers" as CFString, &port) { [weak self] list, refCon in
            guard let source = refCon?.load(as: Int32.self) else { return }
            let bytes = list.midiBytes
            guard !bytes.isEmpty else { return }
            Task { @MainActor [weak self] in self?.receive(bytes, from: source) }
        }
        guard portStatus == noErr else {
            fail("Could not create the MIDI input port (OSStatus \(portStatus)).")
            return
        }
        log.info("CoreMIDI client and controller port created")
    }

    private func receive(_ bytes: [UInt8], from source: Int32) {
        // A callback can be in flight while its source is disconnected; what
        // it carries is no longer wanted.
        guard parsers[source] != nil else { return }
        let messages = parsers[source]!.feed(bytes)
        for message in messages {
            if let change = message.controlChange { onControlChange?(change) }
        }
    }

    // MARK: - Sources

    /// Coalesces a burst of notifications - a DAW publishing its ports one
    /// at a time - into one enumeration.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    /// Re-reads the sources and opens exactly the wanted ones. Also what
    /// Rescan does, so it reconciles even when the list did not change.
    func refresh() {
        let found: [MIDISourceInfo] = (0..<MIDIGetNumberOfSources()).compactMap { index in
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { return nil }
            var uid: Int32 = 0
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid) == noErr else { return nil }
            return MIDISourceInfo(id: uid, name: Self.displayName(of: endpoint), endpoint: endpoint)
        }
        // Assigned only when different: Observation has no equality check,
        // and Settings redraws on every assignment.
        if found != sources { sources = found }
        reconcile()
    }

    /// Brings what is open into line with what is wanted, touching only
    /// what differs - a notification caused by another app's ports must not
    /// throw away a half-read message.
    private func reconcile() {
        for id in connectedIDs {
            let source = sources.first { $0.id == id }
            if source == nil || !wantedNames.contains(source!.name) { disconnect(id) }
        }
        for source in sources where wantedNames.contains(source.name) && !connectedIDs.contains(source.id) {
            connect(source)
        }
    }

    /// Chooses or releases one controller, leaving the others alone.
    func setController(_ source: MIDISourceInfo, on: Bool) {
        if on { wantedNames.insert(source.name) } else { wantedNames.remove(source.name) }
        defaults.set(wantedNames.sorted(), forKey: Self.storageKey)
        lastError = nil
        reconcile()
        log.info("MIDI controller \(on ? "chosen" : "released", privacy: .public): \(source.name, privacy: .public)")
    }

    func isChosen(_ source: MIDISourceInfo) -> Bool {
        wantedNames.contains(source.name)
    }

    private func connect(_ source: MIDISourceInfo) {
        guard port != 0 else { return }
        let token = tokens[source.id] ?? {
            let fresh = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            fresh.initialize(to: source.id)
            tokens[source.id] = fresh
            return fresh
        }()
        // The parser goes in before the connection: a message can arrive in
        // between, and one that found no parser would be dropped.
        parsers[source.id] = MIDIStreamParser()
        let status = MIDIPortConnectSource(port, source.endpoint, token)
        guard status == noErr else {
            parsers[source.id] = nil
            fail("Could not listen to \(source.name) (OSStatus \(status)).")
            return
        }
        endpoints[source.id] = source.endpoint
        connectedIDs.insert(source.id)
    }

    private func disconnect(_ id: Int32) {
        if let endpoint = endpoints.removeValue(forKey: id) {
            MIDIPortDisconnectSource(port, endpoint)
        }
        parsers[id] = nil
        connectedIDs.remove(id)
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
              let name = value?.takeRetainedValue() as String? else { return "Unknown" }
        return name
    }

    private func fail(_ message: String) {
        lastError = message
        log.error("\(message, privacy: .public)")
    }
}
