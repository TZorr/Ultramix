//
//  MP4Tag.swift
//  Ultramix
//
//  Writes a BPM into an M4A without disturbing a byte that is not the BPM.
//  iTunes metadata sits at moov/udta/meta/ilst/tmpo/data, where `tmpo` is a
//  big-endian integer - whole numbers only.
//
//  One editing operation: replace a range of bytes. Replacing an existing
//  tempo moves nothing; adding one shifts everything after `ilst` by 26, so
//  every enclosing atom grows by that and every chunk offset past the
//  insertion (stco, co64) moves with it. Files come with moov before and after
//  mdat; the same rule covers both.
//
//  Not an AVAssetExportSession pass-through: that drops the `----` atoms other
//  programs keep their data in.
//

import Foundation

nonisolated enum MP4Tag {
    /// The file with `bpm` in its tempo atom, or nil when it is already
    /// there. Throws `TagError.unsupported` for anything that does not parse.
    static func writingBPM(_ bpm: Int, into data: Data) throws -> Data? {
        let value = min(max(bpm, 0), 0xFFFF)
        guard let moov = try atoms(in: data, from: 0, to: data.count).first(where: { $0.type == "moov" }) else {
            throw TagError.unsupported("the file has no moov atom")
        }

        let site = try tempoSite(data, moov)
        if case .replace(let atom) = site.kind, try tempo(data, atom) == value { return nil }

        let replacement = site.wrap(tempoAtom(value))
        let range = site.range
        let delta = replacement.count - (range.upperBound - range.lowerBound)

        var out = data
        if delta != 0 {
            try moveChunkOffsets(&out, in: moov, pastAndIncluding: range.lowerBound, by: delta)
            for atom in site.ancestors { try resize(&out, atom, by: delta) }
        }
        out.replaceSubrange(range, with: replacement)
        return out
    }

    /// The tempo in the file's tag, for checking a write.
    static func readBPM(_ data: Data) -> Int? {
        guard let top = try? atoms(in: data, from: 0, to: data.count),
              let moov = top.first(where: { $0.type == "moov" }),
              let site = try? tempoSite(data, moov),
              case .replace(let atom) = site.kind,
              let value = try? tempo(data, atom) else { return nil }
        return value
    }

    // MARK: - Atoms

    private struct Atom {
        let type: String
        /// Offset of the size field.
        let start: Int
        let headerSize: Int
        let size: Int

        var end: Int { start + size }
        var contentStart: Int { start + headerSize }
    }

    private static func atoms(in data: Data, from start: Int, to end: Int) throws -> [Atom] {
        var result: [Atom] = []
        var offset = start
        while offset + 8 <= end {
            var size = Int(read32(data, offset))
            var header = 8
            let type = String(decoding: data[data.startIndex + offset + 4 ..< data.startIndex + offset + 8],
                              as: UTF8.self)
            if size == 1 {
                guard offset + 16 <= end else { throw TagError.unsupported("a truncated atom") }
                // Int(_:) traps above Int.max, and this is a number out of
                // the file: a refusal, not a crash.
                guard let wide = Int(exactly: read64(data, offset + 8)) else {
                    throw TagError.unsupported("an atom's length is not readable")
                }
                size = wide
                header = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= header, offset + size <= end else {
                throw TagError.unsupported("an atom reaches past its parent")
            }
            result.append(Atom(type: type, start: offset, headerSize: header, size: size))
            offset += size
        }
        return result
    }

    /// `meta` is a full atom: four version-and-flags bytes come before its
    /// children. Everything else here holds its children straight away.
    private static func children(_ data: Data, of atom: Atom) throws -> [Atom] {
        let start = atom.contentStart + (atom.type == "meta" ? 4 : 0)
        return try atoms(in: data, from: start, to: atom.end)
    }

    private static func child(_ data: Data, of atom: Atom, _ type: String) throws -> Atom? {
        try children(data, of: atom).first { $0.type == type }
    }

    // MARK: - Where the tempo goes

    private struct Site {
        enum Kind {
            /// An existing tempo atom, replaced as a whole.
            case replace(Atom)
            /// Nothing there yet: the new atom goes in at this offset, inside
            /// whatever containers `build` still has to create around it.
            case insert(at: Int, chain: Chain)
        }
        enum Chain { case intoList, intoMeta, intoUdta, intoMoov }

        var kind: Kind
        var ancestors: [Atom]

        var range: Range<Int> {
            switch kind {
            case .replace(let atom): return atom.start..<atom.end
            case .insert(let at, _): return at..<at
            }
        }

        /// The tempo atom with the containers around it that do not exist yet.
        func wrap(_ tempo: [UInt8]) -> [UInt8] {
            guard case .insert(_, let chain) = kind else { return tempo }
            switch chain {
            case .intoList: return tempo
            case .intoMeta: return atom("ilst", tempo)
            case .intoUdta: return atom("meta", [0, 0, 0, 0] + handler() + atom("ilst", tempo))
            case .intoMoov: return atom("udta", atom("meta", [0, 0, 0, 0] + handler() + atom("ilst", tempo)))
            }
        }
    }

    private static func tempoSite(_ data: Data, _ moov: Atom) throws -> Site {
        guard let udta = try child(data, of: moov, "udta") else {
            return Site(kind: .insert(at: moov.end, chain: .intoMoov), ancestors: [moov])
        }
        guard let meta = try child(data, of: udta, "meta") else {
            return Site(kind: .insert(at: udta.end, chain: .intoUdta), ancestors: [udta, moov])
        }
        guard let list = try child(data, of: meta, "ilst") else {
            return Site(kind: .insert(at: meta.end, chain: .intoMeta), ancestors: [meta, udta, moov])
        }
        let ancestors = [list, meta, udta, moov]
        guard let tempo = try child(data, of: list, "tmpo") else {
            return Site(kind: .insert(at: list.end, chain: .intoList), ancestors: ancestors)
        }
        return Site(kind: .replace(tempo), ancestors: ancestors)
    }

    /// The number in an existing tempo atom, whatever width it was written
    /// with - one byte, two, or four.
    private static func tempo(_ data: Data, _ atom: Atom) throws -> Int? {
        guard let value = try child(data, of: atom, "data") else { return nil }
        let start = value.contentStart + 8   // version and flags, then the locale
        guard start < value.end, value.end - start <= 4 else { return nil }
        var result = 0
        for i in start..<value.end { result = result << 8 | Int(data[data.startIndex + i]) }
        return result
    }

    /// Writes an atom's new size, in the width its header uses. A size that
    /// no longer fits that width is refused rather than truncated: the file
    /// would need a 64-bit header this code does not grow.
    private static func resize(_ data: inout Data, _ atom: Atom, by delta: Int) throws {
        let size = atom.size + delta
        if atom.headerSize == 16 {
            guard let value = UInt64(exactly: size) else {
                throw TagError.unsupported("an atom would grow past what its header can hold")
            }
            write64(&data, at: atom.start + 8, value)
        } else {
            guard let value = UInt32(exactly: size) else {
                throw TagError.unsupported("an atom would grow past what its header can hold")
            }
            write32(&data, at: atom.start, value)
        }
    }

    // MARK: - Chunk offsets

    private static func moveChunkOffsets(_ data: inout Data, in moov: Atom,
                                         pastAndIncluding point: Int, by delta: Int) throws {
        for table in try tables(data, in: moov) {
            let count = Int(read32(data, table.contentStart + 4))
            let wide = table.type == "co64"
            let width = wide ? 8 : 4
            let first = table.contentStart + 8
            guard first + count * width <= table.end else {
                throw TagError.unsupported("a chunk offset table is longer than its atom")
            }
            for i in 0..<count {
                let at = first + i * width
                let raw = wide ? read64(data, at) : UInt64(read32(data, at))
                // Numbers out of the file, so every conversion is checked:
                // an offset that does not fit, or one that would not fit
                // its own width once moved, is a refusal rather than a trap.
                guard let value = Int(exactly: raw) else {
                    throw TagError.unsupported("a chunk offset is not readable")
                }
                guard value >= point else { continue }
                let moved = value + delta
                if wide {
                    guard let out = UInt64(exactly: moved) else {
                        throw TagError.unsupported("a chunk offset would not fit its table")
                    }
                    write64(&data, at: at, out)
                } else {
                    guard let out = UInt32(exactly: moved) else {
                        throw TagError.unsupported("a chunk offset would not fit its table")
                    }
                    write32(&data, at: at, out)
                }
            }
        }
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "udta"]

    private static func tables(_ data: Data, in atom: Atom) throws -> [Atom] {
        var found: [Atom] = []
        for child in try children(data, of: atom) {
            if child.type == "stco" || child.type == "co64" {
                found.append(child)
            } else if containers.contains(child.type) {
                found += try tables(data, in: child)
            }
        }
        return found
    }

    // MARK: - Building

    /// `tmpo` holding a `data` atom of type 21 - a big-endian signed
    /// integer - with the tempo in two bytes, which is how iTunes writes it.
    private static func tempoAtom(_ value: Int) -> [UInt8] {
        let payload: [UInt8] = [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return atom("tmpo", atom("data", [0, 0, 0, 21] + [0, 0, 0, 0] + payload))
    }

    /// The handler a metadata atom needs: 'mdir' from 'appl', and no name.
    private static func handler() -> [UInt8] {
        atom("hdlr", [0, 0, 0, 0] + [0, 0, 0, 0] + Array("mdirappl".utf8) + [UInt8](repeating: 0, count: 9))
    }

    private static func atom(_ type: String, _ content: [UInt8]) -> [UInt8] {
        let size = content.count + 8
        return [UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
                UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)] + Array(type.utf8) + content
    }

    // MARK: - Numbers

    private static func read32(_ data: Data, _ at: Int) -> UInt32 {
        let i = data.startIndex + at
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }

    private static func read64(_ data: Data, _ at: Int) -> UInt64 {
        UInt64(read32(data, at)) << 32 | UInt64(read32(data, at + 4))
    }

    private static func write32(_ data: inout Data, at: Int, _ value: UInt32) {
        let i = data.startIndex + at
        data[i] = UInt8(truncatingIfNeeded: value >> 24)
        data[i + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[i + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[i + 3] = UInt8(truncatingIfNeeded: value)
    }

    private static func write64(_ data: inout Data, at: Int, _ value: UInt64) {
        write32(&data, at: at, UInt32(truncatingIfNeeded: value >> 32))
        write32(&data, at: at + 4, UInt32(truncatingIfNeeded: value))
    }
}
