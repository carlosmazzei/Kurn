//
//  TranscriptionStatus.swift
//  KurnCore
//
//  Lifecycle of a recording's transcription.
//

import Foundation

public enum TranscriptionStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case inProgress
    /// Interrupted mid-transcription (app backgrounded, killed, or cancelled by
    /// the system) with a checkpoint saved; resumes automatically on the next
    /// foreground pass.
    case pending
    case done
    case failed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none:
            return NSLocalizedString("status.none", comment: "No transcript")
        case .inProgress:
            return NSLocalizedString("status.in_progress", comment: "In progress")
        case .pending:
            return NSLocalizedString("status.pending", comment: "Queued to resume")
        case .done:
            return NSLocalizedString("status.done", comment: "Done")
        case .failed:
            return NSLocalizedString("status.failed", comment: "Failed")
        }
    }
}
