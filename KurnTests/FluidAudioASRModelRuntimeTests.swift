import Foundation
import KurnCore
import Testing
@testable import Kurn

#if canImport(FluidAudio)
import CoreML
import FluidAudio

struct FluidAudioASRModelRuntimeTests {
    @Test func tdtVersionsNeverResolveToADifferentModel() {
        #expect(FluidAudioASRModelRuntime.asrVersion(for: .parakeetV3) == .v3)
        #expect(FluidAudioASRModelRuntime.asrVersion(for: .bark3) == .bark3)
        #expect(FluidAudioASRModelRuntime.asrVersion(for: .bark3Clean) == .bark3Clean)
        #expect(FluidAudioASRModelRuntime.asrVersion(for: .phonon2) == .phonon2)
        #expect(FluidAudioASRModelRuntime.asrVersion(for: .nemotronUnified) == nil)
        #expect(FluidAudioASRModelRuntime.asrVersion(for: .nemotronTranscribeLite) == nil)
    }

    @Test func unifiedLanguageMappingRetainsAutoAndRejectsUnsupportedLanguages() {
        #expect(FluidAudioASRModelRuntime.unifiedLanguage(for: .autoDetect) == .auto)
        #expect(FluidAudioASRModelRuntime.unifiedLanguage(for: .portuguese) == .pt)
        #expect(FluidAudioASRModelRuntime.unifiedLanguage(for: .japanese) == nil)
        #expect(FluidAudioASRModelRuntime.unifiedConfig(.auto).family.promptId == NemotronUnifiedLanguage.auto.promptId)
        #expect(FluidAudioASRModelRuntime.unifiedConfig(.pt).family.promptId == NemotronUnifiedLanguage.pt.promptId)
    }

    @Test func iOSUsesFP16AndAvoidsGPUOnlyLiteLoading() {
        #expect(FluidAudioASRModelRuntime.unifiedPrecision == .fp16)
        #expect(FluidAudioASRModelRuntime.transcribeLiteComputeUnits == .cpuAndNeuralEngine)
    }

