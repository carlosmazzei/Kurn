//
//  WhisperTranscriber.swift
//  Kurn
//
//  Cloud transcription via a Whisper-compatible provider (OpenAI, Groq, or any
//  OpenAI-compatible endpoint). Splits long audio into chunks (`AudioChunker`),
//  uploads each through the selected provider, and offsets the
//  per-chunk timestamps back to absolute meeting time. Reports a `0...1`
//  progress fraction while each chunk is in flight and as chunks complete.
//  Wraps what used to live inline in `TranscriptionService` so transcription is
//  uniformly protocol-typed.
//

import AVFoundation
import Foundation
import KurnCore

actor WhisperTranscriber: Transcribing {

    /// Resolves the cloud speech-to-text client for a run. Production resolves
    /// through `ProviderFactory` (key, base URL, transfer policy); tests inject
    /// a scripted provider.
    typealias ProviderResolver = @Sendable (AIProvider, String, LargeTransferPolicy) throws -> any TranscriptionProvider

    private let chunker = AudioChunker()
    private let resolveProvider: ProviderResolver

    init(resolveProvider: @escaping ProviderResolver = {
        try ProviderFactory.whisperProvider(for: $0, model: $1, transferPolicy: $2)
    }) {
        self.resolveProvider = resolveProvider
    }

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

    /// Chunked transcription that can resume from a persisted checkpoint:
    /// `resume` (when its plan matches) skips already-uploaded chunks, and
    /// `onChunkCompleted` reports durable progress after each chunk so an
    /// interruption loses at most the in-flight upload.
    func transcribeResumable(
        url: URL,
        language: MeetingLanguage,
        provider transcriptionProvider: AIProvider,
        model: String,
        transferPolicy: LargeTransferPolicy = .wifiOnly,
        cutPoints: [TimeInterval] = [],
        resume: ChunkedTranscriptionRunner.Progress? = nil,
        onChunkCompleted: (@Sendable (ChunkedTranscriptionRunner.Progress) async throws -> Void)? = nil,
        onProgress: @escaping @Sendable (Double, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> RawTranscript {
        let provider = try resolveProvider(transcriptionProvider, model, transferPolicy)
        let vendor = transcriptionProvider.displayName
        let chunks = try await chunker.chunk(url: url, cutPoints: cutPoints)
        let total = chunks.count
        let planDigest = PipelineDigest.sha256Hex(of: chunks.map(\.offset))
        AppLog.transcription.atInfo.info("whisper: uploading \(total, privacy: .public) chunk(s) via \(vendor, privacy: .public)")
        defer { Task { await chunker.cleanup(chunks) } }

        return try await ChunkedTranscriptionRunner.run(
            chunks: chunks,
            planDigest: planDigest,
            resume: resume,
            transcribeChunk: { chunk, index in
                let data = try Data(contentsOf: chunk.url)
                AppLog.transcription.atInfo.info("whisper: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) sending \(data.count, privacy: .public) bytes to \(vendor, privacy: .public)")
                let progressPulse = Self.startProgressPulse(completedChunks: index, totalChunks: total, onProgress: onProgress)
                defer { progressPulse.cancel() }
                let chunkStart = Date()
                do {
                    let result = try await Self.withChunkTimeout(seconds: LLMHTTP.transcriptionTimeout) {
                        try await provider.transcribe(
                            audioData: data,
                            fileName: chunk.url.lastPathComponent,
                            language: language
                        )
                    }
                    AppLog.transcription.atNotice.notice("whisper: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) done in \(Date().timeIntervalSince(chunkStart), privacy: .public)s, spans=\(result.spans.count, privacy: .public) lang=\(result.language, privacy: .public)")
                    guard Self.hasOnlyUntimedSpans(result) else { return result }
                    let duration = (try? await AVURLAsset(url: chunk.url).load(.duration)).map(CMTimeGetSeconds) ?? 0
                    return Self.spreadingUntimedSpans(result, across: duration)
                } catch {
                    AppLog.transcription.atError.error("whisper: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) failed for \(vendor, privacy: .public) after \(Date().timeIntervalSince(chunkStart), privacy: .public)s code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                    throw error
                }
            },
            onChunkCompleted: onChunkCompleted,
            onProgress: { progress, currentChunk, total in
                onProgress(progress, currentChunk, total)
            }
        )
    }

    /// Whether every span came back without a time range — what a model that
    /// only speaks plain `json` returns (`gpt-4o-transcribe`,
    /// `gpt-4o-mini-transcribe`): one `start: 0, end: 0` span for the chunk.
    static func hasOnlyUntimedSpans(_ transcript: RawTranscript) -> Bool {
        !transcript.spans.isEmpty && transcript.spans.allSatisfy { $0.end <= $0.start }
    }

    /// Gives untimed spans the chunk's own extent, split evenly in order.
    ///
    /// Left at zero length, every word of a chunk (up to ten minutes) sat on
    /// one instant: fusion handed all of it to whoever held the floor at that
    /// instant, so the transcript read as one speaker per chunk and scored
    /// 100% DER on AMI. With the real extent, `TranscriptFusion`'s
    /// word-preserving `splitCoarseSpan` spreads the words over the diarizer's
    /// turns — an estimate, as for any engine without word timings, but an
    /// attribution rather than none. Text is never touched.
    static func spreadingUntimedSpans(_ transcript: RawTranscript, across duration: TimeInterval) -> RawTranscript {
        guard duration > 0, hasOnlyUntimedSpans(transcript) else { return transcript }
        let share = duration / Double(transcript.spans.count)
        var result = transcript
        result.spans = transcript.spans.enumerated().map { index, span in
            TranscribedSpan(
                text: span.text,
                start: Double(index) * share,
                end: Double(index + 1) * share,
                confidence: span.confidence
            )
        }
        return result
    }

    static func estimatedProgress(completedChunks: Int, totalChunks: Int, elapsed: TimeInterval) -> Double {
        guard totalChunks > 0 else { return 0 }
        let completed = min(max(0, completedChunks), totalChunks)
        guard completed < totalChunks else { return 1 }

        // Whisper gives no byte/server-side progress. Move through most of the
        // current chunk's share asymptotically, then let the real response mark
        // that chunk complete. This keeps single-chunk uploads visibly alive
        // without claiming 100% before OpenAI has returned a transcript.
        let seconds = max(0, elapsed)
        let inFlightChunkFraction = min(0.88, seconds / (seconds + 20))
        return (Double(completed) + inFlightChunkFraction) / Double(totalChunks)
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
                AppLog.transcription.atError.error("whisper: chunk result ambiguous after \(Int(seconds), privacy: .public)s — not retrying automatically")
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
                let progress = estimatedProgress(completedChunks: completedChunks, totalChunks: totalChunks, elapsed: elapsed)
                onProgress(progress, completedChunks + 1, totalChunks)
                // Periodic heartbeat so the log shows the upload is alive (not hung).
                // Progress saturates near 88% by design; without this the log goes
                // silent and it's impossible to tell if the upload is still in flight.
                if elapsed >= nextHeartbeatAt {
                    AppLog.transcription.atNotice.notice("whisper: chunk \(completedChunks + 1, privacy: .public)/\(totalChunks, privacy: .public) still awaiting response, elapsed=\(Int(elapsed), privacy: .public)s")
                    nextHeartbeatAt += 30
                }
            }
        }
    }
}
