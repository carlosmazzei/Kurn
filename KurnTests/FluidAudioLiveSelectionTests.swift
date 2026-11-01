import KurnCore
import Testing
@testable import Kurn

@MainActor
struct FluidAudioLiveSelectionTests {
    @Test func unifiedNeverProbesInstallationWithoutConsent() async {
        var probes = 0
        let service = LiveTranscriptionService(isUnifiedInstalled: { probes += 1; return false })
        await service.start(language: .english, modelsConsented: false, model: .nemotronUnified)
        #expect(probes == 0)
        #expect(service.isUnavailable)
        #expect(!service.isActive)
        #expect(!service.isLoading)
    }

    @Test func unsupportedUnifiedLanguageNeverProbesOrStartsAModel() async {
        var probes = 0
        let service = LiveTranscriptionService(isUnifiedInstalled: { probes += 1; return false })
        await service.start(language: .japanese, modelsConsented: true, model: .nemotronUnified)
        #expect(probes == 0)
        #expect(service.isUnavailable)
        #expect(!service.isActive)
    }

    @Test(arguments: [MeetingLanguage.english, .portuguese, .autoDetect])
    func missingUnifiedWeightsStayUnavailableWithoutDownloading(language: MeetingLanguage) async {
        var probes = 0
        let service = LiveTranscriptionService(isUnifiedInstalled: { probes += 1; return false })
        await service.start(language: language, modelsConsented: true, model: .nemotronUnified)
        #expect(probes == 1)
        #expect(service.isUnavailable)
        #expect(!service.isActive)
        #expect(!service.isLoading)
        #expect(service.partialText.isEmpty)
        await service.stop()
        #expect(!service.isActive)
    }
}
