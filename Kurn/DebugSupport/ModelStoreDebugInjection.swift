//
//  ModelStoreDebugInjection.swift
//  Kurn
//
//  DEBUG-only synthetic store-open failures, so `KurnUITests` can exercise
//  every `ModelStoreOpenFailureReason` the H2 boot state machine classifies
//  (docs/resilience-megaplan.md) without a real locked device, full disk,
//  incompatible schema, or corrupt store file. `KurnApp.makeStore()` throws
//  one of these when launched with the matching
//  `UI_TESTING_STORE_OPEN_FAILURE_REASON` launch environment value. Compiled
//  out of Release builds entirely, alongside `ScreenshotSeedData`.
//

#if DEBUG
import CoreData
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ModelStoreDebugInjection {
    /// An error carrying exactly the signature
    /// `ModelStoreOpenFailureClassifier` looks for, so a UI test exercises
    /// the real classifier rather than a hardcoded state.
    static func error(for reason: ModelStoreOpenFailureReason) -> Error {
        switch reason {
        case .protectedDataUnavailable:
            return NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        case .storageFull:
            return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        case .migrationIncompatible:
            return NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)
        case .corruptOrUnknown:
            return NSError(domain: "ai.kurn.debug.syntheticStoreOpenFailure", code: -1)
        case .protectionVerificationFailed:
            // Not reachable via the classifier — ModelStoreBootCoordinator
            // produces this reason directly when its post-open
            // `verifyProtectionAfterOpen` step throws, never from a thrown
            // `makeStore()` error. Included only so this switch stays
            // exhaustive as `ModelStoreOpenFailureReason` grows.
            return NSError(domain: "ai.kurn.debug.syntheticStoreOpenFailure", code: -2)
        }
    }
}
#endif
