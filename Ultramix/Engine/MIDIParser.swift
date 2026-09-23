//
//  MIDIParser.swift
//  Ultramix
//
//  Arriving MIDI bytes back into messages: the byte-stream parser and the
//  packet-list reader, trimmed to what the lane knobs need. No NRPN decoder -
//  it would swallow CC 99 and CC 98 and make those two unlearnable for nothing.
//
//  Every type is `nonisolated`: the parser is fed on a CoreMIDI thread.
//

import CoreMIDI
import Foundation

/// One message as it arrived, before anyone has decided what it means.
nonisolated struct RawMIDIMessage: Equatable {
    /// The status byte, with its channel nibble still in it.
    let status: UInt8
    let data: [UInt8]

    /// 1...16, or nil for a system message which has no channel.
    var channel: Int? {
        status < 0xF0 ? Int(status & 0x0F) + 1 : nil
    }

    var isControlChange: Bool { status & 0xF0 == 0xB0 }

    /// The Control Change this is, or nil for anything else.
    var controlChange: MIDIControlChange? {
        guard isControlChange, data.count == 2, let channel else { return nil }
        return MIDIControlChange(channel: channel, controller: Int(data[0]), value: Int(data[1]))
    }
}

/// A Control Change, in the terms a knob is assigned by: channel 1…16,
/// controller number 0…127, value 0…127.
nonisolated struct MIDIControlChange: Equatable, Sendable {
    let channel: Int
    let controller: Int
    let value: Int
}

/// Bytes in, messages out.
///
/// Stateful on purpose, and one instance per source: a message can be split
/// across packets, and running status means a data-only packet is
/// meaningful *because* of what came before it. Two controllers sharing a
/// parser would hand each other their halves.
nonisolated struct MIDIStreamParser {
    /// The most a single incoming SysEx may grow to before it is abandoned.
    /// Nothing here reads SysEx, but a controller may still send some (a
    /// device inquiry answer, a scene dump), and its bytes have to be
    /// consumed rather than read as data for the next CC. 1 MB is far above
    /// anything real - a guard against a device that sends 0xF0 and stops.
    static let maxSysExBytes = 1 << 20

    private var runningStatus: UInt8?
    private var expectedDataCount = 0
    private var data: [UInt8] = []
    private var sysex: [UInt8]?

    /// How many data bytes a channel-voice status takes. Program Change and
    /// Channel Pressure take one; everything else takes two.
    private static func dataCount(for status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: 1
        default: 2
        }
    }

    /// How many a System Common message takes, so its data bytes are
    /// consumed rather than mistaken for the next message's.
    private static func systemCommonDataCount(for status: UInt8) -> Int {
        switch status {
        case 0xF1, 0xF3: 1  // MTC quarter frame, Song Select
        case 0xF2: 2        // Song Position Pointer
        default: 0          // Tune Request, and the rest
        }
    }

    mutating func feed(_ bytes: some Sequence<UInt8>) -> [RawMIDIMessage] {
        var messages: [RawMIDIMessage] = []
        for byte in bytes {
            // System Real Time (0xF8...0xFF) may appear *inside* another
            // message and does not disturb it. A controller with a clock
            // output sends Clock 24 times a beat, often between the two
            // data bytes of the CC being turned.
            if byte >= 0xF8 { continue }

            if byte == 0xF7 {
                // End of a SysEx. A stray one with no start is ignored.
                if var payload = sysex {
                    sysex = nil
                    payload.append(byte)
                    payload.removeFirst()               // the 0xF0 is framing here
                    messages.append(RawMIDIMessage(status: 0xF0, data: payload))
                }
                continue
            }

            if byte >= 0x80 {
                // Any other status byte ends an unterminated SysEx: the
                // payload is incomplete, so it is dropped.
                sysex = nil

                if byte == 0xF0 {
                    sysex = [byte]
                    runningStatus = nil
                } else if byte >= 0xF0 {
                    // System Common: no running status survives it.
                    runningStatus = nil
                    expectedDataCount = Self.systemCommonDataCount(for: byte)
                    data = []
                } else {
                    runningStatus = byte
                    expectedDataCount = Self.dataCount(for: byte)
                    data = []
                }
                continue
            }

            // A data byte.
            if sysex != nil {
                if sysex!.count >= Self.maxSysExBytes {
                    sysex = nil
                    continue
                }
                sysex!.append(byte)
                continue
            }
            // Orphaned - no status has been seen, so there is nothing to
            // attach it to.
            guard let status = runningStatus else { continue }
            data.append(byte)
            if data.count == expectedDataCount {
                messages.append(RawMIDIMessage(status: status, data: data))
                // Running status persists: a knob sweep is mostly bare data
                // pairs after one status byte, which is the point of it.
                data = []
            }
        }
        return messages
    }
}

extension UnsafePointer<MIDIPacketList> {
    /// Every byte in the list, packets concatenated in order.
    ///
    /// One stream and not one array per packet, because a packet boundary
    /// means nothing: CoreMIDI coalesces messages sent close together into
    /// one packet and may split one across two. The parser finds them again.
    ///
    /// Read through pointers, never through a copy of the packet: a
    /// `MIDIPacket` value carries only the 256 bytes its struct declares,
    /// while a real packet's data may run on past that. A controller never
    /// sends a packet that long, but reading it right costs nothing.
    nonisolated var midiBytes: [UInt8] {
        var bytes: [UInt8] = []
        var packet = UnsafeRawPointer(self).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!)
            .assumingMemoryBound(to: MIDIPacket.self)
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
        for _ in 0..<pointee.numPackets {
            let length = Int(packet.pointee.length)
            let data = UnsafeRawPointer(packet).advanced(by: dataOffset)
            bytes.append(contentsOf: UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: length))
            // Spelled out: inside this extension a bare `UnsafePointer(...)`
            // means a pointer to a MIDIPacketList.
            packet = UnsafePointer<MIDIPacket>(MIDIPacketNext(packet))
        }
        return bytes
    }
}
