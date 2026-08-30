import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct RecorderCaptureOwnershipTests {
    @Test func provisionalOwnershipIsDurableBeforeFileCreation() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Ownership")
        context.insert(meeting)
        try context.save()
        let viewModel = RecorderViewModel(
            meeting: meeting,
            modelContext: context,
            defaultMode: .onDevice
        )

        let recording = try viewModel.prepareCaptureOwnership()
        let fetched = try #require(context.fetch(FetchDescriptor<Recording>()).first)

        #expect(fetched.id == recording.id)
        #expect(fetched.meeting?.id == meeting.id)
        #expect(fetched.captureState == .preparing)
        #expect(fetched.duration == 0)
        #expect(!FileManager.default.fileExists(atPath: fetched.fileURL.path))
        #expect(fetched.fileName.contains(recording.id.uuidString))
    }

    @Test func provisionalSaveFailurePreventsOwnership() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Failure")
        context.insert(meeting)
        try context.save()
        let saver = ScriptedRecordingLifecycleSaver(failOnCall: 1)
        let viewModel = RecorderViewModel(
            meeting: meeting,
            modelContext: context,
            defaultMode: .onDevice,
            lifecycleSaver: saver
        )

        #expect(throws: AppError.self) {
            try viewModel.prepareCaptureOwnership()
        }
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @Test func failedFinalCommitLeavesPreparingStateDurable() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let meeting = Meeting(title: "Final save")
        context.insert(meeting)
        try context.save()
        let saver = ScriptedRecordingLifecycleSaver(failOnCall: 2)
        let finalizer = StubRecordingFileFinalizer(result: FinalizedRecordingFile(duration: 1, fileSize: 128))
        let viewModel = RecorderViewModel(
            meeting: meeting,
            modelContext: context,
            defaultMode: .onDevice,
            fileFinalizer: finalizer,
            lifecycleSaver: saver
        )
        let recording = try viewModel.prepareCaptureOwnership()

        viewModel.finalizeCapture(recording, result: nil)

        #expect(viewModel.error != nil)
        let reloaded = ModelContext(container)
        let durable = try #require(reloaded.fetch(FetchDescriptor<Recording>()).first)
        #expect(durable.captureState == .preparing)
        #expect(durable.duration == 0)
    }

    @Test func meetingFromAnotherContextFailsBeforeInsert() throws {
        let meetingContainer = TestModelContainer.make()
        let meeting = Meeting(title: "Foreign")
        meetingContainer.mainContext.insert(meeting)
        try meetingContainer.mainContext.save()
        let activeContainer = TestModelContainer.make()
        let viewModel = RecorderViewModel(
            meeting: meeting,
            modelContext: activeContainer.mainContext,
            defaultMode: .onDevice
        )

        #expect(throws: AppError.self) {
            try viewModel.prepareCaptureOwnership()
        }
        #expect(try activeContainer.mainContext.fetch(FetchDescriptor<Recording>()).isEmpty)
    }
}

@MainActor
private final class ScriptedRecordingLifecycleSaver: RecordingLifecycleSaving {
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

private struct StubRecordingFileFinalizer: RecordingFileFinalizing {
    let result: FinalizedRecordingFile

    func finalize(fileName: String) throws -> FinalizedRecordingFile {
        result
    }
}
