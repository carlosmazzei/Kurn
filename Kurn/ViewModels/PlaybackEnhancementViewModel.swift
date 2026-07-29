//
//  PlaybackEnhancementViewModel.swift
//  Kurn
//
//  Owns on-demand generation of the enhanced listening copies.
//
//  Per-recording state is keyed by `UUID`, following `TranscriptionViewModel` —
//  two recordings can be rendering at once and neither may see the other's
//  progress or error. Progress is deliberately a membership set rather than a
//  fraction: `OfflineAudioRenderer` reports no incremental progress, and showing
//  an invented percentage that jumps to 100 would be worse than an honest
//  indeterminate spinner.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlaybackEnhancementViewModel {

    private(set) var renderingIDs: Set<UUID> = []
    var error: AppError?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let modelContext: ModelContext
    private let renderer = PlaybackEnhancementRenderer()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func isRendering(_ recording: Recording) -> Bool {
        renderingIDs.contains(recording.id)
    }

    /// Whether playback can use the enhanced copy right now.
    func hasEnhancedAudio(_ recording: Recording) -> Bool {
        recording.hasEnhancedAudio(currentVersion: PlaybackEnhancementRenderer.currentVersion)
    }

    /// Render the enhanced copy unless it already exists at the current tuning.
    ///
    /// Safe to call repeatedly — the UI calls it whenever the user turns
    /// enhancement on for a recording, and re-entry is refused rather than
    /// queued.
    /// - Parameter onReady: run on success, so the caller can switch playback over
    ///   the moment the copy exists instead of making the user tap a second time.
    func ensureEnhancedAudio(for recording: Recording, onReady: (() -> Void)? = nil) {
        guard !hasEnhancedAudio(recording), tasks[recording.id] == nil else {
            onReady?()
            return
        }
        // Never compete with a live recording for disk and CPU.
        guard !RecordingCommandRouter.shared.hasActiveSession else { return }

        let id = recording.id
        let fileName = recording.fileName
        renderingIDs.insert(id)
        tasks[id] = Task { [weak self] in
            let succeeded = await self?.run(recordingID: id, fileName: fileName) ?? false
            self?.tasks[id] = nil
            self?.renderingIDs.remove(id)
            if succeeded { onReady?() }
        }
    }

    func cancel(_ recording: Recording) {
        tasks[recording.id]?.cancel()
    }

    /// Drop every enhanced copy and forget them on the rows that referenced them.
    /// Backs the storage-reclaim action; the copies regenerate on next use.
    func deleteAllEnhancedAudio() {
        AudioFileStore.deleteAllEnhancedAudio()
        let descriptor = FetchDescriptor<Recording>()
        guard let recordings = try? modelContext.fetch(descriptor) else { return }
        for recording in recordings where recording.enhancedAudioVersion != 0 {
            recording.clearEnhancedAudio()
        }
        if let failure = modelContext.saveOrError() { error = failure }
    }

    @discardableResult
    private func run(recordingID: UUID, fileName: String) async -> Bool {
        do {
            let size = try await renderer.render(fileName: fileName)
            // Re-fetch rather than holding the model across the suspension.
            guard let recording = recording(id: recordingID) else { return false }
            recording.enhancedAudioVersion = PlaybackEnhancementRenderer.currentVersion
            recording.enhancedFileSize = size
            if let failure = modelContext.saveOrError() { error = failure }
            return true
        } catch is CancellationError {
            // The renderer removes its own temp file; nothing landed on disk.
            return false
        } catch let failure as AppError {
            error = failure
        } catch let failure {
            error = .audioError(failure.localizedDescription)
        }
        return false
    }

    private func recording(id: UUID) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
