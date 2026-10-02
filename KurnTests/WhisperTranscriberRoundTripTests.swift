//
//  WhisperTranscriberRoundTripTests.swift
//  KurnTests
//
//  Cloud transcription driven end to end over a real chunked file, with a
//  scripted provider in place of the network: the plain entry point refuses
//  without consent, spans come back on the file's timeline, an untimed reply
//  is spread over its chunk, durable progress is reported, and a provider
//  failure stops the run.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

private final class ScriptedTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    let provider = AIProvider.openAI
    private let reply: @Sendable (Int) throws -> RawTranscript
    private let lock = NSLock()
    private var _uploads: [(fileName: String, bytes: Int, language: MeetingLanguage)] = []

    init(reply: @escaping @Sendable (Int) throws -> RawTranscript) {
        self.reply = reply
    }

    var uploads: [(fileName: String, bytes: Int, language: MeetingLanguage)] { lock.withLock { _uploads } }

    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript {
        let index = lock.withLock { () -> Int in
            _uploads.append((fileName, audioData.count, language))
            return _uploads.count - 1
        }
        return try reply(index)
    }
}

struct WhisperTranscriberRoundTripTests {

    private struct UploadFailed: Error {}

    @Test func thePlainEntryPointRequiresConsent() async {
        let transcriber = WhisperTranscriber(resolveProvider: { _, _, _ in
            ScriptedTranscriptionProvider { _ in RawTranscript(spans: [], language: "") }
        })
        do {
            _ = try await transcriber.transcribe(url: AudioFixtures.tempURL(), language: .english)
            Issue.record("expected a refusal")
        } catch let error as AppError {
            #expect(error.logCode == AppError.permissionDenied("").logCode)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func uploadsTheFileAndReturnsTheProviderSpans() async throws {
        let url = try AudioFixtures.m4aTone(seconds: 2, sampleRate: 16_000, bitRate: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ScriptedTranscriptionProvider { _ in
            RawTranscript(spans: [TranscribedSpan(text: "hello", start: 0.2, end: 0.9)], language: "en")
        }
        let checkpoints = Recorded<Int>()
        let fractions = Recorded<Double>()
        let resolved = Recorded<String>()
        let transcriber = WhisperTranscriber(resolveProvider: { vendor, model, _ in
            resolved.append("\(vendor.id)/\(model)")
            return provider
        })

        let transcript = try await transcriber.transcribeResumable(
            url: url,
            language: .english,
            provider: .openAI,
            model: "whisper-1",
            onChunkCompleted: { progress in checkpoints.append(progress.completedChunks) },
            onProgress: { fraction, _, _ in fractions.append(fraction) }
        )

        #expect(transcript.spans.map(\.text) == ["hello"])
        #expect(transcript.spans.first?.start == 0.2)
        #expect(provider.uploads.count == 1)
        #expect(provider.uploads.first?.language == .english)
        #expect((provider.uploads.first?.bytes ?? 0) > 0)
        #expect(checkpoints.values == [1])
        #expect(resolved.values == ["\(AIProvider.openAI.id)/whisper-1"])
        #expect(fractions.values.allSatisfy { (0...1).contains($0) })
    }

    @Test func anUntimedReplyIsSpreadOverItsChunk() async throws {
        let url = try AudioFixtures.m4aTone(seconds: 2, sampleRate: 16_000, bitRate: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ScriptedTranscriptionProvider { _ in
            RawTranscript(
                spans: [TranscribedSpan(text: "one", start: 0, end: 0), TranscribedSpan(text: "two", start: 0, end: 0)],
                language: "en"
            )
        }
        let transcript = try await WhisperTranscriber(resolveProvider: { _, _, _ in provider }).transcribeResumable(
            url: url, language: .english, provider: .openAI, model: "gpt-4o-transcribe"
        )
        #expect(transcript.spans.map(\.text) == ["one", "two"])
        let first = try #require(transcript.spans.first)
        let second = try #require(transcript.spans.last)
        #expect(first.start == 0)
        #expect(first.end > 0)
        #expect(abs(second.start - first.end) < 0.000_1)
        #expect(second.end > 1.5)
    }

    @Test func aFailedUploadStopsTheRun() async throws {
        let url = try AudioFixtures.m4aTone(seconds: 1, sampleRate: 16_000, bitRate: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = ScriptedTranscriptionProvider { _ in throw UploadFailed() }
        await #expect(throws: UploadFailed.self) {
            _ = try await WhisperTranscriber(resolveProvider: { _, _, _ in provider }).transcribeResumable(
                url: url, language: .portuguese, provider: .openAI, model: "whisper-1"
            )
        }
    }

    @Test func aProviderThatCannotBeResolvedFailsBeforeAnyUpload() async {
        await #expect(throws: AppError.self) {
            _ = try await WhisperTranscriber(resolveProvider: { _, _, _ in throw AppError.noAPIKey(provider: "OpenAI") })
                .transcribeResumable(url: AudioFixtures.tempURL(), language: .english, provider: .openAI, model: "whisper-1")
        }
    }
}
