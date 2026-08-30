//
//  ModelStoreOpenFailureClassifierTests.swift
//  KurnTests
//
//  Pins the H2 boot state machine's failure classification
//  (docs/resilience-megaplan.md, PR 3) against hand-built `NSError`s carrying
//  the exact Foundation/CoreData/POSIX signatures the classifier looks for —
//  this is the part of the boot machinery that is meaningfully unit-testable
//  without a real locked device, full disk, or corrupt store.
//

import CoreData
import Foundation
import Testing
@testable import Kurn

struct ModelStoreOpenFailureClassifierTests {

    @Test func classifiesPOSIXPermissionDeniedAsProtectedDataUnavailable() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        #expect(ModelStoreOpenFailureClassifier.classify(error) == .protectedDataUnavailable)
    }

    @Test func classifiesCocoaFileReadNoPermissionAsProtectedDataUnavailable() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(ModelStoreOpenFailureClassifier.classify(error) == .protectedDataUnavailable)
    }

    @Test func classifiesPOSIXNoSpaceAsStorageFull() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(ModelStoreOpenFailureClassifier.classify(error) == .storageFull)
    }

    @Test func classifiesCocoaOutOfSpaceAsStorageFull() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        #expect(ModelStoreOpenFailureClassifier.classify(error) == .storageFull)
    }

    @Test func classifiesMigrationErrorAsMigrationIncompatible() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSMigrationError)
        #expect(ModelStoreOpenFailureClassifier.classify(error) == .migrationIncompatible)
    }

    @Test func classifiesIncompatibleVersionHashAsMigrationIncompatible() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)
        #expect(ModelStoreOpenFailureClassifier.classify(error) == .migrationIncompatible)
    }

    @Test func classifiesUnrecognizedErrorAsCorruptOrUnknown() {
        let error = NSError(domain: "some.unrelated.domain", code: -999)
        #expect(ModelStoreOpenFailureClassifier.classify(error) == .corruptOrUnknown)
    }

    @Test func classifiesGenericSwiftErrorAsCorruptOrUnknown() {
        struct SomeSwiftError: Error {}
        #expect(ModelStoreOpenFailureClassifier.classify(SomeSwiftError()) == .corruptOrUnknown)
    }

    @Test func unwrapsUnderlyingErrorOneLevel() {
        // SwiftData/Core Data commonly wrap the real POSIX/SQLite cause one
        // level down under `NSUnderlyingErrorKey`.
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: NSCoreDataError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(ModelStoreOpenFailureClassifier.classify(wrapper) == .storageFull)
    }

    @Test func stopsUnwrappingBeyondTheBoundedDepth() {
        // A chain deeper than the classifier's recursion bound, with a
        // matching signature only at the very bottom — proves the depth
        // guard actually stops early rather than being purely decorative,
        // without needing a (KVC-unsafe) self-referencing NSError.
        var current: NSError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        for _ in 0..<10 {
            current = NSError(domain: "wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: current])
        }
        #expect(ModelStoreOpenFailureClassifier.classify(current) == .corruptOrUnknown)
    }

    @Test func failureLogCodeIsContentFreeAndStable() {
        let failure = ModelStoreOpenFailure(reason: .storageFull)
        #expect(failure.logCode == "model_store_open.storageFull")
    }
}
