//
//  ModelVerificationTests.swift
//  KurnTests
//
//  H7 PR 16: pins the pure state logic behind "verified installation" as its
//  own fact, separate from consent and from `ModelStore.isInstalled`'s
//  bytes-on-disk check — an unrecorded model reads as unknown, not bad; a
//  size drift against the last successful verification reads as corrupt,
//  never as merely "needs re-checking." Each test gets its own randomly
//  named `UserDefaults` suite, so this suite neither touches the real
//  `.standard` domain nor needs serializing against itself.
//

import Foundation
import Testing
@testable import Kurn

struct ModelVerificationTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ModelVerificationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }

    @Test("a model with no record is unverified")
    func noRecordIsUnverified() {
        let defaults = makeDefaults()
        let state = ModelVerification.state(id: "some.model", currentSize: 1_000, defaults: defaults)
        #expect(state == .unverified)
    }

    @Test("a model whose size matches the recorded verification is verified")
    func matchingSizeIsVerified() {
        let defaults = makeDefaults()
        let now = Date()
        ModelVerification.record(id: "some.model", size: 1_000, at: now, defaults: defaults)

        let state = ModelVerification.state(id: "some.model", currentSize: 1_000, defaults: defaults)
        guard case let .verified(date) = state else {
            Issue.record("expected .verified, got \(state)")
            return
        }
        #expect(date == now)
    }

    @Test("a model whose size no longer matches the recorded verification is corrupt")
    func sizeDriftIsCorrupt() {
        let defaults = makeDefaults()
        ModelVerification.record(id: "some.model", size: 1_000, defaults: defaults)

        let state = ModelVerification.state(id: "some.model", currentSize: 999, defaults: defaults)
        guard case .corrupt = state else {
            Issue.record("expected .corrupt, got \(state)")
            return
        }
    }

    @Test("clearing a record reverts the model to unverified")
    func clearRevertsToUnverified() {
        let defaults = makeDefaults()
        ModelVerification.record(id: "some.model", size: 1_000, defaults: defaults)
        ModelVerification.clear(id: "some.model", defaults: defaults)

        let state = ModelVerification.state(id: "some.model", currentSize: 1_000, defaults: defaults)
        #expect(state == .unverified)
    }

    @Test("clearing one model's record leaves another's untouched")
    func clearIsScopedToOneID() {
        let defaults = makeDefaults()
        ModelVerification.record(id: "model.a", size: 1_000, defaults: defaults)
        ModelVerification.record(id: "model.b", size: 2_000, defaults: defaults)

        ModelVerification.clear(id: "model.a", defaults: defaults)

        #expect(ModelVerification.state(id: "model.a", currentSize: 1_000, defaults: defaults) == .unverified)
        guard case .verified = ModelVerification.state(id: "model.b", currentSize: 2_000, defaults: defaults) else {
            Issue.record("expected model.b to remain verified")
            return
        }
    }

    @Test("recordID folds in the folder only for groups that list folders separately")
    func recordIDFoldsInFolderOnlyWhenSeparatelyListed() {
        #expect(ModelVerification.recordID(for: .whisperCpp, folder: "ggml-small-q5_1") == "whisperCpp.ggml-small-q5_1")
        #expect(ModelVerification.recordID(for: .whisperCpp) == "whisperCpp")
        // `.sherpaOnnxDiarization` doesn't list folders separately, so a
        // folder argument is ignored rather than producing a mismatched id.
        #expect(ModelVerification.recordID(for: .sherpaOnnxDiarization, folder: "segmentation") == "sherpaOnnxDiarization")
        #expect(ModelVerification.recordID(for: .diarization) == "diarization")
    }

    @Test("only the groups with their own downloader/probe are self-verifying")
    func onlyDirectDownloadersAreSelfVerifying() {
        #expect(ModelStore.ModelGroup.whisperCpp.isSelfVerifying)
        #expect(ModelStore.ModelGroup.sherpaOnnxDiarization.isSelfVerifying)
        #expect(!ModelStore.ModelGroup.liveTranscription.isSelfVerifying)
        #expect(!ModelStore.ModelGroup.onDeviceLanguage.isSelfVerifying)
        #expect(!ModelStore.ModelGroup.diarization.isSelfVerifying)
        #expect(!ModelStore.ModelGroup.vad.isSelfVerifying)
    }
}
