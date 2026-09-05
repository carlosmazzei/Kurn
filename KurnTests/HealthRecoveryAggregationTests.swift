//
//  HealthRecoveryAggregationTests.swift
//  KurnTests
//
//  The selection rules behind Health & Recovery, run against an in-memory
//  store: which recordings each section lists and how rows are described.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct HealthRecoveryAggregationTests {

    private let container: ModelContainer
    private let context: ModelContext

    init() {
        container = TestModelContainer.make()
        context = container.mainContext
    }

    @discardableResult
    private func insertRecording(
        title: String = "Meeting",
        captureState: RecordingCaptureState = .ready,
        transcriptionStatus: TranscriptionStatus = .none,
        recordedAt: Date = Date()
    ) -> Recording {
        let meeting = Meeting(title: title)
        context.insert(meeting)
        let recording = Recording(
            meeting: meeting,
            fileName: "\(UUID().uuidString).m4a",
            duration: 10,
            recordedAt: recordedAt,
            transcriptionStatus: transcriptionStatus,
            captureState: captureState
        )
        context.insert(recording)
        return recording
    }

    private func report(_ stages: [(PipelineStage, PipelineStageOutcome)]) -> PipelineReport {
        var builder = PipelineReportBuilder()
        for (stage, outcome) in stages {
            builder.record(PipelineStageReport(stage: stage, outcome: outcome))
        }
        return builder.report
    }

    // MARK: - Descriptors

    @Test func recoveryDescriptorSelectsOnlyRecoveryNeededNewestFirst() throws {
        let older = insertRecording(captureState: .recoveryNeeded, recordedAt: Date(timeIntervalSince1970: 100))
        let newer = insertRecording(captureState: .recoveryNeeded, recordedAt: Date(timeIntervalSince1970: 200))
        insertRecording(captureState: .ready)
        try context.save()

        let result = try context.fetch(HealthRecoveryAggregation.recoveryNeededDescriptor())
        #expect(result.map(\.id) == [newer.id, older.id])
    }

    @Test func stalledDescriptorSelectsReadyFailedOrPendingOnly() throws {
        let failed = insertRecording(transcriptionStatus: .failed)
        let pending = insertRecording(transcriptionStatus: .pending)
        insertRecording(transcriptionStatus: .done)
        insertRecording(transcriptionStatus: .none)
        insertRecording(captureState: .recoveryNeeded, transcriptionStatus: .failed)
        try context.save()

        let result = try context.fetch(HealthRecoveryAggregation.stalledTranscriptionsDescriptor())
        #expect(Set(result.map(\.id)) == [failed.id, pending.id])
    }

    // MARK: - Degraded transcripts

    @Test func degradedItemsKeepOnlyWarningReportsAttachedToARecording() throws {
        let clean = insertRecording()
        let degraded = insertRecording()
        let orphan = Transcript(
            recording: nil,
            pipelineReportData: JSONStorage.encodeAuthoritative(report([(.correction, .degraded)]))
        )
        let cleanTranscript = Transcript(
            recording: clean,
            pipelineReportData: JSONStorage.encodeAuthoritative(report([(.transcription, .succeeded)]))
        )
        let degradedTranscript = Transcript(
            recording: degraded,
            pipelineReportData: JSONStorage.encodeAuthoritative(
                report([(.transcription, .succeeded), (.diarization, .failed)])
            )
        )
        let noReport = Transcript(recording: insertRecording())
        for transcript in [orphan, cleanTranscript, degradedTranscript, noReport] {
            context.insert(transcript)
        }
        try context.save()

        let items = HealthRecoveryAggregation.degradedItems(in: [orphan, cleanTranscript, degradedTranscript, noReport])
        #expect(items.map(\.id) == [degraded.id])
        #expect(items.first?.report.warnings.map(\.stage) == [.diarization])
    }

    @Test func degradedSubtitleJoinsWarningStagesInExecutionOrder() {
        let subtitle = HealthRecoveryAggregation.degradedSubtitle(
            for: report([(.diarization, .degraded), (.transcription, .succeeded), (.correction, .failed)])
        )
        #expect(subtitle == "\(PipelineStage.diarization.displayName), \(PipelineStage.correction.displayName)")
    }

    @Test func correctionRetryIsOfferedOnlyForCorrectionWarnings() {
        #expect(HealthRecoveryAggregation.canRetryCorrection(report([(.correction, .degraded)])))
        #expect(HealthRecoveryAggregation.canRetryCorrection(report([(.correction, .failed)])))
        #expect(!HealthRecoveryAggregation.canRetryCorrection(report([(.correction, .succeeded)])))
        #expect(!HealthRecoveryAggregation.canRetryCorrection(report([(.diarization, .failed)])))
    }

    // MARK: - Models & events

    @Test func corruptModelsFilterKeepsOnlyCorruptState() {
        func model(_ id: String, _ state: ModelVerificationState) -> ModelStore.InstalledModel {
            var model = ModelStore.InstalledModel(
                id: id, group: .vad, displayName: id, folderNames: [id], size: 1
            )
            model.verificationState = state
            return model
        }
        let models = [
            model("a", .unverified),
            model("b", .verified(Date())),
            model("c", .corrupt(reason: "checksum"))
        ]
        #expect(HealthRecoveryAggregation.corruptModels(in: models).map(\.id) == ["c"])
    }

    @Test func recentFailuresDropEverythingButFailedOutcomes() {
        func event(_ outcome: ReliabilityEvent.Outcome) -> ReliabilityEvent {
            ReliabilityEvent(operationID: OperationID(), operation: "capture", outcome: outcome)
        }
        let events = [event(.started), event(.failed), event(.succeeded), event(.cancelled), event(.failed)]
        let failures = HealthRecoveryAggregation.recentFailures(in: events)
        #expect(failures.count == 2)
        #expect(failures.allSatisfy { $0.outcome == .failed })
    }

    // MARK: - Labels & emptiness

    @Test func meetingTitleFallsBackWhenMissingOrBlank() {
        let named = insertRecording(title: "Sprint")
        let blank = insertRecording(title: "")
        let detached = Recording(fileName: "x.m4a", duration: 1)
        context.insert(detached)

        #expect(HealthRecoveryAggregation.meetingTitle(for: named) == "Sprint")
        let fallback = NSLocalizedString("health.untitled_meeting", comment: "")
        #expect(HealthRecoveryAggregation.meetingTitle(for: blank) == fallback)
        #expect(HealthRecoveryAggregation.meetingTitle(for: detached) == fallback)
    }

    @Test func isEmptyRequiresEverySectionToBeEmpty() {
        #expect(HealthRecoveryAggregation.isEmpty(
            recoveryNeeded: [], stalledTranscriptions: [], degraded: [],
            quarantineItems: [], corruptModels: [], recentFailures: []
        ))
        let failure = ReliabilityEvent(operationID: OperationID(), operation: "capture", outcome: .failed)
        #expect(!HealthRecoveryAggregation.isEmpty(
            recoveryNeeded: [], stalledTranscriptions: [], degraded: [],
            quarantineItems: [], corruptModels: [], recentFailures: [failure]
        ))
        let recording = insertRecording(captureState: .recoveryNeeded)
        #expect(!HealthRecoveryAggregation.isEmpty(
            recoveryNeeded: [recording], stalledTranscriptions: [], degraded: [],
            quarantineItems: [], corruptModels: [], recentFailures: []
        ))
    }
}
