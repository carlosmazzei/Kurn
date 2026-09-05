//
//  FakeRecordingLifecycle.swift
//  KurnTests
//
//  Doubles for the two persistence seams `RecorderViewModel` takes in its
//  `init`: a lifecycle saver that fails on a chosen call (to drive the
//  save-failure branches) and a file finalizer that returns scripted metadata
//  or a scripted error instead of probing a real audio file.
//

import Foundation
import SwiftData
@testable import Kurn

@MainActor
final class ScriptedRecordingLifecycleSaver: RecordingLifecycleSaving {
    private let failOnCall: Int?
    private var callCount = 0

    init(failOnCall: Int? = nil) {
        self.failOnCall = failOnCall
    }

    func save(_ context: ModelContext) throws {
        callCount += 1
        if callCount == failOnCall {
            throw CocoaError(.persistentStoreSave)
        }
        try context.save()
    }
}

struct StubRecordingFileFinalizer: RecordingFileFinalizing {
    let result: FinalizedRecordingFile?
    let failure: Error?

    init(result: FinalizedRecordingFile) {
        self.result = result
        failure = nil
    }

    init(failure: Error) {
        result = nil
        self.failure = failure
    }

    func finalize(fileName: String) throws -> FinalizedRecordingFile {
        if let failure { throw failure }
        guard let result else { throw RecordingFileFinalizationError.missing }
        return result
    }
}
