import Foundation
import KurnCore
import Observation
import Synchronization
import Testing
@testable import Kurn

@MainActor
struct AppSettingsKnowledgeControlsTests {
    @Test func persistsControlsSeparatelyFromWikiAndSummaryProvider() throws {
        let defaults = try #require(UserDefaults(suiteName: "knowledge-controls-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        settings.aiProviderID = AIProvider.openAI.id
        var controls = try #require(settings.knowledgeControls)
        controls.automaticCompilation = true
        controls.excludedMeetingIDs = [UUID()]
        try settings.saveKnowledgeControls(controls)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.knowledgeControls?.excludedMeetingIDs == controls.excludedMeetingIDs)
        #expect(restored.knowledgeControls?.automaticCompilation == true)
        #expect(restored.knowledgeProvider == .appleOnDevice && restored.aiProvider == .openAI)
        #expect(!restored.knowledgeEnabled && !restored.wikiEnabled)
    }

    @Test func corruptedWrongTypeAndFutureControlsRemainUnreadableUntilExplicitReset() throws {
        let settings = MeetingFixtures.isolatedSettings()
        let invalid: [Any] = ["wrong type", Data("{}".utf8), Data("{\"version\":999}".utf8)]
        for object in invalid {
            settings.defaults.set(object, forKey: "settings.knowledgeControls.v1")
            #expect(settings.knowledgeControls == nil && settings.knowledgeProvider == nil)
        }
        settings.knowledgeEnabled = true
        try settings.resetKnowledgeControls()
        #expect(!settings.knowledgeEnabled && settings.knowledgeControls?.automaticCompilation == false)
        #expect(settings.knowledgeProvider == .appleOnDevice)
    }

    @Test func staleDraftsIncludingPreResetDraftsCannotOverwriteCurrentScope() throws {
        let settings = MeetingFixtures.isolatedSettings()
        let original = try #require(settings.knowledgeControls)
        var next = original
        next.includedMeetingIDs = []
        try settings.saveKnowledgeControls(next)
        #expect(throws: KnowledgeControlsError.staleControls) { try settings.saveKnowledgeControls(original) }
        try settings.resetKnowledgeControls()
        #expect(throws: KnowledgeControlsError.staleControls) { try settings.saveKnowledgeControls(original) }
    }

    @Test func editsAreObservableForLiveScopeAndPublicationInvalidation() throws {
        let settings = MeetingFixtures.isolatedSettings()
        let changed = KnowledgeControlsObservation()
        withObservationTracking { _ = settings.knowledgeControls } onChange: { changed.value.withLock { $0 = true } }
        var controls = try #require(settings.knowledgeControls)
        controls.isPaused = true
        try settings.saveKnowledgeControls(controls)
        #expect(changed.value.withLock { $0 })
    }
}

private final class KnowledgeControlsObservation: Sendable { let value = Mutex(false) }
