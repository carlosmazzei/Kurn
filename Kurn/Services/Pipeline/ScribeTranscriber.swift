//
//  ScribeTranscriber.swift
//  Kurn
//
//  Cloud transcription via ElevenLabs Scribe. Mirrors `WhisperTranscriber`'s
//  shape (chunked upload, resumable checkpoints, synthetic progress) but talks
//  to `ElevenLabsScribeClient` instead of an OpenAI-compatible provider, and
//  resolves its own API key from the Keychain rather than through
//  `ProviderFactory`/`AIProvider` — Scribe has exactly one vendor and one
//  model, so there is no provider/model choice to thread through.
//

import Foundation
import KurnCore

actor ScribeTranscriber: Transcribing {

    private let chunker = AudioChunker()

    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        throw AppError.permissionDenied(NSLocalizedString(
            "error.cloud_transcription_consent_required",
            comment: "Cloud transcription requires upload consent"
        ))
    }

    /// Chunked transcription that can resume from a persisted checkpoint, same
    /// contract as `WhisperTranscriber.transcribeResumable`.
    func transcribeResumable(
        url: URL,
        language: MeetingLanguage,
        transferPolicy: LargeTransferPolicy = .wifiOnly,
        cutPoints: [TimeInterval] = [],
        resume: ChunkedTranscriptionRunner.Progress? = nil,
        onChunkCompleted: (@Sendable (ChunkedTranscriptionRunner.Progress) async throws -> Void)? = nil,
        onProgress: @escaping @Sendable (Double, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> RawTranscript {
        guard let apiKey = KeychainManager.shared.value(for: .elevenLabs), !apiKey.isEmpty else {
            throw AppError.noAPIKey(provider: "ElevenLabs")
        }
        let client = ElevenLabsScribeClient(apiKey: apiKey, largeTransferPolicy: transferPolicy)
        let chunks = try await chunker.chunk(url: url, cutPoints: cutPoints)
        let total = chunks.count
        let planDigest = PipelineDigest.sha256Hex(of: chunks.map(\.offset))
        AppLog.transcription.atInfo.info("scribe: uploading \(total, privacy: .public) chunk(s) via ElevenLabs")
        defer { Task { await chunker.cleanup(chunks) } }

        return try await ChunkedTranscriptionRunner.run(
            chunks: chunks,
            planDigest: planDigest,
            resume: resume,
            transcribeChunk: { chunk, index in
                let data = try Data(contentsOf: chunk.url)
                AppLog.transcription.atInfo.info("scribe: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) sending \(data.count, privacy: .public) bytes")
                let progressPulse = Self.startProgressPulse(completedChunks: index, totalChunks: total, onProgress: onProgress)
                defer { progressPulse.cancel() }
                let chunkStart = Date()
                do {
                    let result = try await Self.withChunkTimeout(seconds: LLMHTTP.transcriptionTimeout) {
                        try await client.transcribe(
                            audioData: data,
                            fileName: chunk.url.lastPathComponent,
                            language: language
                        )
                    }
                    AppLog.transcription.atNotice.notice("scribe: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) done in \(Date().timeIntervalSince(chunkStart), privacy: .public)s, spans=\(result.spans.count, privacy: .public) lang=\(result.language, privacy: .public)")
                    return result
                } catch {
                    AppLog.transcription.atError.error("scribe: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) failed after \(Date().timeIntervalSince(chunkStart), privacy: .public)s code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                    throw error
                }
            },
            onChunkCompleted: onChunkCompleted,
            onProgress: { progress, currentChunk, total in
                onProgress(progress, currentChunk, total)
            }
        )
    }

    /// Runs `operation`, cancelling it and reporting an ambiguous provider result
    /// if it doesn't complete within `seconds`; the upload is never replayed
    /// automatically because the provider may already have processed it.
    private static func withChunkTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                AppLog.transcription.atError.error("scribe: chunk result ambiguous after \(Int(seconds), privacy: .public)s — not retrying automatically")
                throw AppError.ambiguousProviderResult
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    private static func startProgressPulse(
        completedChunks: Int,
        totalChunks: Int,
        onProgress: @escaping @Sendable (Double, Int, Int) -> Void
    ) -> Task<Void, Never> {
        Task {
            let started = Date()
            var nextHeartbeatAt: TimeInterval = 30
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(started)
                let progress = WhisperTranscriber.estimatedProgress(completedChunks: completedChunks, totalChunks: totalChunks, elapsed: elapsed)
                onProgress(progress, completedChunks + 1, totalChunks)
                if elapsed >= nextHeartbeatAt {
                    AppLog.transcription.atNotice.notice("scribe: chunk \(completedChunks + 1, privacy: .public)/\(totalChunks, privacy: .public) still awaiting response, elapsed=\(Int(elapsed), privacy: .public)s")
                    nextHeartbeatAt += 30
                }
            }
        }
    }
}
