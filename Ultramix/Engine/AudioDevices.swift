//
//  AudioDevices.swift
//  Ultramix
//
//  The Mac's output devices from Core Audio, and the step that puts an
//  AVAudioEngine on one of them (rules in AudioRouting). A listener on the
//  system object keeps the list current and posts `didChange`, and every
//  engine then checks whether its route moved.
//

import Foundation
import Observation
import CoreAudio
@preconcurrency import AVFoundation

@Observable
final class AudioDevices {
    static let shared = AudioDevices()
    static let didChange = Notification.Name("UltramixAudioDevicesDidChange")

    private(set) var devices: [OutputDevice] = []
    private(set) var systemDefault: OutputDevice?

    private init() {
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    NotificationCenter.default.post(name: Self.didChange, object: nil)
                }
            }
        }
    }

    /// The routing as stored, for one role, on the devices connected now.
    func route(_ role: AudioRouting.Role) -> AudioRouting.Route {
        AudioRouting.current().route(role, devices: devices, systemDefault: systemDefault)
    }

    var isSplit: Bool {
        AudioRouting.current().isSplit(devices: devices, systemDefault: systemDefault)
    }

    private func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids: [AudioDeviceID] = Self.array(system, kAudioHardwarePropertyDevices)
        devices = ids.compactMap { Self.outputDevice($0) }
        let defaultID: AudioDeviceID = Self.value(system, kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        systemDefault = devices.first { $0.id == defaultID }
    }

    private static func outputDevice(_ id: AudioDeviceID) -> OutputDevice? {
        let channels = outputChannels(id)
        guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        // AVAudioEngine makes a private aggregate of the system's output for
        // itself, and it appears in the list once an engine runs (seen as
        // "CADefaultDeviceAggregate-2767-0"). It is nobody's interface.
        guard !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
        let names = (0..<channels).map {
            string(id, kAudioObjectPropertyElementName, scope: kAudioObjectPropertyScopeOutput, element: UInt32($0 + 1)) ?? ""
        }
        return OutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                            channels: channels, channelNames: names)
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, result) == noErr else { return nil }
        return result.pointee
    }

    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!) == noErr
                ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: UInt32 = kAudioObjectPropertyElementMain) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

/// Keeps one AVAudioEngine on its route: at once, and again whenever the
/// setting, the connected devices or the engine's own configuration change.
final class OutputRouter {
    private let engine: AVAudioEngine
    private let role: AudioRouting.Role
    /// The route last applied, and the system's output at the time: a
    /// route on the system's output has to follow it once it is pinned.
    private var applied: (route: AudioRouting.Route, systemDefault: UInt32?)?
    /// Once the engine has been put on a device or a channel map, going
    /// back to the defaults has to be done explicitly as well.
    private var touched = false
    private var observers: [NSObjectProtocol] = []
    private(set) var failure: String?

    /// Routes the engine and starts it.
    init(engine: AVAudioEngine, role: AudioRouting.Role) {
        self.engine = engine
        self.role = role
        apply(restart: true)
        let center = NotificationCenter.default
        for (name, object) in [(UserDefaults.didChangeNotification, nil as AnyObject?),
                               (AudioDevices.didChange, nil),
                               (Notification.Name.AVAudioEngineConfigurationChange, engine)] {
            let restart = name == .AVAudioEngineConfigurationChange
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(restart: restart) }
            })
        }
    }

    /// Stops listening; the engine is stopped by its owner.
    func shutdown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Moves the engine when its route changed. A configuration change
    /// (the device went away, its rate changed) stops the engine, so after
    /// one a stopped engine is started again even on the same route - and
    /// a running one left alone, or routing's own changes would loop.
    private func apply(restart: Bool) {
        let route = AudioDevices.shared.route(role)
        let systemDefault = AudioDevices.shared.systemDefault?.id
        let moved = applied.map { $0.route != route || $0.systemDefault != systemDefault } ?? true
        guard moved || (restart && !engine.isRunning) else { return }
        applied = (route, systemDefault)
        engine.stop()
        // The system's output on channels 1-2, never changed: exactly the
        // engine as it was before routing existed.
        if route.device != nil || route.pair != 0 || touched {
            touched = true
            let target = route.device ?? AudioDevices.shared.systemDefault
            if let unit = engine.outputNode.audioUnit, var id = target?.id {
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if rate > 0, let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) {
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereo)
            }
            if route.channels >= 2 {
                engine.outputNode.auAudioUnit.channelMap =
                    AudioRouting.channelMap(pair: route.pair, channels: route.channels).map { NSNumber(value: $0) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
            failure = nil
        } catch {
            failure = "The audio output could not be started: \(error.localizedDescription)"
        }
    }
}
