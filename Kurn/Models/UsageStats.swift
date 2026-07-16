//
//  UsageStats.swift
//  Kurn
//
//  Local-only usage counters shown to the user in the "My Data" screen. Never
//  transmitted anywhere — pure on-device self-observability, persisted as a
//  JSON blob in AppSettings the same way summaryModels/summaryTemplates are.
//

import Foundation

struct UsageStats: Codable, Sendable, Equatable {
    var recordingsCompleted: Int = 0
    /// `TranscriptionEngine.rawValue` -> completed-transcription count.
    var transcriptionEngineUsage: [String: Int] = [:]
    /// `SummaryTemplate.id` -> generated-summary count.
    var summaryTemplateUsage: [String: Int] = [:]

    var mostUsedTranscriptionEngine: TranscriptionEngine? {
        transcriptionEngineUsage
            .max(by: { $0.value < $1.value })
            .flatMap { TranscriptionEngine(rawValue: $0.key) }
    }
}
