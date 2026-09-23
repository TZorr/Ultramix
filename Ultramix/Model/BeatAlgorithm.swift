//
//  BeatAlgorithm.swift
//  Ultramix
//
//  Which analyser finds a track's grid: Ultramix's own (`TempoAnalyzer`), or
//  the Beat This! network with Ultramix's kick fit (`BeatThisAnalyzer`, the
//  default). Chosen in Settings, per Mac; it applies to tracks imported
//  afterwards and to Analyse Again. A track keeps the analyser that last
//  analysed it.
//

import Foundation

nonisolated enum BeatAlgorithm: String, CaseIterable, Identifiable, Codable, Sendable {
    case ultramix, beatThis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultramix: "Ultramix"
        case .beatThis: "Beat This!"
        }
    }

    /// The version a track analysed by this analyser must have, or it is
    /// analysed again at launch - by this analyser.
    var version: Int {
        switch self {
        case .ultramix: TempoAnalyzer.version
        case .beatThis: BeatThisAnalyzer.version
        }
    }

    static let storageKey = "beatAlgorithm"

    /// What a Mac that has never been told analyses with: the network,
    /// for the musical questions the kick fit cannot answer. It changes
    /// nothing about tracks already analysed - those keep their own
    /// analyser.
    static let fallback = BeatAlgorithm.beatThis

    static func stored(in defaults: UserDefaults = .standard) -> BeatAlgorithm {
        defaults.string(forKey: storageKey).flatMap(BeatAlgorithm.init) ?? fallback
    }

    /// The analyser chosen on this Mac.
    static var current: BeatAlgorithm {
        get { stored() }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}
