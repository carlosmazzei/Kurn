//
//  CaptureReliability.swift
//  Kurn
//
//  Durable `ReliabilityEvent`s for the H1 capture path — sink failures,
//  finalization, capture recovery and quarantine — so Health & Recovery and
//  an exported diagnostics bundle explain *why* a recording is partial with
//  the same fixed-code vocabulary the transcription pipeline already uses.
//  Codes are `CaptureRecoveryReason`/`RecordingQuarantineReason` raw values;
//  the operation ID is a prefix of the recording file name, which is a
//  `{meetingID}_{timestamp}` convention and never user content.
//

import Foundation
import KurnCore

enum CaptureReliability {
    static let operation = "recording_capture"

    static func sinkFailed(fileName: String?, failure: AudioSinkFailure) {
        record(fileName: fileName, stage: "capture", outcome: .failed, code: failure.rawValue)
    }

    static func finalized(fileName: String, reason: CaptureRecoveryReason?, stage: String = "finalize") {
        if let reason {
            record(fileName: fileName, stage: stage, outcome: .failed, code: reason.rawValue)
        } else {
            record(fileName: fileName, stage: stage, outcome: .succeeded, code: nil)
        }
    }

    static func quarantined(fileName: String, reason: RecordingQuarantineReason, preserved: Bool) {
        record(
            fileName: fileName,
            stage: "quarantine",
            outcome: .failed,
            code: preserved ? reason.rawValue : "quarantine_preserve_failed"
        )
    }

    private static func record(fileName: String?, stage: String, outcome: ReliabilityEvent.Outcome, code: String?) {
        ReliabilityLog.record(ReliabilityEvent(
            operationID: operationID(fileName: fileName),
            operation: operation,
            stage: stage,
            outcome: outcome,
            code: code
        ))
    }

    private static func operationID(fileName: String?) -> OperationID {
        guard let fileName, !fileName.isEmpty else { return OperationID("capture") }
        return OperationID(String(fileName.prefix(8)))
    }
}
