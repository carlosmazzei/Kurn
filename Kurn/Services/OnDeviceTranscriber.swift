//
//  OnDeviceTranscriber.swift
//  Kurn
//
//  Apple's long-form, fully on-device transcription path. SpeechAnalyzer and
//  SpeechTranscriber are designed for meetings and distant/prerecorded audio;
//  the older SFSpeechRecognizer API is intended for short-form dictation and
//  can silently truncate longer files.
//

import AVFoundation
import Foundation
import KurnCore
import Speech

actor OnDeviceTranscriber: Transcribing {

    /// Ask the user for speech-recognition authorization.
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        let requestedLocale = Locale(
            identifier: language.localeIdentifier ?? Locale.current.identifier
        )
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            AppLog.transcription.atError.error(
                "speechAnalyzer: unsupported locale \(requestedLocale.identifier, privacy: .public)"
            )
            throw AppError.transcriptionLanguageUnsupported(language, .appleSpeech)
        }

        AppLog.transcription.atNotice.notice(
            "speechAnalyzer: locale=\(locale.identifier, privacy: .public)"
        )
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )

        // The new Speech framework manages locale-specific model assets. If the
        // selected locale isn't installed yet, download it before analysis.
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                AppLog.transcription.atNotice.notice(
                    "speechAnalyzer: installing locale assets"
                )
                try await installation.downloadAndInstall()
            }
        } catch {
            AppLog.transcription.atError.error(
                "speechAnalyzer: asset installation failed: \(error.localizedDescription, privacy: .public)"
            )
            throw AppError.transcriptionFailed(error.localizedDescription)
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        onProgress(0)

        let resultTask = Task { () throws -> [TranscribedSpan] in
            var spans: [TranscribedSpan] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let start = CMTimeGetSeconds(result.range.start)
                let rangeDuration = CMTimeGetSeconds(result.range.duration)
                guard start.isFinite, rangeDuration.isFinite else { continue }
                spans.append(
                    contentsOf: Self.spans(
                        words: Self.timedWords(in: result.text),
                        text: text,
                        resultStart: max(0, start),
                        resultEnd: max(0, start + rangeDuration),
                        duration: duration
                    )
                )
                if duration > 0 {
                    onProgress(min(0.99, max(0, (start + rangeDuration) / duration)))
                }
            }
            return spans
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let spans = try await resultTask.value.sorted { $0.start < $1.start }
            guard !spans.isEmpty else {
                throw AppError.transcriptionFailed(
                    NSLocalizedString("error.no_speech_detected", comment: "No speech detected")
                )
            }
            onProgress(1)
            let covered = spans.reduce(0) { $0 + max(0, $1.end - $1.start) }
            AppLog.transcription.atNotice.notice(
                "speechAnalyzer: complete spans=\(spans.count, privacy: .public) covered=\(String(format: "%.1f", covered), privacy: .public)s"
            )
            return RawTranscript(spans: spans, language: locale.identifier)
        } catch let appError as AppError {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw appError
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            AppLog.transcription.atError.error(
                "speechAnalyzer: transcription failed: \(error.localizedDescription, privacy: .public)"
            )
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Word timings

    /// One recognizer result as the spans it should contribute.
    ///
    /// Pure and `static` so the decision — *when* word timings are trustworthy —
    /// can be tested without the Speech framework, a locale asset or a device.
    ///
    /// The timeline check is the point of it. `audioTimeRange` is documented on
    /// the same timeline as `result.range`, and if a future SDK ever reported it
    /// relative to the result instead, every word would land near zero: the
    /// transcript would still read correctly, the timestamps would be silently
    /// wrong, and speaker attribution would collapse onto whoever spoke first.
    /// Rather than trust it, check that the words land where the result says they
    /// should, and fall back to the result-level span when they don't.
    static func spans(
        words: [TimedWord],
        text: String,
        resultStart: TimeInterval,
        resultEnd: TimeInterval,
        duration: TimeInterval
    ) -> [TranscribedSpan] {
        let wholeResult = [
            TranscribedSpan(text: text, start: resultStart, end: resultEnd, confidence: nil)
        ]
        guard let first = words.first, let last = words.last else { return wholeResult }

        let tolerance: TimeInterval = 1
        guard first.start >= resultStart - tolerance,
              last.end <= resultEnd + tolerance else {
            AppLog.transcription.atError.error(
                "speechAnalyzer: word timings \(first.start, privacy: .public)…\(last.end, privacy: .public) fall outside result \(resultStart, privacy: .public)…\(resultEnd, privacy: .public); using the result span"
            )
            return wholeResult
        }

        let built = TimedWordSpanBuilder.spans(from: words, fallbackText: "", duration: duration)
        return built.isEmpty ? wholeResult : built
    }

    /// Pull the per-run `audioTimeRange` the `.timeIndexedProgressiveTranscription`
    /// preset attaches. Runs without one are skipped rather than guessed at.
    private static func timedWords(in text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(range.end)
            guard start.isFinite, end.isFinite, end > start else { continue }
            words.append(TimedWord(text: piece, start: max(0, start), end: max(0, end)))
        }
        return words
    }
}
