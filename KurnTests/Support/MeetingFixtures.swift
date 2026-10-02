//
//  MeetingFixtures.swift
//  KurnTests
//
//  Shared building blocks for the coordinator and view-model suites: a
//  meeting with a transcript in an in-memory store, settings isolated from
//  the test host's `UserDefaults`, and a provider circuit that persists
//  nowhere.
//

import Foundation
import KurnCore
import SwiftData
@testable import Kurn

@MainActor
enum MeetingFixtures {
    /// A meeting with one done recording whose transcript has one segment per line.
    @discardableResult
    static func transcribed(
        _ title: String,
        lines: [String] = ["we ship on monday"],
        in context: ModelContext
    ) -> Meeting {
        let meeting = Meeting(title: title)
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "\(UUID().uuidString).m4a", duration: 60, transcriptionStatus: .done)
        context.insert(recording)
        let segments = lines.enumerated().map { index, text in
            TranscriptSegment(
                speakerLabel: "Speaker 1",
                startTime: TimeInterval(index * 5),
                endTime: TimeInterval(index * 5 + 4),
                text: text
            )
        }
        let transcript = Transcript(recording: recording, segments: segments, language: "en")
        context.insert(transcript)
        recording.transcript = transcript
        try? context.save()
        return meeting
    }

    /// Settings backed by a throwaway `UserDefaults` suite, so a test that
    /// flips a toggle never leaks it into another.
    static func isolatedSettings() -> AppSettings {
        let suite = "kurn-tests-\(UUID().uuidString)"
        return AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    /// A provider circuit with no persisted history.
    static func freshCircuit() -> ProviderCircuitBreaker {
        ProviderCircuitBreaker(store: MemoryProviderCircuitStore())
    }
}

final class MemoryProviderCircuitStore: ProviderCircuitStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ProviderCircuitRecord] = [:]

    func load() -> [String: ProviderCircuitRecord] {
        lock.withLock { records }
    }

    func save(_ records: [String: ProviderCircuitRecord]) {
        lock.withLock { self.records = records }
    }
}
