//
//  TranscriptionInputPreparationTests.swift
//  KurnTests
//
//  `TranscriptionService.prepareInput` with the engines that need nothing
//  downloaded (passthrough or DSP preprocessing, energy VAD, no-op language
//  detection). Checks the stage reports, which are the only place the
//  degraded paths — cleanup failing, a detector deferring to its hint, VAD
//  finding nothing — leave a trace.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct TranscriptionInputPreparationTests {

    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [TranscriptionPhase] = []
        func record(_ phase: TranscriptionPhase) {
            lock.lock(); defer { lock.unlock() }
            phases.append(phase)
        }
        var recorded: [TranscriptionPhase] {
            lock.lock(); defer { lock.unlock() }
            return phases
        }
    }

    private func onDeviceConfig(preprocessing: PreprocessingEngine) -> PipelineConfiguration {
        var config = PipelineConfiguration()
        config.preprocessing = preprocessing
        config.vad = .energyThreshold
        config.languageDetection = .byTranscriber
        return config
    }

    private func report(_ stages: [PipelineStageReport], _ stage: PipelineStage) -> PipelineStageReport? {
        stages.first { $0.stage == stage }
    }

    @Test func passthroughPreprocessingKeepsOriginalAndReportsSkipped() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(440, 1.0), (0, 0.8), (440, 1.0)])
            defer { try? FileManager.default.removeItem(at: url) }
            let phases = PhaseRecorder()

            let prepared = try await TranscriptionService().prepareInput(
                fileURL: url,
                config: onDeviceConfig(preprocessing: .none),
                language: .english,
                onPhase: { phases.record($0) }
            )

            #expect(prepared.cleanedURL == url)
            #expect(prepared.language == .english)
            #expect(!prepared.regions.isEmpty)
            #expect(prepared.stages.map(\.stage) == [.preprocessing, .languageDetection, .voiceActivityDetection])

            let pre = try #require(report(prepared.stages, .preprocessing))
            #expect(pre.outcome == .skipped)
            #expect(pre.reason == .notRequested)
            #expect(!pre.isWarning)

            let lid = try #require(report(prepared.stages, .languageDetection))
            #expect(lid.outcome == .skipped)
            #expect(lid.reason == .notRequested)

            let vad = try #require(report(prepared.stages, .voiceActivityDetection))
            #expect(vad.outcome == .succeeded)
            #expect(vad.reason == nil)

            // The no-op detector does no work, so its phase must not flash in the UI.
            #expect(phases.recorded == [.preprocessing, .detectingSpeech])
        }
    }

    @Test func dspPreprocessingProducesACleanedCopyAndReportsSuccess() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.m4aTone(seconds: 1.5)
            defer { try? FileManager.default.removeItem(at: url) }
            let service = TranscriptionService()

            let prepared = try await service.prepareInput(
                fileURL: url,
                config: onDeviceConfig(preprocessing: .standardDSP),
                language: .portuguese,
                onPhase: { _ in }
            )
            defer { try? FileManager.default.removeItem(at: prepared.cleanedURL) }

            #expect(prepared.cleanedURL != url)
            #expect(FileManager.default.fileExists(atPath: prepared.cleanedURL.path))
            let pre = try #require(report(prepared.stages, .preprocessing))
            #expect(pre.outcome == .succeeded)
            #expect(pre.requestedEngine == PreprocessingEngine.standardDSP.rawValue)
            #expect(pre.effectiveEngine == PreprocessingEngine.standardDSP.rawValue)
            #expect(!pre.fellBack)
        }
    }

    @Test func unreadableAudioFallsBackToOriginalAndReportsDegradedPreprocessing() async throws {
        try await tempFileTestLock.run {
            let url = AudioFixtures.tempURL(ext: "m4a")
            try Data("not audio".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let prepared = try await TranscriptionService().prepareInput(
                fileURL: url,
                config: onDeviceConfig(preprocessing: .standardDSP),
                language: .english,
                onPhase: { _ in }
            )

            #expect(prepared.cleanedURL == url)
            let pre = try #require(report(prepared.stages, .preprocessing))
            #expect(pre.outcome == .degraded)
            #expect(pre.reason == .originalAudioUsed)
            #expect(pre.effectiveEngine == PreprocessingEngine.none.rawValue)
            #expect(pre.fellBack)
            #expect(pre.isWarning)

            // The energy VAD never returns nothing — an unreadable file yields a
            // single zero-length region, which the report records as a success
            // because the stage did produce output. The transcription stage is
            // what fails on this file.
            let vad = try #require(report(prepared.stages, .voiceActivityDetection))
            #expect(prepared.regions == [SpeechRegion(start: 0, end: 0)])
            #expect(vad.outcome == .succeeded)
        }
    }

    @Test func silentAudioYieldsOneWholeClipRegion() async throws {
        try await tempFileTestLock.run {
            let url = try AudioFixtures.wav(segments: [(0, 2.0)])
            defer { try? FileManager.default.removeItem(at: url) }

            let prepared = try await TranscriptionService().prepareInput(
                fileURL: url,
                config: onDeviceConfig(preprocessing: .none),
                language: .autoDetect,
                onPhase: { _ in }
            )

            // Silence gating has nothing to gate, so the whole clip is handed on
            // as one region rather than dropping the recording on the floor.
            #expect(prepared.regions.count == 1)
            let region = try #require(prepared.regions.first)
            #expect(region.start == 0)
            #expect(abs(region.end - 2.0) < 0.15)
            let vad = try #require(report(prepared.stages, .voiceActivityDetection))
            #expect(vad.outcome == .succeeded)
            #expect(!vad.isWarning)
        }
    }

    @Test func cancellationBeforePreparationPropagatesAsCancellationError() async throws {
        let url = try AudioFixtures.wav(segments: [(440, 0.5)])
        defer { try? FileManager.default.removeItem(at: url) }
        let config = onDeviceConfig(preprocessing: .none)

        let task = Task {
            try await TranscriptionService().prepareInput(
                fileURL: url, config: config, language: .english, onPhase: { _ in }
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
