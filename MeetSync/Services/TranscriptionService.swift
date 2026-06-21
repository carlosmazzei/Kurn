//
//  TranscriptionService.swift
//  MeetSync
//
//  Orchestrates a full transcription: runs the chosen engine (on-device or
//  Whisper), runs heuristic diarization over the same audio, then fuses the two
//  into speaker-attributed `TranscriptSegment`s. Works in value types only so it
//  is decoupled from SwiftData and safe to call off the main actor.
//

import Foundation

struct TranscriptionService {

    struct Output: Sendable {
        var segments: [TranscriptSegment]
        var language: String
        /// Distinct speaker labels in first-appearance order.
        var speakerLabels: [String]
    }

    /// Cap on a single fused segment's spoken duration before it's split.
    private let maxSegmentDuration: TimeInterval = 30

    private let onDevice = OnDeviceTranscriber()
    private let diarizer = SpeakerDiarizer()
    private let chunker = AudioChunker()

    /// Transcribe one recording file and return diarized segments.
    func transcribe(
        fileURL: URL,
        fileName: String,
        language: MeetingLanguage,
        mode: TranscriptionMode
    ) async throws -> Output {
        // Transcription and diarization both read the same file but are
        // independent, so run them concurrently instead of back to back.
        async let rawTranscript = transcribeRaw(fileURL: fileURL, language: language, mode: mode)
        async let speakerTurns = diarizer.diarize(url: fileURL)

        let raw = try await rawTranscript
        let turns = await speakerTurns
        let segments = fuse(spans: raw.spans, turns: turns)

        var labels: [String] = []
        for segment in segments where !labels.contains(segment.speakerLabel) {
            labels.append(segment.speakerLabel)
        }

        return Output(
            segments: segments,
            language: raw.language,
            speakerLabels: labels
        )
    }

    /// Run the chosen transcription engine for the file.
    private func transcribeRaw(
        fileURL: URL,
        language: MeetingLanguage,
        mode: TranscriptionMode
    ) async throws -> RawTranscript {
        switch mode {
        case .onDevice:
            return try await onDevice.transcribe(url: fileURL, language: language)
        case .whisperAPI:
            return try await transcribeViaWhisper(fileURL: fileURL, language: language)
        }
    }

    // MARK: - Whisper path (chunked upload)

    private func transcribeViaWhisper(
        fileURL: URL,
        language: MeetingLanguage
    ) async throws -> RawTranscript {
        let provider = try ProviderFactory.whisperProvider()
        let chunks = try await chunker.chunk(url: fileURL)
        defer { Task { await chunker.cleanup(chunks) } }

        var allSpans: [TranscribedSpan] = []
        var detectedLanguage = ""

        for chunk in chunks {
            let data = try Data(contentsOf: chunk.url)
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

    // MARK: - Fusion

    /// Attribute each text span to a speaker turn, then merge consecutive
    /// same-speaker spans into segments (capped at `maxSegmentDuration`).
    private func fuse(spans: [TranscribedSpan], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !spans.isEmpty else { return [] }

        var segments: [TranscriptSegment] = []
        var currentLabel: String?
        var currentText: [String] = []
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        var confidenceSum: Float = 0
        var confidenceCount = 0

        func flush() {
            guard let label = currentLabel, !currentText.isEmpty else { return }
            let text = currentText.joined(separator: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let confidence = confidenceCount > 0 ? confidenceSum / Float(confidenceCount) : nil
            segments.append(
                TranscriptSegment(
                    speakerLabel: label,
                    startTime: currentStart,
                    endTime: currentEnd,
                    text: text,
                    confidence: confidence
                )
            )
            currentText = []
            confidenceSum = 0
            confidenceCount = 0
        }

        for span in spans {
            let label = speakerLabel(for: span, in: turns)
            let wouldExceed = currentLabel != nil
                && (span.end - currentStart) > maxSegmentDuration

            if label != currentLabel || wouldExceed {
                flush()
                currentLabel = label
                currentStart = span.start
            }
            currentText.append(span.text)
            currentEnd = span.end
            if let c = span.confidence {
                confidenceSum += c
                confidenceCount += 1
            }
        }
        flush()

        return segments
    }

    /// Pick the speaker whose turn best overlaps the span's midpoint, falling
    /// back to the nearest turn by start time.
    private func speakerLabel(for span: TranscribedSpan, in turns: [SpeakerTurn]) -> String {
        guard !turns.isEmpty else { return "Speaker 1" }
        let mid = (span.start + span.end) / 2

        if let containing = turns.first(where: { mid >= $0.start && mid < $0.end }) {
            return containing.speakerLabel
        }
        // Nearest by distance to the turn's range.
        let nearest = turns.min { a, b in
            distance(from: mid, to: a) < distance(from: mid, to: b)
        }
        return nearest?.speakerLabel ?? "Speaker 1"
    }

    private func distance(from time: TimeInterval, to turn: SpeakerTurn) -> TimeInterval {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }
}
