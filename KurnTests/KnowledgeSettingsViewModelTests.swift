import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct KnowledgeSettingsViewModelTests {
    private func plan(_ settings: AppSettings, id: UUID) throws -> KnowledgeBackfillPlan {
        .init(id: UUID(), controls: try #require(settings.knowledgeControls),
            read: .init(policyRevisionKey: "local-v1", sources: [.init(id: id, title: "Example source", fingerprint: "source-v1",
                segments: 1, characters: 20, isCurrent: false, requiresRebuild: false)]), rebuild: false)
    }

    private func operations(_ plan: KnowledgeBackfillPlan) -> KnowledgeSettingsViewModel.SettingsOperations {
        .init(preview: { _, _ in plan }, coverage: { ids in
            .init(scope: "workspace", policyRevisionKey: "local-v1", sources: ids.map { .init(meetingID: $0, fingerprint: "source-v1") },
                report: try KnowledgeMaintenanceLinter.inspect(.init(revision: 0)))
        }, pages: { _ in })
    }

    @Test func publishesOnlyTheRequestedScopeAndClearsThePreviousPresentation() async throws {
        let settings = MeetingFixtures.isolatedSettings(); settings.knowledgeEnabled = true
        let id = UUID(), model = KnowledgeSettingsViewModel()
        let preview = try plan(settings, id: id)
        let operations = operations(preview)
        await model.perform(.preview, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        #expect(model.plan == preview && !model.isBusy)
        await model.perform(.coverage, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        #expect(model.plan == nil && model.coverage?.sources.first?.meetingID == id)
        await model.perform(.preview, meetingIDs: [UUID()], rebuild: false, settings: settings, operations: operations)
        #expect(model.plan == nil && model.error != nil)
    }

    @Test func lateScopeOrInvalidatedResponsesCannotRestoreSourceMetadata() async throws {
        let settings = MeetingFixtures.isolatedSettings(); settings.knowledgeEnabled = true
        let id = UUID(), model = KnowledgeSettingsViewModel()
        let preview = try plan(settings, id: id)
        var operations = operations(preview)
        operations.preview = { _, _ in model.invalidate(); return preview }
        await model.perform(.preview, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        #expect(model.plan == nil && model.error == nil && !model.isBusy)
        operations.preview = { _, _ in
            var controls = try #require(settings.knowledgeControls)
            controls.excludedMeetingIDs = [id]
            try settings.saveKnowledgeControls(controls)
            return preview
        }
        await model.perform(.preview, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        #expect(model.plan == nil && model.error == nil)
    }

    @Test func disabledEmptyAndExcludedRequestsNeverCallTheReader() async throws {
        let settings = MeetingFixtures.isolatedSettings()
        let id = UUID(), model = KnowledgeSettingsViewModel()
        let preview = try plan(settings, id: id)
        var operations = operations(preview)
        operations.preview = { _, _ in Issue.record("Unauthorized read"); return preview }
        await model.perform(.preview, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        settings.knowledgeEnabled = true
        await model.perform(.preview, meetingIDs: [], rebuild: false, settings: settings, operations: operations)
        var controls = try #require(settings.knowledgeControls); controls.includedMeetingIDs = []
        try settings.saveKnowledgeControls(controls)
        await model.perform(.preview, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        #expect(model.error != nil && model.plan == nil)
    }

    @Test func operationFailuresSurfaceWithoutRetainingAnOldPreview() async throws {
        let settings = MeetingFixtures.isolatedSettings(); settings.knowledgeEnabled = true
        let id = UUID(), model = KnowledgeSettingsViewModel()
        var operations = operations(try plan(settings, id: id))
        await model.perform(.preview, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        operations.pages = { _ in throw KnowledgeSettingsError.unavailable }
        await model.perform(.pages, meetingIDs: [id], rebuild: false, settings: settings, operations: operations)
        #expect(model.error != nil && model.plan == nil && !model.isBusy)
    }

    @Test func corpusDeletionNeedsAuthorizationAndReportsOnlyRealFailures() async {
        struct Injected: Error {}
        let model = KnowledgeSettingsViewModel()
        var deletions = 0
        await model.deleteCorpus(authorize: { false }, delete: { deletions += 1 })
        #expect(deletions == 0 && !model.corpusDeleted && model.error == nil)
        await model.deleteCorpus(authorize: { true }, delete: { deletions += 1 })
        #expect(deletions == 1 && model.corpusDeleted && !model.isDeletingCorpus)
        await model.deleteCorpus(authorize: { true }, delete: { throw CancellationError() })
        #expect(!model.corpusDeleted && model.error == nil)
        await model.deleteCorpus(authorize: { true }, delete: { throw Injected() })
        #expect(!model.corpusDeleted && model.error != nil && !model.isDeletingCorpus)
    }

    @Test func aSecondCorpusDeletionWhileOneRunsIsIgnored() async {
        let model = KnowledgeSettingsViewModel()
        var deletions = 0
        await model.deleteCorpus(authorize: { true }, delete: {
            deletions += 1
            await model.deleteCorpus(authorize: { true }, delete: { deletions += 1 })
        })
        #expect(deletions == 1 && model.corpusDeleted)
    }
}
