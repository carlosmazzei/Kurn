//
//  HealthRecoveryAggregation.swift
//  Kurn
//
//  Pure selection and labelling behind `HealthRecoveryView`: which records
//  each section lists and how a row describes them. Kept free of SwiftUI so
//  the rules can be exercised against an in-memory store without a view.
//

import Foundation
import KurnCore
import SwiftData

enum HealthRecoveryAggregation {
    /// One decoded, warning-carrying `PipelineReport` alongside the recording
    /// it came from — `pipelineReportData` is opaque JSON, so `Transcript`
    /// can't be filtered by a SwiftData predicate; every transcript is
    /// fetched and decoded here instead.
    struct DegradedItem: Identifiable {
        var id: UUID { recording.id }
        let recording: Recording
        let report: PipelineReport
    }

    static let recentFailureWindow = 100

    static func recoveryNeededDescriptor() -> FetchDescriptor<Recording> {
        let recoveryRaw = RecordingCaptureState.recoveryNeeded.rawValue
        return FetchDescriptor<Recording>(
            predicate: #Predicate { $0.captureStateRaw == recoveryRaw },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
    }

    /// Ready recordings whose transcription never completed: failed outright
    /// or still pending (deferred by the scheduler, or orphaned by a crash).
    static func stalledTranscriptionsDescriptor() -> FetchDescriptor<Recording> {
        let readyRaw = RecordingCaptureState.ready.rawValue
        let failedRaw = TranscriptionStatus.failed.rawValue
        let pendingRaw = TranscriptionStatus.pending.rawValue
        return FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.captureStateRaw == readyRaw
                    && ($0.transcriptionStatusRaw == failedRaw || $0.transcriptionStatusRaw == pendingRaw)
            },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
    }

    static func degradedItems(in transcripts: [Transcript]) -> [DegradedItem] {
        transcripts.compactMap { transcript in
            guard let report = transcript.pipelineReport, report.hasWarnings,
                  let recording = transcript.recording else { return nil }
            return DegradedItem(recording: recording, report: report)
        }
    }

    static func corruptModels(in models: [ModelStore.InstalledModel]) -> [ModelStore.InstalledModel] {
        models.filter {
            if case .corrupt = $0.verificationState { return true }
            return false
        }
    }

    static func recentFailures(in events: [ReliabilityEvent]) -> [ReliabilityEvent] {
        events.filter { $0.outcome == .failed }
    }

    static func isEmpty(
        recoveryNeeded: [Recording],
        stalledTranscriptions: [Recording],
        degraded: [DegradedItem],
        quarantineItems: [QuarantinedRecording],
        corruptModels: [ModelStore.InstalledModel],
        blockedProviders: [String],
        recentFailures: [ReliabilityEvent]
    ) -> Bool {
        recoveryNeeded.isEmpty && stalledTranscriptions.isEmpty && degraded.isEmpty
            && quarantineItems.isEmpty && corruptModels.isEmpty && blockedProviders.isEmpty
            && recentFailures.isEmpty
    }

    static func meetingTitle(for recording: Recording) -> String {
        guard let title = recording.meeting?.title, !title.isEmpty else {
            return NSLocalizedString("health.untitled_meeting", comment: "Untitled meeting")
        }
        return title
    }

    /// Comma-separated names of the stages that degraded or failed, in
    /// execution order.
    static func degradedSubtitle(for report: PipelineReport) -> String {
        report.warnings.map { $0.stage.displayName }.joined(separator: ", ")
    }

    /// Only a degraded correction pass can be re-run from this screen; the
    /// other warning stages need a full re-transcription.
    static func canRetryCorrection(_ report: PipelineReport) -> Bool {
        report.warnings.contains { $0.stage == .correction }
    }
}
