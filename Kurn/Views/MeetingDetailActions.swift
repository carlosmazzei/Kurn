//
//  MeetingDetailActions.swift
//  Kurn
//
//  Playback, transcription, summary, sharing, and deletion actions for
//  `MeetingDetailView`. Isolated here so the main view file stays under
//  SwiftLint's file-length limit.
//

import SwiftUI

extension MeetingDetailView {

    var sortedRecordings: [Recording] {
        meeting.recordings.sorted { $0.recordedAt < $1.recordedAt }
    }

    func togglePlay(_ recording: Recording) {
        do {
            if player.loadedFileName == recording.fileName {
                player.togglePlayPause()
            } else {
                try player.load(fileName: recording.fileName)
                player.play()
            }
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    func seek(_ recording: Recording, to time: TimeInterval) {
        do {
            if player.loadedFileName != recording.fileName {
                try player.load(fileName: recording.fileName)
            }
            player.seek(to: time)
            player.play()
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    func startTranscription(_ recording: Recording) {
        guard let txVM else { return }
        Task {
            await txVM.transcribe(
                recording,
                language: meeting.language,
                config: settings.pipelineConfiguration
            )
        }
    }

    func retranscribe(_ recording: Recording) {
        // `transcribe` replaces any existing transcript for this recording.
        startTranscription(recording)
    }

    func retranscribeAll() {
        guard let txVM else { return }
        Task {
            await txVM.retranscribeAll(
                meeting,
                language: meeting.language,
                config: settings.pipelineConfiguration
            )
        }
    }

    func generateSummary() {
        showingTemplatePicker = true
    }

    func runSummary(with template: SummaryTemplate) {
        guard let txVM else { return }
        settings.lastSummaryTemplateID = template.id
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        Task {
            await txVM.generateSummary(
                for: meeting,
                provider: provider,
                model: model,
                template: template
            )
        }
    }

    func deleteRecording(_ recording: Recording) {
        if player.loadedFileName == recording.fileName { player.stop() }
        MeetingsViewModel(modelContext: modelContext).deleteRecording(recording)
    }

    func share() {
        do {
            let url = try MeetingExport.temporaryFile(for: meeting)
            shareItem = ShareItem(url: url)
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }
}
