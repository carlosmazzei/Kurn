//
//  WhisperTranscriber.swift
//  Kurn
//
//  Cloud transcription via OpenAI Whisper. Splits long audio into chunks
//  (`AudioChunker`), uploads each through the OpenAI provider, and offsets the
//  per-chunk timestamps back to absolute meeting time. Reports a `0...1`
//  progress fraction as chunks complete (only meaningful when there is more
//  than one chunk). Wraps what used to live inline in `TranscriptionService`
//  so transcription is uniformly protocol-typed.
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

        for (index, chunk) in chunks.enumerated() {
            // Report progress before each upload so the UI advances as chunks
            // complete. Only meaningful when split into several chunks; a single
            // chunk stays indeterminate until it finishes.
            if total > 1 {
                onProgress(Double(index) / Double(total))
            }
            let data = try Data(contentsOf: chunk.url)
            AppLog.transcription.atDebug.debug("whisper: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) (\(data.count, privacy: .public) bytes)")
            let result = try await provider.transcribe(
                audioData: data,
                fileName: chunk.url.lastPathComponent,
                language: language
            )
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
        }

        return RawTranscript(spans: allSpans, language: detectedLanguage)
    }
}
