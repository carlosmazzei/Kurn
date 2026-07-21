//
//  SemanticIndexCoordinator.swift
//  Kurn
//
//  Owns building and persisting a meeting's on-device semantic index. All
//  SwiftData reads/writes happen here on the main actor; the expensive
//  embedding runs off-main in `SemanticIndexService`. Used two ways:
//  transcription completion indexes the just-finished meeting, and a launch/
//  foreground backfill sweeps meetings that were transcribed before indexing
//  existed (or by an older embedder model).
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SemanticIndexCoordinator {
    private let modelContext: ModelContext
    private let indexService = SemanticIndexService()

    /// App-wide settings, set by `KurnApp`; the index respects the
    /// `semanticSearchEnabled` toggle without threading settings through callers.
    var appSettings: AppSettings?

    /// Meetings currently being indexed, so the UI can show progress and repeat
    /// requests for the same meeting coalesce instead of racing.
    private(set) var indexingMeetingIDs: Set<UUID> = []
    /// True while a backfill sweep is running, so it never overlaps itself.
    private(set) var isBackfilling = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Single meeting

    /// Index `meeting` only when the feature is enabled. Called from the
    /// transcription success path.
    func indexIfEnabled(_ meeting: Meeting?) async {
        guard appSettings?.semanticSearchEnabled ?? false, let meeting else { return }
        await index(meeting)
    }

    /// Rebuild `meeting`'s semantic chunks from its current transcripts. A no-op
    /// (clearing any stale chunks) when the meeting has no transcript text.
    func index(_ meeting: Meeting) async {
        let meetingID = meeting.id
        guard !indexingMeetingIDs.contains(meetingID) else { return }
        indexingMeetingIDs.insert(meetingID)
        defer { indexingMeetingIDs.remove(meetingID) }

        let inputs = Self.chunkInputs(for: meeting)
        let chunks = TranscriptChunker.chunk(inputs)
        guard !chunks.isEmpty else {
            replaceChunks(of: meeting, with: [])
            return
        }

        do {
            let embedded = try await indexService.embed(chunks)
            // The meeting/context could have changed while embedding ran off-main;
            // re-check the object is still live before mutating it.
            guard !embedded.isEmpty else { return }
            replaceChunks(of: meeting, with: embedded)
            AppLog.transcription.atNotice.notice("semanticIndex: indexed meeting \(meetingID, privacy: .public) chunks=\(embedded.count, privacy: .public)")
        } catch is CancellationError {
            // Leave existing chunks in place; a later pass retries.
        } catch {
            AppLog.transcription.atError.error("semanticIndex: failed for meeting \(meetingID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Backfill / maintenance

    /// Index every meeting that has a transcript but no up-to-date semantic
    /// index. Low priority and cancellable; skipped entirely when the feature is
    /// off. Safe to call on every foreground — meetings already indexed by the
    /// current model are skipped.
    func backfill() async {
        guard appSettings?.semanticSearchEnabled ?? false, !isBackfilling else { return }
        isBackfilling = true
        defer { isBackfilling = false }

        let stale = (try? modelContext.fetch(FetchDescriptor<Meeting>()))?.filter(needsIndexing) ?? []
        guard !stale.isEmpty else { return }
        AppLog.transcription.atNotice.notice("semanticIndex: backfill \(stale.count, privacy: .public) meeting(s)")
        for meeting in stale {
            if Task.isCancelled { return }
            await index(meeting)
        }
    }

    /// Delete the whole on-device index (Settings → Clear index).
    func clearIndex() {
        let all = (try? modelContext.fetch(FetchDescriptor<SemanticChunk>())) ?? []
        for chunk in all { modelContext.delete(chunk) }
        persist()
    }

    /// Wipe and re-index every meeting from scratch (Settings → Rebuild index).
    /// After clearing, every transcribed meeting looks stale, so the backfill
    /// re-embeds all of them. Ignores the enabled toggle so the user can rebuild
    /// even while deciding whether to keep the feature on.
    func rebuild() async {
        clearIndex()
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>()))?
            .filter(\.hasAnyTranscript) ?? []
        for meeting in meetings {
            if Task.isCancelled { return }
            await index(meeting)
        }
    }

    /// Number of indexed passages, for the Settings status row.
    func indexedChunkCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<SemanticChunk>())) ?? 0
    }

    // MARK: - Helpers

    /// A meeting needs indexing when it has transcript text but no chunks, or its
    /// chunks were produced by a different/older embedder model.
    private func needsIndexing(_ meeting: Meeting) -> Bool {
        guard meeting.hasAnyTranscript else { return false }
        if meeting.semanticChunks.isEmpty { return true }
        return meeting.semanticChunks.contains { $0.modelIdentifier != indexService.modelIdentifier }
    }

    private static func chunkInputs(for meeting: Meeting) -> [TranscriptChunker.Input] {
        meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { recording in
                guard let segments = recording.transcript?.segments, !segments.isEmpty else { return nil }
                return TranscriptChunker.Input(
                    recordingID: recording.id,
                    offset: meeting.startOffset(of: recording),
                    segments: segments
                )
            }
    }

    /// Replace a meeting's chunks wholesale (delete old, insert new), so a
    /// re-index never leaves a mix of old and new passages.
    private func replaceChunks(of meeting: Meeting, with embedded: [SemanticIndexService.EmbeddedChunk]) {
        for existing in meeting.semanticChunks { modelContext.delete(existing) }
        for item in embedded {
            let chunk = SemanticChunk(
                meeting: meeting,
                recordingID: item.chunk.recordingID,
                text: item.chunk.text,
                startTime: item.chunk.startTime,
                endTime: item.chunk.endTime,
                speakerLabel: item.chunk.speakerLabel,
                vector: item.vector,
                modelIdentifier: indexService.modelIdentifier
            )
            modelContext.insert(chunk)
        }
        persist()
    }

    private func persist() {
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.atError.error("semanticIndex: persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
