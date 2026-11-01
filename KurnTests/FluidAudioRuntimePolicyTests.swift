import Foundation
import KurnCore
import Testing
@testable import Kurn

struct FluidAudioRuntimePolicyTests {
    private let root = URL(fileURLWithPath: "/models")

    @Test func backendChoicePreservesDefaultAndRoutesOnlyTheSelectedFamily() {
        #expect(FluidAudioRuntimePolicy.backend(for: .parakeetV3) == .parakeetV3)
        #expect(FluidAudioRuntimePolicy.backend(for: .bark3) == .tdt)
        #expect(FluidAudioRuntimePolicy.backend(for: .bark3Clean) == .tdt)
        #expect(FluidAudioRuntimePolicy.backend(for: .phonon2) == .tdt)
        #expect(FluidAudioRuntimePolicy.backend(for: .nemotronUnified) == .unified)
        #expect(FluidAudioRuntimePolicy.backend(for: .nemotronTranscribeLite) == .transcribeLite)
    }

    @Test func autoDetectUsesAutoRatherThanAnInventedLanguage() {
        #expect(FluidAudioRuntimePolicy.unifiedLanguageCode(for: .autoDetect) == "auto")
    }

    @Test func pinnedLanguageUsesItsCode() {
        #expect(FluidAudioRuntimePolicy.unifiedLanguageCode(for: .portuguese) == "pt")
        #expect(FluidAudioRuntimePolicy.unifiedLanguageCode(for: .english) == "en")
    }

    @Test func aCompiledBundleDirectoryAloneIsNotInstalled() {
        let present: Set<String> = ["/models/encoder.mlmodelc", "/models/vocab.json"]
        let missing = FluidAudioRuntimePolicy.missingFiles(
            ["encoder.mlmodelc", "vocab.json"], in: root, fileExists: { present.contains($0) }
        )
        #expect(missing == ["encoder.mlmodelc"])
    }

    @Test func nestedBundlesAndAssetsAreCheckedAtTheirExactPaths() {
        let present: Set<String> = [
            "/models/coreml/encoder.mlmodelc/coremldata.bin", "/models/assets/vocab.json"
        ]
        let missing = FluidAudioRuntimePolicy.missingFiles(
            ["coreml/encoder.mlmodelc", "assets/vocab.json"], in: root,
            enumerate: { _ in [] }, fileExists: { present.contains($0) }
        )
        #expect(missing.isEmpty)
    }

    @Test func partialDownloadsInsideCompiledModelsRequireExplicitRepair() {
        let enumerated = Recorded<String>()
        let missing = FluidAudioRuntimePolicy.missingFiles(
            ["encoder.mlmodelc", "vocab.json"], in: root,
            enumerate: { path in
                enumerated.append(path)
                return ["coremldata.bin", "weights/weight.bin.partial"]
            }, fileExists: { _ in true }
        )
        #expect(missing == ["encoder.mlmodelc"])
        #expect(enumerated.values == ["/models/encoder.mlmodelc"])
    }

    @Test func unreadableModelContentsFailClosedEvenWhenTheMarkerExists() {
        #expect(FluidAudioRuntimePolicy.missingFiles(
            ["encoder.mlmodelc"], in: root, enumerate: { _ in nil }, fileExists: { _ in true }
        ) == ["encoder.mlmodelc"])
    }

    @Test func completedBundlesPassAndOrdinaryAssetsAreNeverEnumerated() {
        let missing = FluidAudioRuntimePolicy.missingFiles(
            ["encoder.mlmodelc", "vocab.json"], in: root,
            enumerate: { path in
                #expect(path == "/models/encoder.mlmodelc")
                return ["coremldata.bin", "weights/weight.bin", "weights/partial_metadata.bin"]
            }, fileExists: { _ in true }
        )
        #expect(missing.isEmpty)
    }

    @Test func aMissingCompiledMarkerNeverEnumeratesAnIncompleteBundle() {
        #expect(FluidAudioRuntimePolicy.missingFiles(
            ["encoder.mlmodelc"], in: root,
            enumerate: { _ in Issue.record("Missing bundles must not be enumerated"); return [] },
            fileExists: { _ in false }
        ) == ["encoder.mlmodelc"])
    }

    @Test func theDefaultEnumeratorFailsClosedForAnAbsentDirectory() {
        #expect(FluidAudioRuntimePolicy.modelContents(at: root.appendingPathComponent(UUID().uuidString).path) == nil)
    }

    @Test func missingFilesAreSortedAndMetadataIsRequired() {
        let missing = FluidAudioRuntimePolicy.missingFiles(
            ["z.json", "metadata.json", "a.mlmodelc"], in: root, fileExists: { _ in false }
        )
        #expect(missing == ["a.mlmodelc", "metadata.json", "z.json"])
    }

    @Test func noRequiredFilesMeansNoProbes() {
        let missing = FluidAudioRuntimePolicy.missingFiles([String](), in: root, fileExists: { _ in
            Issue.record("No files should have been probed")
            return false
        })
        #expect(missing.isEmpty)
    }

    @Test func theDefaultFilesystemProbeDoesNotTreatMissingFilesAsInstalled() {
        let missing = FluidAudioRuntimePolicy.missingFiles(["vocab.json"], in: root.appendingPathComponent(UUID().uuidString))
        #expect(missing == ["vocab.json"])
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func supportedInstalledModelsPass(model: FluidAudioASRModel) throws {
        try FluidAudioRuntimePolicy.validate(model: model, language: .english, isInstalled: true)
    }

    @Test func unsupportedLanguageIsRejectedBeforeEvenProbingInstallation() {
        var probed = false
        func installed() -> Bool {
            probed = true
            return false
        }
        #expect {
            try FluidAudioRuntimePolicy.validate(model: .bark3, language: .japanese, isInstalled: installed())
        } throws: { error in
            if case .transcriptionLanguageUnsupported(.japanese, .fluidAudioParakeet) = error as? AppError { return true }
            return false
        }
        #expect(!probed)
    }

    @Test(arguments: [FluidAudioASRModel.bark3, .bark3Clean, .phonon2, .nemotronTranscribeLite])
    func englishOnlyModelsRejectAutoDetect(model: FluidAudioASRModel) {
        #expect {
            try FluidAudioRuntimePolicy.validate(model: model, language: .autoDetect, isInstalled: true)
        } throws: { error in
            if case .transcriptionLanguageUnsupported = error as? AppError { return true }
            return false
        }
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func aMissingModelRequiresAnExplicitDownload(model: FluidAudioASRModel) {
        #expect {
            try FluidAudioRuntimePolicy.validate(model: model, language: .english, isInstalled: false)
        } throws: { error in
            if case .modelDownloadRequired(let name) = error as? AppError { return name == model.displayName }
            return false
        }
    }
}
