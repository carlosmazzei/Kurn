//
//  RecordingCompactionViewModel.swift
//  Kurn
//
//  Drives the "Compact recordings" action in Settings → Storage: finds the
//  recordings worth re-encoding, runs `RecordingCompactor` over them off the main
//  actor, and keeps the cached sizes in SwiftData in step with what is on disk.
//
//  It also computes the largest-meetings breakdown the same screen shows, since
//  both come from one fetch of every recording.
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class RecordingCompactionViewModel {
    /// One row of the "largest recordings" breakdown.
    struct MeetingUsage: Identifiable, Sendable {
        let id: UUID
        let title: String
        let bytes: Int64
        let duration: TimeInterval
    }

    /// Recordings that would be re-encoded, and what that is expected to save.
    private(set) var candidateCount = 0
    private(set) var estimatedSavings: Int64 = 0
    /// Largest meetings by total audio size, longest bar first.
    private(set) var largestMeetings: [MeetingUsage] = []
    /// 0...1 across the whole run, or nil when nothing is running.
    private(set) var progress: Double?
    /// Bytes reclaimed by the run that just finished, for the result dialog.
    var completedSavings: Int64?
    var error: AppError?

    /// How many meetings the breakdown lists. Enough to spot the outliers without
    /// turning Settings into a second library screen.
    static let largestMeetingsLimit = 8

    private let modelContext: ModelContext
    private var runTask: Task<Void, Never>?

    var isRunning: Bool { progress != nil }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Inspection

    /// Recompute the candidate count, the estimated saving, and the largest-
    /// meetings breakdown from the store. Cheap: one fetch, no disk access —
    /// `Recording.fileSize` is already cached (and backfilled by
    /// `RecordingRecovery` for rows that predate it).
    func refresh(targetBitRate: Int) {
        guard let recordings = try? modelContext.fetch(FetchDescriptor<Recording>()) else { return }

        let compactor = RecordingCompactor(targetBitRate: targetBitRate)
        let candidates = compactor.candidates(from: recordings.compactMap(Self.candidate(for:)))
        candidateCount = candidates.count
        estimatedSavings = compactor.estimatedSavings(for: candidates)
        largestMeetings = Self.largestMeetings(from: recordings, limit: Self.largestMeetingsLimit)
    }

    /// Only completed transcriptions are eligible: a pending, in-progress or
    /// checkpointed recording is still going to be read by the pipeline, and
    /// swapping the file underneath it would corrupt the resume.
    private static func candidate(for recording: Recording) -> RecordingCompactor.Candidate? {
        guard recording.isReadyForConsumption, recording.transcriptionStatus == .done else { return nil }
        return RecordingCompactor.Candidate(
            fileName: recording.fileName,
            duration: recording.duration,
            fileSize: recording.fileSize
        )
    }

    /// Sum each meeting's recordings and take the biggest. Pure so the ranking is
    /// testable without a running app.
    static func largestMeetings(from recordings: [Recording], limit: Int) -> [MeetingUsage] {
        var totals: [UUID: MeetingUsage] = [:]
        for recording in recordings {
            guard let meeting = recording.meeting, recording.fileSize > 0 else { continue }
            let existing = totals[meeting.id]
            totals[meeting.id] = MeetingUsage(
                id: meeting.id,
                title: meeting.title,
                bytes: (existing?.bytes ?? 0) + recording.fileSize,
                duration: (existing?.duration ?? 0) + recording.duration
            )
        }
        return totals.values
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Running

    /// Re-encode every candidate, updating progress as it goes. Safe to call
    /// again after it finishes; a second call while running is ignored.
    func start(targetBitRate: Int) {
        guard runTask == nil else { return }
        // Don't compete with a live recording for disk and CPU — and never touch
        // files while the recorder owns one.
        guard !RecordingCommandRouter.shared.hasActiveSession else { return }

        progress = 0
        completedSavings = nil
        runTask = Task { [weak self] in
            await self?.run(targetBitRate: targetBitRate)
            self?.runTask = nil
            self?.progress = nil
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    private func run(targetBitRate: Int) async {
        guard let recordings = try? modelContext.fetch(FetchDescriptor<Recording>()) else { return }
        let compactor = RecordingCompactor(targetBitRate: targetBitRate)

        // Index by file name so each result can be written back to its row
        // without holding the model objects across a suspension.
        var byFileName: [String: Recording] = [:]
        for recording in recordings where recording.isReadyForConsumption
            && recording.transcriptionStatus == .done {
            byFileName[recording.fileName] = recording
        }
        let candidates = compactor.candidates(from: recordings.compactMap(Self.candidate(for:)))
        guard !candidates.isEmpty else {
            completedSavings = 0
            return
        }

        var saved: Int64 = 0
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { break }
            do {
                // Nonisolated `async`, so the decode/encode runs off the main
                // actor; only the bookkeeping below is back on it.
                saved += try await compactor.compact(fileName: candidate.fileName)
            } catch is CancellationError {
                break
            } catch let failure as AppError {
                // Resource exhaustion applies to every remaining recording, so
                // stop rather than failing candidate after candidate.
                error = failure
                break
            } catch let failure {
                // Bound explicitly: `catch`'s implicit `error` would shadow this
                // type's own `error` property.
                error = .audioError(failure.localizedDescription)
                break
            }
            byFileName[candidate.fileName]?.refreshFileSize()
            progress = Double(index + 1) / Double(candidates.count)
        }

        if let failure = modelContext.saveOrError() { error = failure }
        completedSavings = saved
        AppLog.recorder.atNotice.notice("compaction run finished, reclaimed \(saved, privacy: .public) bytes")
        refresh(targetBitRate: targetBitRate)
    }
}
