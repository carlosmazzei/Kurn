//
//  PlaybackEnhancementViewModel.swift
//  Kurn
//
//  Owns on-demand generation of the enhanced listening copies.
//
//  Per-recording state is keyed by `UUID`, following `TranscriptionViewModel` —
//  two recordings can be rendering at once and neither may see the other's
//  progress or error. The renderer reports a weighted fraction across its neural
//  and DSP passes so a long recording never looks stuck in one opaque stage.
//

import Foundation
import KurnCore
import Observation
import SwiftData

protocol PlaybackEnhancementRendering: Sendable {
    func render(
        fileName: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Int64
}

extension PlaybackEnhancementRenderer: PlaybackEnhancementRendering {}

@MainActor
@Observable
final class PlaybackEnhancementViewModel {

    private(set) var progressByID: [UUID: Double] = [:]
    var error: AppError?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let modelContext: ModelContext
    private let renderer: any PlaybackEnhancementRendering

    init(
        modelContext: ModelContext,
        renderer: any PlaybackEnhancementRendering = PlaybackEnhancementRenderer()
    ) {
        self.modelContext = modelContext
        self.renderer = renderer
    }

    func progress(for recording: Recording) -> Double? {
        progressByID[recording.id]
    }

    func isEnhancing(_ recording: Recording) -> Bool {
        tasks[recording.id] != nil
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
        guard recording.isReadyForConsumption else { return }
        if hasEnhancedAudio(recording) {
            onReady?()
            return
        }
        // A second request must not announce readiness while the first render is
        // still writing its temporary file. Apart from switching playback too
        // early, that used to let a reconstructed detail screen race the render.
        guard tasks[recording.id] == nil else { return }
        // Never compete with a live recording for disk and CPU.
        guard !RecordingCommandRouter.shared.hasActiveSession else { return }

        let id = recording.id
        let fileName = recording.fileName
        progressByID[id] = 0
        tasks[id] = Task { [weak self] in
            let succeeded = await self?.run(recordingID: id, fileName: fileName) ?? false
            self?.tasks[id] = nil
            self?.progressByID.removeValue(forKey: id)
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
            let size = try await renderer.render(fileName: fileName) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.tasks[recordingID] != nil else { return }
                    let clamped = min(1, max(0, progress))
                    self.progressByID[recordingID] = max(
                        self.progressByID[recordingID] ?? 0,
                        clamped
                    )
                }
            }
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
