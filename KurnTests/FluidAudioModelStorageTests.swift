import Foundation
import KurnCore
import Testing
@testable import Kurn

private struct FluidAudioCellularNetworkPath: NetworkPathSnapshotProviding {
    let snapshot = NetworkPathSnapshot(isExpensive: true, isConstrained: false)
}

extension FluidAudioModelIntegrationTests {
    @Test(arguments: [false, true], [false, true])
    func deletedActiveASRFallsBackOnlyToInstalledAndConsentedV3(
        installed: Bool, consented: Bool
    ) async throws {
        try await withFluidAudioDownloadHarness(installedASR: installed ? [.parakeetV3] : []) { harness in
            harness.settings.fluidAudioBatchASRModelsConsented = consented
            harness.settings.fluidAudioASRModel = .bark3
            harness.settings.fluidAudioASRModelConsents = [FluidAudioASRModel.bark3.rawValue]
            harness.settings.transcriptionEngine = .fluidAudioParakeet
            let entry = try harness.modelEntry(.fluidAudioASR, folders: [FluidAudioASRModel.bark3.folderName])
            harness.controller.deleteModel(entry, settings: harness.settings)
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.settings.transcriptionEngine == (installed && consented ? .fluidAudioParakeet : .appleSpeech))
            #expect(harness.settings.fluidAudioASRModelConsents.isEmpty)
            #expect(harness.settings.fluidAudioBatchASRModelsConsented == consented)
            #expect(harness.settings.selectedFluidAudioASRModelsConsented == consented)
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test func deletingAnotherASRVariantPreservesTheSelectedOneAndItsConsent() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModel = .phonon2
            harness.settings.transcriptionEngine = .fluidAudioParakeet
            harness.settings.fluidAudioASRModelConsents = [FluidAudioASRModel.bark3.rawValue, FluidAudioASRModel.phonon2.rawValue]
            harness.settings.fluidAudioLiveModel = .nemotronUnified
            harness.settings.fluidAudioUnifiedStreamingConsented = true
            harness.settings.liveTranscriptionEnabled = true
            let entry = try harness.modelEntry(.fluidAudioASR, folders: [FluidAudioASRModel.bark3.folderName])
            harness.controller.deleteModel(entry, settings: harness.settings)
            #expect(harness.settings.fluidAudioASRModel == .phonon2)
            #expect(harness.settings.transcriptionEngine == .fluidAudioParakeet)
            #expect(harness.settings.fluidAudioASRModelConsents == [FluidAudioASRModel.phonon2.rawValue])
            #expect(harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(harness.settings.liveTranscriptionEnabled)
        }
    }

    @Test func unifiedDeletionInvalidatesBothBatchAndStreamingChoices() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModel = .nemotronUnified
            harness.settings.transcriptionEngine = .fluidAudioParakeet
            harness.settings.fluidAudioASRModelConsents = [FluidAudioASRModel.nemotronUnified.rawValue]
            harness.settings.fluidAudioLiveModel = .nemotronUnified
            harness.settings.fluidAudioUnifiedStreamingConsented = true
            harness.settings.liveTranscriptionEnabled = true
            let entry = try harness.modelEntry(.fluidAudioASR, folders: [FluidAudioASRModel.nemotronUnified.folderName])
            harness.controller.deleteModel(entry, settings: harness.settings)
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            #expect(harness.settings.fluidAudioASRModelConsents.isEmpty)
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(!harness.settings.liveTranscriptionEnabled)
            #expect(!harness.settings.fluidAudioUnifiedStreamingConsented)
        }
    }

    @Test func deletingLegacyGroupsDoesNotDisableSelectedNewVariants() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModel = .bark3
            harness.settings.transcriptionEngine = .fluidAudioParakeet
            harness.settings.fluidAudioASRModelConsents = [FluidAudioASRModel.bark3.rawValue]
            harness.settings.languageDetectionEngine = .fluidAudioLID
            harness.settings.fluidAudioLiveModel = .nemotronUnified
            harness.settings.fluidAudioUnifiedStreamingConsented = true
            harness.settings.liveTranscriptionEnabled = true
            harness.settings.fluidAudioDiarizationModel = .nemotron3
            harness.settings.fluidAudioNemotronModelsConsented = true
            harness.settings.diarizationEngine = .fluidAudio
            for group in [ModelStore.ModelGroup.liveTranscription, .onDeviceLanguage, .diarization] {
                let entry = try harness.modelEntry(group, folders: ["kurn-tests-missing-\(UUID().uuidString)"])
                harness.controller.deleteModel(entry, settings: harness.settings)
            }
            #expect(harness.settings.liveTranscriptionEnabled)
            #expect(harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(harness.settings.fluidAudioASRModel == .bark3)
            #expect(harness.settings.transcriptionEngine == .fluidAudioParakeet)
            #expect(harness.settings.languageDetectionEngine == .byTranscriber)
            #expect(harness.settings.diarizationEngine == .fluidAudio)
            #expect(harness.settings.fluidAudioNemotronModelsConsented)
            #expect(harness.settings.selectedFluidAudioASRModelsConsented)
            #expect(harness.settings.selectedFluidDiarizationConsented)
            #expect(harness.settings.selectedFluidAudioLiveModelsConsented)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func deletedNemotronDiarizationUsesOnlyInstalledAndConsentedPyannote(
        installed: Bool, consented: Bool
    ) async throws {
        try await withFluidAudioDownloadHarness(installedDiarization: installed ? [.pyannote] : []) { harness in
            harness.settings.fluidAudioDiarizationModel = .nemotron3
            harness.settings.fluidAudioNemotronModelsConsented = true
            harness.settings.fluidAudioDiarizationModelsConsented = consented
            harness.settings.diarizationEngine = .fluidAudio
            let entry = try harness.modelEntry(.nemotronDiarization, folders: [FluidAudioDiarizationModel.nemotron3.folderName])
            harness.controller.deleteModel(entry, settings: harness.settings)
            #expect(harness.settings.fluidAudioDiarizationModel == .pyannote)
            #expect(!harness.settings.fluidAudioNemotronModelsConsented)
            #expect(harness.settings.fluidAudioDiarizationModelsConsented == consented)
            #expect(harness.settings.selectedFluidDiarizationConsented == consented)
            #expect(harness.settings.diarizationEngine == (installed && consented ? .fluidAudio : .heuristic))
        }
    }

    @Test func storageOwnershipUsesCoreFoldersWithoutClaimingOtherGroups() {
        let group = ModelStore.ModelGroup.fluidAudioASR
        #expect(Set(group.fallbackFolderNames) == Set(FluidAudioASRModel.allCases.filter { $0 != .parakeetV3 }.map(\.folderName)))
        #expect(group.listsFoldersSeparately)
        #expect(!ModelStore.ModelGroup.nemotronDiarization.listsFoldersSeparately)
        #expect(ModelStore.ModelGroup.nemotronDiarization.fallbackFolderNames == [FluidAudioDiarizationModel.nemotron3.folderName])
        #expect(ModelStore.ModelGroup.onDeviceLanguage.fallbackFolderNames.contains(FluidAudioASRModel.parakeetV3.folderName))
        for model in FluidAudioASRModel.allCases where model != .parakeetV3 {
            #expect(group.displayName(forFolder: model.folderName).contains(model.displayName))
            #expect(!ModelStore.ModelGroup.onDeviceLanguage.canClaimFolder(model.folderName))
            #expect(!ModelStore.ModelGroup.liveTranscription.canClaimFolder(model.folderName))
        }
        #expect(!group.canClaimFolder(FluidAudioASRModel.parakeetV3.folderName))
        #expect(!group.canClaimFolder(FluidAudioDiarizationModel.nemotron3.folderName))
        #expect(!group.canClaimFolder("unrelated-model"))
        #expect(ModelStore.ModelGroup.nemotronDiarization.canClaimFolder(FluidAudioDiarizationModel.nemotron3.folderName))
        #expect(!ModelStore.ModelGroup.nemotronDiarization.canClaimFolder(FluidAudioASRModel.nemotronUnified.folderName))
        #expect(ModelStore.ModelGroup.onDeviceLanguage.canClaimFolder("historical-v3-repo-name"))
        #expect(ModelVerification.recordID(for: .onDeviceLanguage) == "onDeviceLanguage")
        #expect(ModelVerification.recordID(for: .liveTranscription) == "liveTranscription")
    }

    @Test func newASRFoldersAreListedVerifiedAndDeletedIndependently() throws {
        let fm = FileManager.default
        let group = ModelStore.ModelGroup.fluidAudioASR
        let models: [FluidAudioASRModel] = [.bark3, .bark3Clean, .nemotronUnified]
        let unrelated = "kurn-tests-unclaimed-\(UUID().uuidString)"
        let folders = models.map(\.folderName) + [unrelated]
        for folder in group.fallbackFolderNames {
            try #require(!fm.fileExists(atPath: group.root.appendingPathComponent(folder).path))
        }
        let registryKey = "settings.fluidAudioModelFoldersByGroup"
        let verificationKey = "settings.modelVerificationRecords"
        let previousRegistry = UserDefaults.standard.object(forKey: registryKey)
        let previousVerification = UserDefaults.standard.object(forKey: verificationKey)
        defer {
            for folder in folders { try? fm.removeItem(at: group.root.appendingPathComponent(folder)) }
            UserDefaults.standard.set(previousRegistry, forKey: registryKey)
            UserDefaults.standard.set(previousVerification, forKey: verificationKey)
        }
        let before = ModelStore.snapshot()
        for folder in folders {
            let directory = group.root.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 2_048).write(to: directory.appendingPathComponent("fixture"))
        }
        ModelStore.recordDownload(for: group, before: before)
        var registry = UserDefaults.standard.dictionary(forKey: registryKey) as? [String: [String]] ?? [:]
        #expect(!(registry[group.rawValue] ?? []).contains(unrelated))
        registry[ModelStore.ModelGroup.liveTranscription.rawValue] = [FluidAudioASRModel.nemotronUnified.folderName]
        registry[ModelStore.ModelGroup.onDeviceLanguage.rawValue] = [FluidAudioASRModel.bark3.folderName]
        UserDefaults.standard.set(registry, forKey: registryKey)
        ModelStore.recordVerification(for: .fluidAudioASR(.bark3), group: group)
        ModelStore.recordVerification(for: .fluidAudioUnifiedStreaming, group: group)
        let inventory = ModelStore.installedModels()
        #expect(!inventory.filter { $0.group == .liveTranscription }.flatMap(\.folderNames).contains(FluidAudioASRModel.nemotronUnified.folderName))
        #expect(!inventory.filter { $0.group == .onDeviceLanguage }.flatMap(\.folderNames).contains(FluidAudioASRModel.bark3.folderName))
        let rows = inventory.filter { $0.group == group }
        #expect(rows.count == models.count)
        #expect(rows.allSatisfy { $0.folderNames.count == 1 && $0.size == 2_048 })
        #expect(Set(rows.map(\.id)).count == models.count)
        let bark = try #require(rows.first { $0.folderNames == [FluidAudioASRModel.bark3.folderName] })
        guard case .verified = bark.verificationState else {
            Issue.record("expected per-folder health verification")
            return
        }
        let unified = try #require(rows.first { $0.folderNames == [FluidAudioASRModel.nemotronUnified.folderName] })
        guard case .verified = unified.verificationState else {
            Issue.record("expected shared Unified folder health verification")
            return
        }
        #expect(unified.id == ModelVerification.recordID(for: group, folder: FluidAudioASRModel.nemotronUnified.folderName))
        ModelStore.delete(bark)
        #expect(!fm.fileExists(atPath: group.root.appendingPathComponent(FluidAudioASRModel.bark3.folderName).path))
        #expect(fm.fileExists(atPath: group.root.appendingPathComponent(FluidAudioASRModel.bark3Clean.folderName).path))
        #expect(fm.fileExists(atPath: group.root.appendingPathComponent(FluidAudioASRModel.nemotronUnified.folderName).path))
        #expect(ModelStore.installedModels().filter { $0.group == group }.count == 2)
        #expect(ModelVerification.state(id: bark.id, currentSize: 0) == .unverified)
        ModelStore.delete(unified)
        #expect(ModelStore.installedModels().filter { $0.group == group }.count == 1)
    }

    @Test(arguments: [
        ModelSet.onDeviceASR, .diarization, .liveTranscriptionASR, .vad,
        .whisperCppASR(.small), .sherpaOnnxDiarization
    ])
    func legacySetsFailVariantAdapterDispatchWithoutStartingADownload(_ set: ModelSet) async {
        do {
            try await ModelDownloadConsent.downloadFluidAudioVariant(set) { _ in
                Issue.record("Invalid variant routes must not report download progress")
            }
            Issue.record("Expected invalid variant dispatch to throw")
        } catch AppError.modelDownloadRequired(let modelName) {
            #expect(modelName == TranscriptionEngine.fluidAudioParakeet.displayName)
        } catch {
            Issue.record("Unexpected invalid-route error: \(error)")
        }
    }

    @Test(arguments: [
        ModelSet.fluidAudioASR(.bark3), .fluidAudioASR(.nemotronUnified),
        .fluidAudioDiarization(.nemotron3), .fluidAudioUnifiedStreaming
    ])
    func newDownloadSetsRespectNetworkPolicyBeforeDispatch(_ set: ModelSet) async {
        do {
            try await ModelDownloadConsent.download(
                set, policy: .wifiOnly, network: FluidAudioCellularNetworkPath(), isInstalled: { _ in false }
            )
            Issue.record("expected network policy to stop dispatch")
        } catch AppError.networkPolicyRestricted {
            return
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
