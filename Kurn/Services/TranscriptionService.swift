//
//  TranscriptionService.swift
//  Kurn
//
//  Orchestrates a full transcription: runs the chosen engine (on-device or
//  Whisper), runs heuristic diarization over the same audio, then fuses the two
//  into speaker-attributed `TranscriptSegment`s. Works in value types only so it
//  is decoupled from SwiftData and safe to call off the main actor.
//

import Foundation

struct TranscriptionService {

    /// Callback invoked as the pipeline advances through its stages. May be
    /// called from a background executor; the receiver is responsible for
    /// hopping to the main actor before touching UI state.
    typealias PhaseHandler = @Sendable (TranscriptionPhase) -> Void
    /// Reports a non-fatal diarization failure (e.g. a FluidAudio model
    /// download error). Transcription still succeeds with a fallback turn.
    typealias DiarizationWarningHandler = @Sendable (String) -> Void

    struct Output: Sendable {
        var segments: [TranscriptSegment]
        var language: String
        /// Distinct speaker labels in first-appearance order.
        var speakerLabels: [String]
    }

    /// Cap on a single fused segment's spoken duration before it's split.
    private let maxSegmentDuration: TimeInterval = 30

    private let onDevice = OnDeviceTranscriber()
    private let fluidAudioTranscriber = FluidAudioTranscriber()
    private let heuristicDiarizer = SpeakerDiarizer()
    private let fluidAudioDiarizer = FluidAudioDiarizer()
    private let chunker = AudioChunker()
    private let preprocessor = AudioPreprocessor()

    /// Transcribe one recording file and return diarized segments.
    /// - Parameter onPhase: optional progress callback reporting the active stage.
    func transcribe(
        fileURL: URL,
        fileName: String,
        language: MeetingLanguage,
        mode: TranscriptionMode,
        diarizationEngine: DiarizationEngine = .heuristic,
        onDeviceMultilingualEnabled: Bool = false,
        onPhase: @escaping PhaseHandler = { _ in },
        onDiarizationWarning: DiarizationWarningHandler? = nil
    ) async throws -> Output {
        let started = Date()
        AppLog.transcription.notice("transcribe: start file=\(fileName, privacy: .public) mode=\(mode.rawValue, privacy: .public) language=\(language.rawValue, privacy: .public)")

        // Clean the audio (high-pass, presence EQ, AGC/limiter, mono 16 kHz)
        // before transcription/diarization. If cleanup fails for any reason we
        // fall back to the original so transcription never breaks.
        onPhase(.preprocessing)
        AppLog.transcription.debug("transcribe: preprocessing…")
        let preStart = Date()
        let cleanedURL: URL
        do {
            cleanedURL = try await preprocessor.process(url: fileURL)
            AppLog.transcription.debug("transcribe: preprocessing done in \(Date().timeIntervalSince(preStart), privacy: .public)s -> cleaned copy")
        } catch {
            cleanedURL = fileURL
            AppLog.transcription.error("transcribe: preprocessing failed after \(Date().timeIntervalSince(preStart), privacy: .public)s, using original: \(error.localizedDescription, privacy: .public)")
        }
        defer {
            if cleanedURL != fileURL {
                let url = cleanedURL
                Task { await preprocessor.cleanup(url) }
            }
        }

        // Transcription and diarization both read the same file but are
        // independent, so run them concurrently instead of back to back.
        onPhase(.transcribing(progress: nil))
        AppLog.transcription.debug("transcribe: transcribing + diarizing (concurrent)…")
        let txStart = Date()
        async let rawTranscript = transcribeRaw(
            fileURL: cleanedURL,
            language: language,
            mode: mode,
            onDeviceMultilingualEnabled: onDeviceMultilingualEnabled,
            onPhase: onPhase
        )
        async let speakerTurns = diarize(
            url: cleanedURL,
            engine: diarizationEngine,
            onWarning: onDiarizationWarning
        )

        let raw = try await rawTranscript
        let turns = await speakerTurns
        AppLog.transcription.info("transcribe: engine done in \(Date().timeIntervalSince(txStart), privacy: .public)s spans=\(raw.spans.count, privacy: .public) turns=\(turns.count, privacy: .public)")

        onPhase(.finalizing)
        let segments = fuse(spans: raw.spans, turns: turns)

        var labels: [String] = []
        for segment in segments where !labels.contains(segment.speakerLabel) {
            labels.append(segment.speakerLabel)
        }

        AppLog.transcription.notice("transcribe: complete in \(Date().timeIntervalSince(started), privacy: .public)s segments=\(segments.count, privacy: .public) speakers=\(labels.count, privacy: .public)")
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
        mode: TranscriptionMode,
        onDeviceMultilingualEnabled: Bool,
        onPhase: @escaping PhaseHandler
    ) async throws -> RawTranscript {
        switch mode {
        case .onDevice:
            // Apple's recognizer needs a fixed locale and can't detect the
            // spoken language. When the meeting language is "Auto" and the user
            // has enabled the multilingual on-device model, route to FluidAudio
            // (Parakeet TDT v3) so the language is detected from the audio.
            // Pinned languages keep using Apple Speech (no download, and it
            // covers locales the multilingual model doesn't, e.g. ja/zh).
            if language == .autoDetect && onDeviceMultilingualEnabled {
                AppLog.transcription.info("transcribe: on-device auto-detect via FluidAudio multilingual ASR")
                return try await fluidAudioTranscriber.transcribe(url: fileURL, language: language)
            }
            return try await onDevice.transcribe(url: fileURL, language: language)
        case .whisperAPI:
            return try await transcribeViaWhisper(fileURL: fileURL, language: language, onPhase: onPhase)
        }
    }

    /// Dispatch to the chosen diarization engine. Both engines satisfy
    /// `Diarizing` and never throw, so this always returns usable turns.
    ///
    /// `fluidAudioDiarizer` is a single shared actor reused across concurrent
    /// transcriptions (different recordings can transcribe at once), so the
    /// warning handler is passed as a call argument rather than set on shared
    /// actor state beforehand — that would let one call's handler leak into
    /// another's result at the actor's next suspension point.
    private func diarize(
        url: URL,
        engine: DiarizationEngine,
        onWarning: DiarizationWarningHandler?
    ) async -> [SpeakerTurn] {
        switch engine {
        case .heuristic:
            return await heuristicDiarizer.diarize(url: url)
        case .fluidAudio:
            return await fluidAudioDiarizer.diarize(url: url, onDownloadFailure: onWarning)
        }
    }

    // MARK: - Whisper path (chunked upload)

    private func transcribeViaWhisper(
        fileURL: URL,
        language: MeetingLanguage,
        onPhase: @escaping PhaseHandler
    ) async throws -> RawTranscript {
        let provider = try ProviderFactory.whisperProvider()
        let chunks = try await chunker.chunk(url: fileURL)
        let total = chunks.count
        AppLog.transcription.info("whisper: uploading \(total, privacy: .public) chunk(s)")
        defer { Task { await chunker.cleanup(chunks) } }

        var allSpans: [TranscribedSpan] = []
        var detectedLanguage = ""

        for (index, chunk) in chunks.enumerated() {
            // Report progress before each upload so the UI advances as chunks
            // complete. Only meaningful when split into several chunks; a single
            // chunk stays indeterminate (nil) until it finishes.
            if total > 1 {
                onPhase(.transcribing(progress: Double(index) / Double(total)))
            }
            let data = try Data(contentsOf: chunk.url)
            AppLog.transcription.debug("whisper: chunk \(index + 1, privacy: .public)/\(total, privacy: .public) (\(data.count, privacy: .public) bytes)")
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
