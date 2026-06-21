//
//  TranscriptionViewModel.swift
//  MeetSync
//
//  Coordinates transcription and summary generation for a meeting and writes the
//  results back into SwiftData. Heavy work runs in the value-type services off
//  the main actor; all model mutation happens here on the main actor.
//

import Foundation
import Observation
import SwiftData
import SwiftUI // for Color.speakerHex palette helper

@MainActor
@Observable
final class TranscriptionViewModel {
    /// IDs of recordings currently transcribing, for per-row spinners.
    private(set) var transcribingIDs: Set<UUID> = []
    private(set) var isSummarizing = false
    var error: AppError?

    private let modelContext: ModelContext
    private let transcriptionService = TranscriptionService()
    private let summaryService = SummaryService()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Persist pending model changes, surfacing failures instead of dropping
    /// them silently — a failed save otherwise leaves the in-memory models and
    /// the store diverged (e.g. status shown as `.done` but stored as `.inProgress`).
    private func persist() {
        do {
            try modelContext.save()
        } catch {
            self.error = .persistenceFailed(error.localizedDescription)
        }
    }

    func isTranscribing(_ recording: Recording) -> Bool {
        transcribingIDs.contains(recording.id)
    }

    // MARK: - Transcription

    /// Request the on-device speech permission when needed for the chosen mode.
    func ensureAuthorization(for mode: TranscriptionMode) async -> Bool {
        guard mode == .onDevice else { return true }
        return await OnDeviceTranscriber().requestAuthorization()
    }

    func transcribe(
        _ recording: Recording,
        language: MeetingLanguage,
        mode: TranscriptionMode
    ) async {
        guard !transcribingIDs.contains(recording.id) else { return }

        if mode == .onDevice {
            let authorized = await ensureAuthorization(for: mode)
            guard authorized else {
                error = .permissionDenied(
                    NSLocalizedString("error.speech_permission", comment: "Speech permission")
                )
                return
            }
        }

        // Capture primitives before suspending.
        let fileURL = recording.fileURL
        let fileName = recording.fileName

        transcribingIDs.insert(recording.id)
        recording.transcriptionStatus = .inProgress
        recording.transcriptionMode = mode
        persist()

        do {
            let output = try await transcriptionService.transcribe(
                fileURL: fileURL,
                fileName: fileName,
                language: language,
                mode: mode
            )

            // Replace any existing transcript.
            if let existing = recording.transcript {
                modelContext.delete(existing)
            }
            let transcript = Transcript(
                recording: recording,
                segments: output.segments,
                language: output.language
            )
            modelContext.insert(transcript)
            recording.transcript = transcript
            recording.transcriptionStatus = .done

            ensureSpeakers(for: recording.meeting, labels: output.speakerLabels)
            persist()
        } catch let appError as AppError {
            recording.transcriptionStatus = .failed
            persist()
            error = appError
        } catch {
            recording.transcriptionStatus = .failed
            persist()
            self.error = .transcriptionFailed(error.localizedDescription)
        }

        transcribingIDs.remove(recording.id)
    }

    /// Create `Speaker` rows for any labels not already present on the meeting.
    private func ensureSpeakers(for meeting: Meeting?, labels: [String]) {
        guard let meeting else { return }
        var index = meeting.speakers.count
        for label in labels where !meeting.speakers.contains(where: { $0.label == label }) {
            // Setting `meeting` establishes the relationship; SwiftData maintains
            // the inverse `meeting.speakers`.
            let speaker = Speaker(
                meeting: meeting,
                label: label,
                color: Color.speakerHex(for: index)
            )
            modelContext.insert(speaker)
            index += 1
        }
    }

    // MARK: - Summary

    func generateSummary(for meeting: Meeting, provider: AIProvider) async {
        guard !isSummarizing else { return }

        // Assemble transcript text on the main actor (reads SwiftData).
        let groups: [[TranscriptSegment]] = meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { $0.transcript?.segments }
        let transcriptText = SummaryService.assembleTranscriptText(from: groups)
        let title = meeting.title

        guard !transcriptText.isEmpty else {
            error = .transcriptionFailed(
                NSLocalizedString("error.no_transcript", comment: "No transcript to summarize")
            )
            return
        }

        isSummarizing = true
        do {
            let result = try await summaryService.generate(
                transcriptText: transcriptText,
                meetingTitle: title,
                provider: provider
            )
            if let existing = meeting.summary {
                existing.content = result.content
                existing.actionItems = result.actionItems
                existing.keyDecisions = result.keyDecisions
                existing.provider = provider
                existing.updatedAt = Date()
            } else {
                let summary = Summary(
                    meeting: meeting,
                    content: result.content,
                    actionItems: result.actionItems,
                    keyDecisions: result.keyDecisions,
                    provider: provider
                )
                modelContext.insert(summary)
                meeting.summary = summary
            }
            persist()
        } catch let appError as AppError {
            error = appError
        } catch {
            self.error = .apiError(statusCode: 0, message: error.localizedDescription)
        }
        isSummarizing = false
    }
}
