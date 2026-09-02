//
//  ModelVerification.swift
//  Kurn
//
//  H7 PR 16: a third, persisted fact about a downloaded model, distinct from
//  "consented" (an `AppSettings` flag) and "installed" (`ModelStore.isInstalled`,
//  a byte-count check). Neither of those two proves the file is actually
//  usable — PR 15 verifies a transfer's declared size and, when volunteered,
//  its SHA-256, but a bit flip after install, a partial write PR 15's own
//  atomic replace doesn't protect against (this file's format, not that
//  mechanism, being wrong), or manual tampering would still read back as
//  "installed" forever, and only surface the first time a real
//  transcription/diarization run tried to load it.
//
//  Records a lightweight fact instead: the size the model was at the moment
//  a health probe last proved it loads. `state(id:currentSize:)` compares
//  that recorded size against what's on disk now — a full re-hash on every
//  Settings→Storage appearance would mean rereading gigabytes of model
//  weights on every visit, so drift detection is a cheap size comparison,
//  not a routine re-digest. This is a narrower guarantee than PR 15's
//  install-time SHA-256 check and is stated as such, not oversold.
//

import Foundation

/// Whether an installed model has been proven to load, as of the last time
/// anything checked. `.unverified` is not a failure — it is the honest state
/// of every model installed before this PR existed, or of a model this PR's
/// probes don't cover.
enum ModelVerificationState: Equatable {
    case unverified
    case verified(Date)
    case corrupt(reason: String)
}

enum ModelVerification {
    struct Record: Codable, Equatable {
        var verifiedAt: Date
        var sizeAtVerification: Int64
    }

    private static let registryKey = "settings.modelVerificationRecords"

    /// The id a verification record is stored/looked up under — the same
    /// scheme `ModelStore.installedModels()` uses for `InstalledModel.id`,
    /// so a record always lines up with the row it describes. whisper.cpp's
    /// variants are the one group with independently deletable folders
    /// (`ModelGroup.listsFoldersSeparately`), so only they need `folder`.
    static func recordID(for group: ModelStore.ModelGroup, folder: String? = nil) -> String {
        if let folder, group.listsFoldersSeparately {
            return "\(group.rawValue).\(folder)"
        }
        return group.rawValue
    }

    /// Record that a health probe proved the model at `id` loads, at its
    /// current on-disk `size`. Called once, right after a successful probe —
    /// never speculatively.
    static func record(id: String, size: Int64, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var all = registry(defaults: defaults)
        all[id] = Record(verifiedAt: date, sizeAtVerification: size)
        setRegistry(all, defaults: defaults)
    }

    /// Drop any verification record for `id` — called when a model is
    /// deleted, so a later re-download starts from `.unverified` rather than
    /// comparing against a record describing bytes that no longer exist.
    static func clear(id: String, defaults: UserDefaults = .standard) {
        var all = registry(defaults: defaults)
        all[id] = nil
        setRegistry(all, defaults: defaults)
    }

    /// The state to report for a model currently `currentSize` bytes on
    /// disk. A size mismatch against the recorded verification is treated as
    /// corruption rather than merely "needs re-verifying": nothing in this
    /// app ever grows or shrinks an installed model file in place, so any
    /// difference means the bytes changed by some means other than this
    /// app's own verified install path.
    static func state(id: String, currentSize: Int64, defaults: UserDefaults = .standard) -> ModelVerificationState {
        guard let record = registry(defaults: defaults)[id] else { return .unverified }
        guard record.sizeAtVerification == currentSize else {
            return .corrupt(
                reason: "size changed since verification (was \(record.sizeAtVerification) bytes, now \(currentSize))"
            )
        }
        return .verified(record.verifiedAt)
    }

    private static func registry(defaults: UserDefaults) -> [String: Record] {
        guard let data = defaults.data(forKey: registryKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return decoded
    }

    private static func setRegistry(_ registry: [String: Record], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(registry) else { return }
        defaults.set(data, forKey: registryKey)
    }
}
