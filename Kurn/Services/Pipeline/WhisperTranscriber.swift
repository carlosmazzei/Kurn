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
        let provider = try ProviderFactory.whisperProvider()
        let chunks = try await chunker.chunk(url: url)
        let total = chunks.count
        AppLog.transcription.atInfo.info("whisper: uploading \(total, privacy: .public) chunk(s)")
        defer { Task { await chunker.cleanup(chunks) } }

        var allSpans: [TranscribedSpan] = []
        var detectedLanguage = ""

        // Show 0% immediately so the user sees a determinate bar from the start.
        onProgress(0)

        for (index, chunk) in chunks.enumerated() {
            let data = try Data(contentsOf: chunk.url)
            AppLog.transcription.atDebug.debug("whisper: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) (\(data.count, privacy: .public) bytes)")
            let progressPulse = Self.startProgressPulse(completedChunks: index, totalChunks: total, onProgress: onProgress)
            let result: RawTranscript
            do {
                result = try await provider.transcribe(
                    audioData: data,
                    fileName: chunk.url.lastPathComponent,
                    language: language
                )
            } catch {
                progressPulse.cancel()
                throw error
            }
            progressPulse.cancel()
            if detectedLanguage.isEmpty { detectedLanguage = result.language }
            // Offset chunk-local timestamps back to absolute meeting time.
            for span in result.spans {
                allSpans.append(
                    TranscribedSpan(
                        text: span.text,
                        start: span.start + chunk.offset,
                        end: span.end + chunk.offset,
                        confidence: span.confidence
                    )
                )
            }
            // Advance after each upload completes so the bar reaches 100% when
            // the last chunk lands (rather than stalling at (total-1)/total).
            onProgress(Double(index + 1) / Double(total))
        }

        return RawTranscript(spans: allSpans, language: detectedLanguage)
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
