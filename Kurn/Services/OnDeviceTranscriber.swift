//
//  OnDeviceTranscriber.swift
//  Kurn
//
//  SFSpeechRecognizer-based offline transcription. Runs entirely on-device
//  (`requiresOnDeviceRecognition = true`) so it works with no network. Produces
//  word-level spans with timestamps that the diarizer/segmenter later groups.
//

import AVFoundation
import Foundation
import os
import Speech

actor OnDeviceTranscriber {

    /// Ask the user for speech-recognition authorization.
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribe an audio file fully offline.
    /// - Parameters:
    ///   - url: local .m4a file.
    ///   - language: desired `MeetingLanguage`; auto-detect falls back to the
    ///     device locale.
    func transcribe(url: URL, language: MeetingLanguage) async throws -> RawTranscript {
        let locale: Locale
        if let id = language.localeIdentifier {
            locale = Locale(identifier: id)
        } else {
            locale = Locale.current
        }

        AppLog.transcription.debug("onDevice: locale=\(locale.identifier, privacy: .public)")
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            AppLog.transcription.error("onDevice: recognizer unavailable for locale")
            throw AppError.transcriptionFailed(
                NSLocalizedString("error.recognizer_unavailable", comment: "Recognizer unavailable")
            )
        }
        guard recognizer.isAvailable else {
            AppLog.transcription.error("onDevice: recognizer not available (offline/unsupported)")
            throw AppError.transcriptionFailed(
                NSLocalizedString("error.recognizer_offline", comment: "Recognizer offline")
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        // On-device recognition is roughly real-time or faster; allow a generous
        // multiple of the clip length (with a floor) before treating a task that
        // never reports a final result or error as stuck.
        let durationSeconds = (try? await AVURLAsset(url: url).load(.duration))
            .map(CMTimeGetSeconds) ?? 0
        let timeout = max(60, durationSeconds * 4)
        AppLog.transcription.debug("onDevice: recognizing (clip=\(durationSeconds, privacy: .public)s, timeout=\(timeout, privacy: .public)s)")

        let spans: [TranscribedSpan] = try await withCheckedThrowingContinuation { continuation in
            // Guard against the continuation being resumed more than once: the
            // Speech API can deliver a final result and an error in some cases.
            let box = ResumeBox()
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if box.resumeIfNeeded() {
                        continuation.resume(
                            throwing: AppError.transcriptionFailed(error.localizedDescription)
                        )
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                let segments = result.bestTranscription.segments
                let mapped = segments.map { seg in
                    TranscribedSpan(
                        text: seg.substring,
                        start: seg.timestamp,
                        end: seg.timestamp + seg.duration,
                        confidence: seg.confidence
                    )
                }
                if box.resumeIfNeeded() {
                    continuation.resume(returning: mapped)
                }
            }
            // Safety net: if the task ends without ever delivering a final result
            // or an error, resume so the caller doesn't hang forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.resumeIfNeeded() {
                    box.task?.cancel()
                    continuation.resume(
                        throwing: AppError.transcriptionFailed(
                            NSLocalizedString(
                                "error.recognizer_timeout",
                                comment: "Recognition timed out"
                            )
                        )
                    )
                }
            }
        }

        return RawTranscript(spans: spans, language: locale.identifier)
    }
}

/// Tiny actor-free helper to ensure a continuation is resumed exactly once.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    /// The recognition task, held so the timeout safety net can cancel it
    /// without capturing a non-Sendable value into the dispatch closure.
    var task: SFSpeechRecognitionTask?
    func resumeIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
