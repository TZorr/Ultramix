//
//  ImportCopy.swift
//  Ultramix
//
//  Whether an import copies each song into the working directory's Audio
//  folder, or refers to it where it lies.
//
//  Copying is the default and the safe choice: the working directory then
//  holds everything a mix needs. Referring saves the second copy when the
//  songs already live on the same drive, at the price that the original must
//  stay put - the cache gives its decoded audio back under the size limit and
//  decodes again from the original - and that the permission to read it, a
//  security-scoped bookmark, belongs to this Mac. A song moved on the same
//  drive is still found.
//
//  Per Mac, set in Settings, changeable for one import in the import panel. A
//  song already inside the working directory is never copied.
//

import Foundation

nonisolated enum ImportCopy {
    static let storageKey = "copyOnImport"

    static func current(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }
}
