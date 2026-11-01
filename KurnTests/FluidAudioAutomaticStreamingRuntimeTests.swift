import Foundation
import KurnCore
import Testing
@testable import Kurn

#if canImport(FluidAudio)
import AVFoundation
import FluidAudio

struct FluidAudioAutomaticStreamingRuntimeTests {
    @Test func cachePathsMirrorTheActualLegacyDownloaders() {
        #expect(FluidAudioAutomaticStreamingRuntime.englishDirectory.path.hasSuffix(
            "/FluidAudio/Models/parakeet-eou-streaming/parakeet-eou-streaming/160ms"
        ))
        #expect(FluidAudioAutomaticStreamingRuntime.multilingualDirectory().path.hasSuffix(
            "/FluidAudio/Models/nemotron-multilingual/multilingual/2240ms"
        ))
        #expect(FluidAudioAutomaticStreamingRuntime.multilingualDirectory(chunkMs: 1120).lastPathComponent == "1120ms")
        #expect(Set(FluidAudioAutomaticStreamingRuntime.englishFiles) == [
            "streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"
        ])
        #expect(Set(FluidAudioAutomaticStreamingRuntime.multilingualBaseFiles) == [
            "encoder.mlmodelc", "metadata.json", "tokenizer.json"
        ])
    }

    @Test(arguments: MeetingLanguage.allCases)
    func onlyExplicitEnglishSelectsEOU(language: MeetingLanguage) {
        #expect(FluidAudioAutomaticStreamingRuntime.backend(for: language) == (language == .english ? .english : .multilingual))
    }

    @Test func installationRequiresBothCompleteLegacyModelFamilies() {
        let english = englishPaths
        let multilingual = multilingualPaths()
        let complete = english.union(multilingual)
        #expect(FluidAudioAutomaticStreamingRuntime.installed(enumerate: { _ in [] }, fileExists: { complete.contains($0) }))
        #expect(!FluidAudioAutomaticStreamingRuntime.installed(enumerate: { _ in [] }, fileExists: { english.contains($0) }))
        #expect(!FluidAudioAutomaticStreamingRuntime.installed(enumerate: { _ in [] }, fileExists: { multilingual.contains($0) }))
        for missing in complete where !missing.hasSuffix(".mlmodelc") {
            #expect(!FluidAudioAutomaticStreamingRuntime.installed(enumerate: { _ in [] }, fileExists: {
                $0 != missing && complete.contains($0)
            }))
        }
    }

    @Test func partialWeightsInEitherFamilyRequireExplicitRepair() {
        let complete = englishPaths.union(multilingualPaths())
        for bundle in complete where bundle.hasSuffix(".mlmodelc") {
            #expect(!FluidAudioAutomaticStreamingRuntime.installed(
                enumerate: { $0 == bundle ? ["weights/weight.bin.partial"] : [] }, fileExists: { complete.contains($0) }
            ))
        }
        #expect(!FluidAudioAutomaticStreamingRuntime.installed(enumerate: { _ in nil }, fileExists: { complete.contains($0) }))
    }

    @Test func multilingualAcceptsThePublishedBareOrFusedDecodePaths() {
        for optional in [
            ["decoder.mlmodelc", "joint.mlmodelc"], ["decoder_joint.mlmodelc"],
            ["decoder_joint_noencproj.mlmodelc"], ["decoder_joint_argmax.mlmodelc"]
        ] {
            let present = multilingualPaths(optional)
            #expect(FluidAudioAutomaticStreamingRuntime.multilingualIsInstalled(
                enumerate: { _ in [] }, fileExists: { present.contains($0) }
            ))
        }
        for optional in [[String](), ["decoder.mlmodelc"], ["joint.mlmodelc"],
                         ["decoder_joint.mlmodelc", "joint_noencproj_batched.mlmodelc"]] {
            let present = multilingualPaths(optional)
            #expect(!FluidAudioAutomaticStreamingRuntime.multilingualIsInstalled(
                enumerate: { _ in [] }, fileExists: { present.contains($0) }
            ))
        }
        let speculative = multilingualPaths(["decoder.mlmodelc", "joint.mlmodelc", "joint_noencproj_batched.mlmodelc"])
        #expect(FluidAudioAutomaticStreamingRuntime.multilingualIsInstalled(
            enumerate: { _ in [] }, fileExists: { speculative.contains($0) }
        ))
    }

    @Test func presentOptionalModelsMustAlsoBeCompleteBeforeNativeLoading() {
        let present = multilingualPaths(["decoder.mlmodelc", "joint.mlmodelc", "decoder_joint.mlmodelc"])
        let marker = FluidAudioAutomaticStreamingRuntime.multilingualDirectory()
            .appendingPathComponent("decoder_joint.mlmodelc/coremldata.bin").path
        #expect(!FluidAudioAutomaticStreamingRuntime.multilingualIsInstalled(enumerate: { _ in [] }, fileExists: {
            $0 != marker && present.contains($0)
        }))
    }

    @Test(arguments: [MeetingLanguage.english, .portuguese, .autoDetect, .japanese])
    func loadUsesOnlyTheSelectedLocalFactory(language: MeetingLanguage) async throws {
        let selected = Recorded<FluidAudioAutomaticStreamingRuntime.Backend>()
        let session = AutomaticStreamingSession()
        let loaded = try await FluidAudioAutomaticStreamingRuntime.load(
            language: language, isInstalled: { true }, factory: { backend in
                selected.append(backend)
                return session
            }
        )
        #expect(loaded === session)
        #expect(selected.values == [language == .english ? .english : .multilingual])
    }

    @Test func unsupportedLanguagePrecedesEvenTheInstallationProbe() async {
        await #expect {
            _ = try await FluidAudioAutomaticStreamingRuntime.load(
                language: .russian,
                isInstalled: { Issue.record("Unsupported languages must not probe files"); return true },
                factory: { _ in Issue.record("Unsupported languages must not load models"); throw CancellationError() }
            )
        } throws: { error in
            if case .transcriptionLanguageUnsupported = error as? AppError { return true }
            return false
        }
    }

    @Test func missingModelsNeverReachALoaderOrDownloader() async {
        await #expect {
            _ = try await FluidAudioAutomaticStreamingRuntime.load(
                language: .english, isInstalled: { false },
                factory: { _ in Issue.record("Missing models require explicit repair"); throw CancellationError() }
            )
        } throws: { error in
            if case .modelDownloadRequired = error as? AppError { return true }
            return false
        }
    }

    @Test func localLoadFailuresArePropagatedWithoutRecoveryDownloads() async {
        await #expect(throws: CancellationError.self) {
            _ = try await FluidAudioAutomaticStreamingRuntime.load(
                language: .autoDetect, isInstalled: { true }, factory: { _ in throw CancellationError() }
            )
        }
    }

    private var englishPaths: Set<String> {
        paths(FluidAudioAutomaticStreamingRuntime.englishFiles, in: FluidAudioAutomaticStreamingRuntime.englishDirectory)
    }

    private func multilingualPaths(_ optional: [String] = ["decoder.mlmodelc", "joint.mlmodelc"]) -> Set<String> {
        paths(FluidAudioAutomaticStreamingRuntime.multilingualBaseFiles + optional,
              in: FluidAudioAutomaticStreamingRuntime.multilingualDirectory())
    }

    private func paths(_ files: [String], in directory: URL) -> Set<String> {
        Set(files.flatMap { file in
            let url = directory.appendingPathComponent(file)
            return file.hasSuffix(".mlmodelc") ? [url.path, url.appendingPathComponent("coremldata.bin").path] : [url.path]
        })
    }
}

private actor AutomaticStreamingSession: StreamingAsrManager {
    let displayName = "Local factory session"
    func loadModels() { Issue.record("The factory must return an already loaded session") }
    func appendAudio(_ buffer: AVAudioPCMBuffer) {}
    func processBufferedAudio() {}
    func finish() -> String { "" }
    func reset() {}
    func cleanup() {}
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {}
    func getPartialTranscript() -> String { "" }
}
#endif
