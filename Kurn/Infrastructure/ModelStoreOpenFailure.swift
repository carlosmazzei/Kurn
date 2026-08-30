//
//  ModelStoreOpenFailure.swift
//  Kurn
//
//  Classifies a `ModelContainer` construction failure into one of the four
//  reasons docs/resilience-megaplan.md's H2 PR 3 names — protected data
//  unavailable, storage full, an incompatible migration, or everything else —
//  so the boot coordinator can react differently instead of guessing.
//
//  The classifier only ever narrows toward `.corruptOrUnknown`: every branch
//  requires a specific, well-known Foundation/CoreData/POSIX error signature,
//  and anything that doesn't match falls through to the safe default rather
//  than being asserted as a specific cause. A wrong classification here means
//  a slightly imprecise reason shown to the user, never a crash and never a
//  silently created empty store — the two things this PR actually guards
//  against.
//

import CoreData
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The four launch-blocking reasons a store can fail to open, per the
/// megaplan's "Classify open failures without guessing" requirement.
enum ModelStoreOpenFailureReason: String, Sendable, CaseIterable {
    case protectedDataUnavailable
    case storageFull
    case migrationIncompatible
    case corruptOrUnknown
}

/// A classified store-open failure. Deliberately carries no free-text
/// description — `logCode` is content-free like `AppError.logCode`, and the
/// recovery UI's copy is keyed off `reason` alone, never off the raw error.
struct ModelStoreOpenFailure: Sendable, Equatable {
    let reason: ModelStoreOpenFailureReason

    init(reason: ModelStoreOpenFailureReason) {
        self.reason = reason
    }

    init(classifying error: Error) {
        self.reason = ModelStoreOpenFailureClassifier.classify(error)
    }

    var logCode: String { "model_store_open.\(reason.rawValue)" }
}

/// Pure classification over an `Error`'s NSError bridge, so it is testable
/// against hand-built `NSError`s without touching a real store.
enum ModelStoreOpenFailureClassifier {
    static func classify(_ error: Error) -> ModelStoreOpenFailureReason {
        let nsError = error as NSError
        if matches(nsError, protectedDataUnavailableSignatures) { return .protectedDataUnavailable }
        if matches(nsError, storageFullSignatures) { return .storageFull }
        if matches(nsError, migrationIncompatibleSignatures) { return .migrationIncompatible }
        return .corruptOrUnknown
    }

    /// `EPERM`/permission-denied surfaces when the process tries to open a
    /// Data-Protected file before the device has been unlocked since boot —
    /// the classic "background launch while locked" signature.
    private static let protectedDataUnavailableSignatures: [ErrorSignature] = [
        ErrorSignature(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    ]

    private static let storageFullSignatures: [ErrorSignature] = [
        ErrorSignature(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    ]

    /// Core Data's own migration/version-hash mismatch codes — thrown when
    /// the store's schema doesn't match the requested one and no migration
    /// stage bridges them.
    private static let migrationIncompatibleSignatures: [ErrorSignature] = [
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSMigrationError),
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSMigrationCancelledError),
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSMigrationMissingSourceModelError),
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSMigrationMissingMappingModelError),
        ErrorSignature(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)
    ]

    private struct ErrorSignature {
        let domain: String
        let code: Int
    }

    /// Checks the error itself, then walks `NSUnderlyingErrorKey` — SwiftData/
    /// Core Data commonly wrap the real POSIX/SQLite cause one level down.
    /// Bounded depth so a cyclical or pathological `userInfo` can't loop.
    private static func matches(_ error: NSError, _ signatures: [ErrorSignature], depth: Int = 0) -> Bool {
        guard depth < 5 else { return false }
        if signatures.contains(where: { $0.domain == error.domain && $0.code == error.code }) {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return matches(underlying, signatures, depth: depth + 1)
    }
}
