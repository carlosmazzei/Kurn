//
//  PipelineEngineCatalogLiveTests.swift
//  KurnTests
//
//  The production catalog maps every configuration choice to the engine it
//  names — the orchestrator tests run on fakes, so this is the only place
//  that mapping is checked — and the live adapters forward a request to the
//  engine underneath. Nothing here runs a model or reaches the network.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct PipelineEngineCatalogLiveTests {

    private let live = PipelineEngineCatalog.live

    @Test func everyPreprocessingChoiceResolves() {
        #expect(live.preprocessor(.standardDSP) is AudioPreprocessor)
        #expect(live.preprocessor(.none) is PassthroughPreprocessor)
    }

    @Test func everyLanguageDetectionChoiceResolves() {
        #expect(live.languageDetector(.byTranscriber) is NoOpLanguageDetector)
        #expect(live.languageDetector(.fluidAudioLID) is FluidAudioLanguageDetector)
    }

    @Test func everyVADChoiceResolves() {
        #expect(live.vad(.energyThreshold) is EnergyVAD)
        #expect(live.vad(.fluidAudio) is FluidAudioVAD)
    }

    @Test func everyTranscriptionChoiceResolves() {
        #expect(live.transcriber(.appleSpeech) is OnDeviceTranscriber)
        #expect(live.transcriber(.fluidAudioParakeet) is FluidAudioTranscriber)
        #expect(live.transcriber(.whisperAPI) is WhisperTranscriber)
        #expect(live.transcriber(.whisperCpp) is WhisperCppTranscriber)
    }

    @Test func everyDiarizationChoiceResolves() {
        #expect(live.diarizer(.heuristic) is SpeakerDiarizer)
        #expect(live.diarizer(.fluidAudio) is FluidAudioDiarizer)
        #expect(live.diarizer(.sherpaOnnx) is SherpaOnnxDiarizer)
        // Never called for provider-native turns; the defensive answer is the
        // engine that needs nothing.
        #expect(live.diarizer(.transcriptionProviderNative) is SpeakerDiarizer)
    }

    @Test func everyCorrectionChoiceResolves() {
        #expect(live.corrector(.none) is NoOpTranscriptCorrector)
        #expect(live.corrector(.llm) is LLMTranscriptCorrector)
    }

    @Test func sharedStagesAreTheLiveEngines() {
        #expect(live.diarizationPreprocessor is DiarizationPreprocessor)
        #expect(live.compactor is VADAudioCompactor)
    }

    @Test func liveEnginesAreReusedAcrossCalls() {
        let first = live.transcriber(.whisperAPI) as? WhisperTranscriber
        let second = live.transcriber(.whisperAPI) as? WhisperTranscriber
        #expect(first != nil)
        #expect(first === second)
    }

    // MARK: - Adapters

    @Test func noOpLanguageDetectionReturnsTheHint() async {
        #expect(await NoOpLanguageDetector().detect(url: AudioFixtures.tempURL(), hint: .german) == .german)
    }

    @Test func aPinnedLanguageNeedsNoDetection() async {
        #expect(await FluidAudioLanguageDetector().detect(url: AudioFixtures.tempURL(), hint: .italian) == .italian)
    }

    @Test func theWhisperAdapterForwardsTheRequest() async throws {
        let url = try AudioFixtures.m4aTone(seconds: 1, sampleRate: 16_000, bitRate: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let models = Recorded<String>()
        let transcriber = WhisperTranscriber(resolveProvider: { provider, model, _ in
            models.append(model)
            return EchoTranscriptionProvider(provider: provider)
        })
        let chunks = Recorded<ChunkProgress>()
        let request = EngineTranscriptionRequest(
            url: url,
            language: .english,
            provider: .openAI,
            model: "whisper-1",
            transferPolicy: .wifiOnly,
            whisperCppModel: .small,
            cutPoints: [],
            resume: nil,
            onChunkCompleted: nil,
            onProgress: { _, chunk in if let chunk { chunks.append(chunk) } }
        )
        let transcript = try await transcriber.transcribe(request)
        #expect(transcript.spans.map(\.text) == ["echo"])
        #expect(models.values == ["whisper-1"])
        #expect(chunks.values.allSatisfy { $0.total == 1 })
    }

    @Test func theHeuristicDiarizerAdapterReportsTurnsWithoutVoiceprints() async throws {
        let url = try AudioFixtures.twoSpeakerWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = await SpeakerDiarizer().diarize(PipelineDiarizationRequest(
            url: url,
            regions: [SpeechRegion(start: 0, end: 1.5), SpeechRegion(start: 2.4, end: 3.9)],
            speakerCount: 0,
            onWarning: nil,
            onProgress: { _ in }
        ))
        #expect(!outcome.turns.isEmpty)
        #expect(outcome.voiceprints.isEmpty)
    }
}

private struct EchoTranscriptionProvider: TranscriptionProvider {
    let provider: AIProvider
    func transcribe(audioData: Data, fileName: String, language: MeetingLanguage) async throws -> RawTranscript {
        RawTranscript(spans: [TranscribedSpan(text: "echo", start: 0, end: 0.5)], language: "en")
    }
}
