import KurnCore
import Testing
@testable import Kurn

struct TranscriptionPresetTests {
    @Test func everyPresetRoundTrips() {
        for preset in TranscriptionPreset.allCases {
            #expect(TranscriptionPreset.matching(preset.choice(for: .english), language: .english) == preset)
            #expect(TranscriptionPreset.matching(preset.choice(for: .portuguese), language: .portuguese) == preset)
        }
    }

    @Test func onDevicePicksASRModelByLanguage() {
        #expect(TranscriptionPreset.bestOnDevice.choice(for: .portuguese).asrModel == .nemotronUnified)
        #expect(TranscriptionPreset.bestOnDevice.choice(for: .english).asrModel == .parakeetV3)
    }

    @Test func customChoiceMatchesNothing() {
        var custom = TranscriptionPreset.basic.choice(for: .english)
        custom.vad = .fluidAudio
        #expect(TranscriptionPreset.matching(custom, language: .english) == nil)
    }

    @Test func nextUnmetStepFollowsConsentOrder() {
        // Nothing applied yet: a cloud preset starts at its provider.
        let target = TranscriptionPreset.fastCloud.choice(for: .english)
        // basic already shares fastCloud's VAD — start from a different one
        // so the .vad step exists at the end of the chain.
        var current = TranscriptionPreset.basic.choice(for: .english)
        current.vad = .fluidAudio
        #expect(TranscriptionPreset.nextUnmetStep(target: target, current: current) == .cloudProvider)

        // Each gated field unlocks the next, in the order the view drives
        // them: provider → diarization model → engine → diarization → vad
        // (fastCloud pins no ASR model, so that step is skipped).
        current.cloudProviderID = target.cloudProviderID
        #expect(TranscriptionPreset.nextUnmetStep(target: target, current: current) == .diarizationModel)
        current.diarizationModel = target.diarizationModel
        #expect(TranscriptionPreset.nextUnmetStep(target: target, current: current) == .engine)
        current.engine = target.engine
        #expect(TranscriptionPreset.nextUnmetStep(target: target, current: current) == .diarization)
        current.diarization = target.diarization
        #expect(TranscriptionPreset.nextUnmetStep(target: target, current: current) == .vad)
        current.vad = target.vad
        // Cloud model and preprocessing are ungated leftovers — `nil` means
        // every gated field already matches.
        #expect(TranscriptionPreset.nextUnmetStep(target: target, current: current) == nil)
    }

    @Test func nextUnmetStepReportsASRModelBeforeDiarizationModel() {
        let target = TranscriptionPreset.bestOnDevice.choice(for: .english)
        let current = TranscriptionPreset.basic.choice(for: .english)
        #expect(TranscriptionPreset.nextUnmetStep(target: target, current: current) == .asrModel)
    }

    @Test func cloudModelMatchesCaseInsensitively() {
        var choice = TranscriptionPreset.fastCloud.choice(for: .english)
        choice.cloudModel = " Whisper-Large-V3-Turbo "
        #expect(TranscriptionPreset.matching(choice, language: .english) == .fastCloud)
    }
}
