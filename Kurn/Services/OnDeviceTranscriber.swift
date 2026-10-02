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
                "speechAnalyzer: asset installation failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
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
                guard !text.isEmpty,
                      let bounds = AppleSpeechResultAssembly.resultBounds(
                          start: CMTimeGetSeconds(result.range.start),
                          duration: CMTimeGetSeconds(result.range.duration)
                      ) else { continue }
                let assembly = AppleSpeechResultAssembly.assemble(
                    words: Self.timedWords(in: result.text),
                    text: text,
                    resultStart: bounds.start,
                    resultEnd: bounds.end,
                    duration: duration
                )
                if assembly.rejectedWordTimings {
                    AppLog.transcription.atError.error(
                        "speechAnalyzer: word timings fall outside result \(bounds.start, privacy: .public)…\(bounds.end, privacy: .public); using the result span"
                    )
                }
                spans.append(contentsOf: assembly.spans)
                if let fraction = AppleSpeechResultAssembly.progress(resultEnd: bounds.end, duration: duration) {
                    onProgress(fraction)
                }
            }
            return spans
        }

        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let recognized = try await resultTask.value
            guard let spans = AppleSpeechResultAssembly.finished(recognized) else {
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
                "speechAnalyzer: transcription failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Word timings

    /// Pull the per-run `audioTimeRange` the `.timeIndexedProgressiveTranscription`
    /// preset attaches. Runs without one are skipped rather than guessed at.
    private static func timedWords(in text: AttributedString) -> [TimedWord] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            return AppleSpeechResultAssembly.word(
                text: String(text[run.range].characters),
                start: CMTimeGetSeconds(range.start),
                end: CMTimeGetSeconds(range.end)
            )
        }
    }
}
