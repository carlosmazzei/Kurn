//
//  WhisperTranscriber.swift
//  Kurn
//
//  Cloud transcription via OpenAI Whisper. Splits long audio into chunks
//  (`AudioChunker`), uploads each through the OpenAI provider, and offsets the
//  per-chunk timestamps back to absolute meeting time. Reports a `0...1`
//  progress fraction while each chunk is in flight and as chunks complete.
//  Wraps what used to live inline in `TranscriptionService` so transcription is
//  uniformly protocol-typed.
//

import Foundation

actor WhisperTranscriber: Transcribing {

    private let chunker = AudioChunker()

    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        try await transcribeResumable(url: url, language: language, onProgress: onProgress)
    }

    /// Chunked transcription that can resume from a persisted checkpoint:
    /// `resume` (when its plan matches) skips already-uploaded chunks, and
    /// `onChunkCompleted` reports durable progress after each chunk so an
    /// interruption loses at most the in-flight upload.
    func transcribeResumable(
        url: URL,
        language: MeetingLanguage,
        resume: ChunkedTranscriptionRunner.Progress? = nil,
        onChunkCompleted: (@Sendable (ChunkedTranscriptionRunner.Progress) -> Void)? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        let provider = try ProviderFactory.whisperProvider()
        let chunks = try await chunker.chunk(url: url)
        let total = chunks.count
        AppLog.transcription.atInfo.info("whisper: uploading \(total, privacy: .public) chunk(s)")
        defer { Task { await chunker.cleanup(chunks) } }

        return try await ChunkedTranscriptionRunner.run(
            chunks: chunks,
            resume: resume,
            transcribeChunk: { chunk, index in
                let data = try Data(contentsOf: chunk.url)
                AppLog.transcription.atDebug.debug("whisper: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) (\(data.count, privacy: .public) bytes)")
                let progressPulse = Self.startProgressPulse(completedChunks: index, totalChunks: total, onProgress: onProgress)
                defer { progressPulse.cancel() }
                return try await provider.transcribe(
                    audioData: data,
                    fileName: chunk.url.lastPathComponent,
                    language: language
                )
            },
            onChunkCompleted: onChunkCompleted,
            onProgress: onProgress
        )
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

    private static func startProgressPulse(
        completedChunks: Int,
        totalChunks: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) -> Task<Void, Never> {
        Task {
            let started = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                onProgress(
                    estimatedProgress(
                        completedChunks: completedChunks,
                        totalChunks: totalChunks,
                        elapsed: Date().timeIntervalSince(started)
                    )
                )
            }
        }
    }
}
