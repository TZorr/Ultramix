//
//  AudioRouting.swift
//  Ultramix
//
//  Where the sound goes: one interface, on it one stereo pair for the main mix
//  and one for auditioning - headphones, typically.
//
//  At its defaults - the system's output, both on channels 1-2 - the two share
//  one pair and keep out of each other's way: an audition pauses the mix, and
//  none is allowed over a playing live set. Only when the pairs differ does an
//  audition play beside the mix; that is the headphone cue.
//
//  The choice belongs to the Mac. A missing interface is replaced by the
//  system's output while it is gone, and the choice is kept.
//

import Foundation

/// An output device as the routing sees it.
nonisolated struct OutputDevice: Sendable, Equatable {
    /// The Core Audio object id: valid while the device is connected.
    let id: UInt32
    /// Stable across launches and reconnections; what is stored.
    let uid: String
    let name: String
    let channels: Int
    /// The driver's name for each output channel, "" when it has none.
    var channelNames: [String] = []
}

nonisolated struct AudioRouting: Sendable, Equatable {
    static let deviceKey = "audioOutputDevice"
    /// The chosen interface's name, only to say which one is missing.
    static let deviceNameKey = "audioOutputDeviceName"
    static let mainKey = "mainOutputPair"
    static let auditionKey = "auditionOutputPair"

    /// nil: the system's output, following it when it changes.
    var deviceUID: String?
    /// Stereo pairs, from 0: pair 1 is channels 3-4.
    var mainPair = 0
    var auditionPair = 0

    static func current(_ defaults: UserDefaults = .standard) -> AudioRouting {
        let uid = defaults.string(forKey: deviceKey)
        return AudioRouting(deviceUID: uid?.isEmpty == false ? uid : nil,
                            mainPair: max(0, defaults.integer(forKey: mainKey)),
                            auditionPair: max(0, defaults.integer(forKey: auditionKey)))
    }

    enum Role { case main, audition }

    /// What one engine plays through.
    struct Route: Sendable, Equatable {
        /// nil: the system's output.
        var device: OutputDevice?
        var pair: Int
        /// The device's output channels, for the channel map.
        var channels: Int
    }

    /// The interface that is actually used: the chosen one when it is
    /// connected, nil (the system's output) otherwise.
    func device(in devices: [OutputDevice]) -> OutputDevice? {
        guard let deviceUID else { return nil }
        return devices.first { $0.uid == deviceUID }
    }

    /// The chosen interface is not connected.
    func isMissing(in devices: [OutputDevice]) -> Bool {
        deviceUID != nil && device(in: devices) == nil
    }

    /// The route for one role. A pair the device does not have falls back
    /// to channels 1-2, so a missing interface - or a smaller one - never
    /// leaves an output silent.
    func route(_ role: Role, devices: [OutputDevice], systemDefault: OutputDevice?) -> Route {
        let device = device(in: devices)
        let channels = (device ?? systemDefault)?.channels ?? 2
        let wanted = role == .main ? mainPair : auditionPair
        let pair = Self.pairCount(channels: channels) > wanted ? wanted : 0
        return Route(device: device, pair: pair, channels: channels)
    }

    /// Main mix and audition on different outputs: auditioning no longer
    /// has to pause the mix.
    func isSplit(devices: [OutputDevice], systemDefault: OutputDevice?) -> Bool {
        route(.main, devices: devices, systemDefault: systemDefault).pair
            != route(.audition, devices: devices, systemDefault: systemDefault).pair
    }

    /// Whole stereo pairs; an odd last channel is not offered. A mono
    /// device still gets its one "pair", played in mono by the system.
    static func pairCount(channels: Int) -> Int {
        max(1, channels / 2)
    }

    /// The channel map for the output unit: for each device channel, the
    /// stereo channel it plays (0 left, 1 right), or −1 for none.
    static func channelMap(pair: Int, channels: Int) -> [Int] {
        var map = Array(repeating: -1, count: max(channels, 2))
        map[2 * pair] = 0
        map[2 * pair + 1] = 1
        return map
    }

    /// "1-2", "3-4" …, with the driver's name for the pair when it has one:
    /// "3-4 · Phones 1" for "Phones 1 L" / "Phones 1 R". Plain numbers, as
    /// some drivers give, are not names.
    static func pairLabel(_ pair: Int, names: [String]) -> String {
        let numbers = "\(2 * pair + 1)–\(2 * pair + 2)"
        func name(_ i: Int) -> String {
            guard i < names.count else { return "" }
            let n = names[i].trimmingCharacters(in: .whitespaces)
            return n.allSatisfy(\.isNumber) ? "" : n
        }
        let left = name(2 * pair), right = name(2 * pair + 1)
        guard !left.isEmpty || !right.isEmpty else { return numbers }
        let l = strippedSide(left), r = strippedSide(right)
        if !l.isEmpty && l == r { return "\(numbers) · \(l)" }
        return "\(numbers) · \([left, right].filter { !$0.isEmpty }.joined(separator: " / "))"
    }

    /// "Phones 1 L" → "Phones 1"; a name without a side stays as it is.
    private static func strippedSide(_ name: String) -> String {
        for suffix in [" Left", " Right", " L", " R", " left", " right"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }
}
