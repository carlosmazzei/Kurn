//
//  ChunkedTranscriptionRunner.swift
//  Kurn
//
//  Shared chunk loop for the resumable transcription engines (Whisper and Apple
//  Speech): iterates a chunk plan, offsets each chunk's spans back to the
//  input's absolute timeline, reports durable progress after every chunk, and
//  honors cooperative cancellation between chunks. Given the same input file
//  the chunk plan is deterministic, so a persisted `Progress` from an earlier
//  interrupted run can seed the loop to skip already-transcribed chunks.
//

import Foundation

enum ChunkedTranscriptionRunner {

    /// Accumulated state of the chunk loop. Persisted (via
    /// `TranscriptionCheckpoint`) after every chunk so interruption at any
    /// point loses at most the in-flight chunk.
    struct Progress: Sendable {
        var totalChunks: Int
        var completedChunks: Int
        var detectedLanguage: String
        /// Spans of completed chunks, offset to the input file's timeline.
        var spans: [TranscribedSpan]
    }

    /// Run the chunk loop, optionally resuming from prior progress.
    /// - Parameters:
    ///   - chunks: the (re-)derived chunk plan for the input file.
    ///   - resume: progress from an interrupted run; ignored when its chunk
    ///     count doesn't match the current plan.
    ///   - transcribeChunk: transcribes one chunk (given its zero-based index)
    ///     into chunk-local spans.
    ///   - onChunkCompleted: durable-progress sink invoked after each chunk.
    ///   - onProgress: 0...1 fraction of chunks completed, plus the current
    ///     chunk number and total (the current chunk is clamped to `1...total`).
    static func run(
        chunks: [AudioChunker.Chunk],
        resume: Progress?,
        transcribeChunk: @Sendable (AudioChunker.Chunk, Int) async throws -> RawTranscript,
        onChunkCompleted: (@Sendable (Progress) -> Void)? = nil,
        onProgress: @Sendable (Double, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> RawTranscript {
        var state: Progress
        if let resume, resume.totalChunks == chunks.count,
           (0...chunks.count).contains(resume.completedChunks) {
            state = resume
            AppLog.transcription.atNotice.notice("chunked: resuming at chunk \(resume.completedChunks + 1, privacy: .public)/\(chunks.count, privacy: .public)")
        } else {
            if resume != nil {
                AppLog.transcription.atNotice.notice("chunked: checkpoint plan mismatch, starting over")
            }
            state = Progress(totalChunks: chunks.count, completedChunks: 0, detectedLanguage: "", spans: [])
        }

        let total = max(1, chunks.count)
        onProgress(
            chunks.isEmpty ? 1 : Double(state.completedChunks) / Double(total),
            max(1, min(total, state.completedChunks + 1)),
            total
        )

        for index in state.completedChunks..<chunks.count {
            try Task.checkCancellation()
            let chunk = chunks[index]
            let result = try await transcribeChunk(chunk, index)
            if state.detectedLanguage.isEmpty {
                state.detectedLanguage = result.language
            }
            // Offset chunk-local timestamps back to the input's timeline.
            for span in result.spans {
                state.spans.append(
                    TranscribedSpan(
                        text: span.text,
                        start: span.start + chunk.offset,
                        end: span.end + chunk.offset,
                        confidence: span.confidence
                    )
                )
            }
            state.completedChunks = index + 1
            onChunkCompleted?(state)
            // Advance after each chunk completes so the bar reaches 100% when
            // the last chunk lands (rather than stalling at (total-1)/total).
            // The current chunk is the next one in flight (or the last one if
            // this was the final chunk).
            let currentChunk = max(1, min(total, index + 2))
            onProgress(Double(index + 1) / Double(total), currentChunk, total)
        }

        return RawTranscript(spans: state.spans, language: state.detectedLanguage)
    }
}

// MARK: - Checkpoint bridging

extension TranscriptionCheckpoint {
    init(
        engine: TranscriptionEngine,
        language: MeetingLanguage,
        compacted: Bool,
        providerID: String? = nil,
        progress: ChunkedTranscriptionRunner.Progress
    ) {
        self.init(
            engineRaw: engine.rawValue,
            languageRaw: language.rawValue,
            compacted: compacted,
            totalChunks: progress.totalChunks,
            completedChunks: progress.completedChunks,
            detectedLanguage: progress.detectedLanguage,
            providerID: providerID,
            spans: progress.spans.map {
                Span(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
        )
    }

    var runnerProgress: ChunkedTranscriptionRunner.Progress {
        ChunkedTranscriptionRunner.Progress(
            totalChunks: totalChunks,
            completedChunks: completedChunks,
            detectedLanguage: detectedLanguage,
            spans: spans.map {
                TranscribedSpan(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
        )
    }
}