    @Test func batchAndStreamingHaveDifferentEncodersAndOnlyShareFourFiles() {
        let batch = Set(FluidAudioASRModelRuntime.unifiedBatchFiles)
        let streaming = Set(FluidAudioASRModelRuntime.unifiedStreamingFiles)
        #expect(batch.intersection(streaming) == Set(FluidAudioASRModelRuntime.unifiedSharedFiles))
        #expect(batch.subtracting(streaming) == ["nemotron_unified_encoder.mlmodelc"])
        #expect(streaming.subtracting(batch) == ["nemotron_unified_encoder_streaming_70_13_13.mlmodelc"])
        #expect(batch.count == 5)
        #expect(streaming.count == 5)
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func installationUsesOnlyTheSelectedModelsDirectory(model: FluidAudioASRModel) {
        let installation = FluidAudioASRModelRuntime.installation(for: model)
        let suffix = model == .nemotronUnified ? "/\(model.folderName)/coreml" : "/\(model.folderName)"
        #expect(installation.directory.path.hasSuffix(suffix))
        #expect(!installation.files.isEmpty)
        let probed = Recorded<String>()
        #expect(FluidAudioASRModelRuntime.isInstalled(model, enumerate: { _ in [] }, fileExists: { path in
            probed.append(path)
            return true
        }))
        #expect(probed.values.allSatisfy { $0.hasPrefix(installation.directory.path + "/") })
        #expect(probed.values.count == installation.files.count)
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func everyRequiredComponentIsNecessary(model: FluidAudioASRModel) {
        let installation = FluidAudioASRModelRuntime.installation(for: model)
        for missing in installation.files {
            let url = installation.directory.appendingPathComponent(missing)
            let probe = missing.hasSuffix(".mlmodelc") ? url.appendingPathComponent("coremldata.bin").path : url.path
            #expect(!FluidAudioASRModelRuntime.isInstalled(model, enumerate: { _ in [] }, fileExists: { $0 != probe }))
        }
    }

    @Test func streamingInstallationCannotUseTheBatchEncoderInstead() {
        let batch = Set(FluidAudioASRModelRuntime.unifiedBatchFiles)
        let root = FluidAudioASRModelRuntime.unifiedDirectory
        let present = Set(batch.map { file in
            let url = root.appendingPathComponent(file)
            return file.hasSuffix(".mlmodelc") ? url.appendingPathComponent("coremldata.bin").path : url.path
        })
        #expect(!FluidAudioASRModelRuntime.unifiedStreamingIsInstalled(enumerate: { _ in [] }, fileExists: { present.contains($0) }))
        #expect(FluidAudioASRModelRuntime.unifiedStreamingIsInstalled(enumerate: { _ in [] }, fileExists: { _ in true }))
        #expect(!FluidAudioASRModelRuntime.unifiedStreamingIsInstalled(enumerate: { _ in [] }, fileExists: { _ in false }))
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func partialWeightsRejectEveryRequiredCompiledModel(model: FluidAudioASRModel) {
        let installation = FluidAudioASRModelRuntime.installation(for: model)
        for file in installation.files where file.hasSuffix(".mlmodelc") {
            let corrupted = installation.directory.appendingPathComponent(file).path
            #expect(!FluidAudioASRModelRuntime.isInstalled(
                model, enumerate: { $0 == corrupted ? ["weights/weight.bin.partial"] : [] }, fileExists: { _ in true }
            ))
        }
    }

    @Test func unifiedStreamingAlsoRejectsPartialWeightsAndUnreadableBundles() {
        #expect(!FluidAudioASRModelRuntime.unifiedStreamingIsInstalled(
            enumerate: { _ in ["weights/weight.bin.partial"] }, fileExists: { _ in true }
        ))
        #expect(!FluidAudioASRModelRuntime.unifiedStreamingIsInstalled(
            enumerate: { _ in nil }, fileExists: { _ in true }
        ))
    }

    @Test func tdtAndLiteRequirementsMatchTheLocalLoaders() {
        for model in [FluidAudioASRModel.parakeetV3, .bark3, .bark3Clean, .phonon2] {
            #expect(Set(FluidAudioASRModelRuntime.installation(for: model).files) == [
                "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"
            ])
        }
        #expect(Set(FluidAudioASRModelRuntime.installation(for: .nemotronTranscribeLite).files) ==
            ModelNames.NemotronTranscribeLite.requiredModels)
    }

    @Test func progressAdapterMapsEveryPhaseAndClampsFractions() {
        let statuses = Recorded<ModelDownloadStatus>()
        let handler = FluidAudioASRModelRuntime.progressHandler { statuses.append($0) }
        handler(DownloadProgress(fractionCompleted: -1, phase: .listing))
        handler(DownloadProgress(fractionCompleted: 0.5, phase: .downloading(completedFiles: 1, totalFiles: 2)))
        handler(DownloadProgress(fractionCompleted: 2, phase: .compiling(modelName: "encoder")))
        #expect(statuses.values == [
            ModelDownloadStatus(fractionCompleted: 0, phase: .preparing),
            ModelDownloadStatus(fractionCompleted: 0.5, phase: .downloading),
            ModelDownloadStatus(fractionCompleted: 1, phase: .compiling)
        ])
    }

    @Test func nativeUnifiedTranscriptionRejectsUnsupportedLanguageBeforeReadingAudio() async {
        await #expect {
            _ = try await FluidAudioModelTranscriber.transcribeUnified(
                url: URL(fileURLWithPath: "/never-opened.m4a"), language: .japanese
            )
        } throws: { error in
            if case .transcriptionLanguageUnsupported = error as? AppError { return true }
            return false
        }
    }

    @Test func resultAssemblyUsesWordsWithoutInventingLanguageOrSpeakers() {
        let transcript = FluidAudioModelTranscriber.transcript(from: ASRResult(
            text: "hello world", confidence: 1, duration: 4, processingTime: 0,
            tokenTimings: [
                TokenTiming(token: "▁hello", tokenId: 1, startTime: 0.2, endTime: 1, confidence: 1),
                TokenTiming(token: "▁world", tokenId: 2, startTime: 2, endTime: 3, confidence: 1)
            ]
        ))
        #expect(transcript.spans.map(\.text) == ["hello", "world"])
        #expect(transcript.spans.map(\.start) == [0.2, 2])
        #expect(transcript.spans.map(\.end) == [1, 3])
        #expect(transcript.language.isEmpty)
        #expect(transcript.speakerTurns == nil)
    }

    @Test func startOnlyResultAssemblyUsesCoreTimingWithoutLanguageOrSpeakers() throws {
        let transcript = try FluidAudioModelTranscriber.transcript(from: [
            FluidAudioStartTimedWord(text: " hello", start: 0.2),
            FluidAudioStartTimedWord(text: "world ", start: 1)
        ], duration: 3)
        #expect(transcript.spans == [
            TranscribedSpan(text: " hello", start: 0.2, end: 1),
            TranscribedSpan(text: "world ", start: 1, end: 2.5)
        ])
        #expect(transcript.language.isEmpty)
        #expect(transcript.speakerTurns == nil)
        #expect(try FluidAudioModelTranscriber.transcript(from: [FluidAudioStartTimedWord](), duration: 0).spans.isEmpty)
        #expect(throws: ChunkTimestampNormalization.Failure.invalidDuration) {
            try FluidAudioModelTranscriber.transcript(from: [FluidAudioStartTimedWord](), duration: .nan)
        }
    }

    @Test func absentTimingUsesTheSharedWholeClipFallback() {
        let transcript = FluidAudioModelTranscriber.transcript(from: ASRResult(
            text: " hello ", confidence: 1, duration: 4, processingTime: 0
        ))
        #expect(transcript.spans.map(\.text) == ["hello"])
        #expect(transcript.spans.first?.start == 0)
        #expect(transcript.spans.first?.end == 4)
    }
}
#endif
