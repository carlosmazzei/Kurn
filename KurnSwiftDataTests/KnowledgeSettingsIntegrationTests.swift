import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeSettingsIntegrationTests {
    private actor Gate {
        var started = false
        private var released = false
        // Every waiter is kept: two calls parked before `release` must both resume.
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async { started = true; if !released { await withCheckedContinuation { continuations.append($0) } } }
        func release() { released = true; continuations.forEach { $0.resume() }; continuations = [] }
    }

    private actor Provider: LLMProvider {
        let provider: AIProvider
        let gate: Gate?
        var calls = 0
        var narrativeCalls = 0
        init(_ provider: AIProvider = .appleOnDevice, gate: Gate? = nil) { self.provider = provider; self.gate = gate }
        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult { SummaryResult(sections: []) }
        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
            if systemPrompt == KnowledgeNarrativePrompt.systemPrompt {
                narrativeCalls += 1
                return "Example topic is open [c1].\n\nAn uncited aside."
            }
            calls += 1
            if calls == 1 { await gate?.wait() }
            let data = try #require(messages.first?.content.data(using: .utf8))
            let input = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let segments = try #require(input["segments"] as? [[String: Any]])
            let segment = try #require(segments.first)
            let id = try #require(segment["id"] as? String), quote = try #require(segment["text"] as? String)
            let wire: [String: Any] = ["version": 1,
                "entities": [["ref": "e1", "kind": "topic", "name": "Example topic", "aliases": []]],
                "assertions": [["ref": "a1", "subject": "e1", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
                    "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                    "confidence": "low", "attributedToSegmentID": id, "evidence": [["segmentIDs": [id], "quote": quote]]]],
                "events": [], "examinedSegmentIDs": segments.compactMap { $0["id"] as? String }]
            return String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let meeting: Meeting
        let settings: AppSettings
        let queue: KnowledgeJobQueue
        let compiler: KnowledgeCompilationCoordinator
        let management: KnowledgeSettingsCoordinator
        let provider: Provider
        let cloud: Provider
        var ids: Set<UUID> { [meeting.id] }
    }

    private func fixture(gate: Gate? = nil, erase: KnowledgeJobQueue.Erase? = nil) throws -> Fixture {
        let schema = KurnModelGraph.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let meeting = Meeting(title: "Synthetic Knowledge settings")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "synthetic-settings.m4a", duration: 2, transcriptionStatus: .done)
        context.insert(recording)
        let transcript = Transcript(recording: recording,
            segments: [.init(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "Example topic is open.")], language: "en")
        context.insert(transcript); recording.transcript = transcript
        try context.save()
        let defaults = try #require(UserDefaults(suiteName: "knowledge-settings-integration-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        settings.knowledgeEnabled = true
        settings.aiProviderID = AIProvider.openAI.id
        let queue = KnowledgeJobQueue(container: container, eraseJobs: erase ?? { try await $0.eraseJobs(kind: $1, createdBefore: $2) })
        let provider = Provider(gate: gate), cloud = Provider(.openAI)
        let compiler = KnowledgeCompilationCoordinator(queue: queue, settings: settings, resolveProvider: { selected, _ in
            if selected == .openAI { return cloud }
            #expect(selected == .appleOnDevice); return provider
        }, isProviderUsable: { _ in true })
        return Fixture(container: container, meeting: meeting, settings: settings, queue: queue, compiler: compiler,
            management: KnowledgeSettingsCoordinator(compilation: compiler), provider: provider, cloud: cloud)
    }

    private func wait(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await gate.started) {
            guard ContinuousClock.now < deadline else { throw KnowledgeQueueError.workFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func enableAndPreviewNeverBackfillImplicitlyOrChangeTheSummaryProvider() async throws {
        let f = try fixture()
        #expect(await f.compiler.compile(meetingID: f.meeting.id) == .deferred)
        let plan = try await f.management.preview(meetingIDs: f.ids, rebuild: false)
        #expect(plan.pending.count == 1 && plan.read.sources.first?.segments == 1)
        #expect(await f.provider.calls == 0)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeJob>()) == 0)
        #expect(f.settings.aiProvider == .openAI && f.settings.knowledgeProvider == .appleOnDevice)
        f.management.start(plan); await f.management.waitUntilIdle()
        #expect(f.management.progress?.completed == 1 && !f.management.failed)
        #expect(await f.provider.calls == 1)
        #expect(try await f.management.preview(meetingIDs: f.ids, rebuild: false).pending.isEmpty)
    }

    @Test func explicitRebuildRetriesReuseTheirGenerationAndPageRebuildWritesNarratives() async throws {
        let f = try fixture()
        #expect(await f.compiler.compile(meetingID: f.meeting.id, trigger: .explicit) == .completed)
        let plan = try await f.management.preview(meetingIDs: f.ids, rebuild: true)
        f.management.start(plan); await f.management.waitUntilIdle()
        f.management.start(plan); await f.management.waitUntilIdle()
        #expect(await f.provider.calls == 2)
        try await f.management.rebuildPages(meetingIDs: f.ids)
        let narrativeCalls = await f.provider.narrativeCalls
        #expect(await f.provider.calls == 2)
        #expect(narrativeCalls == 1)
        let store = await f.queue.writer()
        let compiler = f.compiler, ids = f.ids
        let read = try await store.browserRead(meetingIDs: ids, authorization: { await compiler.browserReadAuthorization(meetingIDs: ids) })
        let narrative = try #require(read.pages.first?.narrative)
        #expect(narrative.paragraphs.map(\.text) == ["Example topic is open."])
        #expect(narrative.paragraphs.first?.assertionIDs == read.pages.first?.sections.flatMap(\.entries).map(\.fact.id))
        #expect(try await store.pendingProjection() == nil)
        let coverage = try await f.management.coverage(meetingIDs: f.ids)
        #expect(coverage.report.coverage.first?.examinedSegments == 1)
    }

    @Test func aCloudKnowledgeProviderWithoutItsAutomaticGrantWritesNoNarrative() async throws {
        let f = try fixture()
        #expect(await f.compiler.compile(meetingID: f.meeting.id, trigger: .explicit) == .completed)
        var controls = try #require(f.settings.knowledgeControls)
        controls.providerID = AIProvider.openAI.id
        try f.settings.saveKnowledgeControls(controls)
        #expect(f.settings.knowledgeProvider == .openAI && !f.settings.allowsCloud(.openAI, for: .automatic))
        try await f.management.rebuildPages(meetingIDs: f.ids)
        let denied = await f.cloud.narrativeCalls
        #expect(denied == 0)
        // The same provider, once granted, does write it: the denial above is the grant's.
        f.settings.grantCloudConsent(.openAI, for: .onRequest)
        f.settings.grantCloudConsent(.openAI, for: .automatic)
        try await f.management.rebuildPages(meetingIDs: f.ids)
        let granted = await f.cloud.narrativeCalls
        #expect(granted == 1)
    }

    @Test func exclusionsInvalidatePreviewAndEveryReaderBeforeReturningContent() async throws {
        let f = try fixture()
        let plan = try await f.management.preview(meetingIDs: f.ids, rebuild: false)
        var controls = try #require(f.settings.knowledgeControls)
        controls.excludedMeetingIDs = f.ids
        try f.settings.saveKnowledgeControls(controls)
        #expect(f.compiler.browserReadAuthorization(meetingIDs: f.ids).meetingIDs.isEmpty)
        await #expect(throws: (any Error).self) { try await f.compiler.readKnowledgeBrowser(meetingIDs: f.ids) }
        f.management.start(plan); await f.management.waitUntilIdle()
        #expect(f.management.failed && f.management.progress?.completed == 0)
        #expect(await f.provider.calls == 0)
    }

    @Test func changedTranscriptCannotBeCompiledUsingTheOldPreviewExpectation() async throws {
        let f = try fixture()
        let plan = try await f.management.preview(meetingIDs: f.ids, rebuild: false)
        let source = try #require(plan.read.sources.first)
        let transcript = try #require(f.meeting.recordings.first?.transcript)
        transcript.segments = [.init(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "Changed source.")]
        try f.container.mainContext.save()
        let outcome = await f.compiler.compile(meetingID: f.meeting.id, trigger: .explicit,
            expectedSource: .init(fingerprint: source.fingerprint, policyRevisionKey: plan.read.policyRevisionKey))
        #expect(outcome == .failed)
        #expect(await f.provider.calls == 0)
    }

    @Test func pausingRejectsLateCanonicalOutputAndPreservesOfflineReadingAuthorization() async throws {
        let gate = Gate()
        let f = try fixture(gate: gate)
        let plan = try await f.management.preview(meetingIDs: f.ids, rebuild: false)
        f.management.start(plan)
        try await wait(gate)
        var controls = try #require(f.settings.knowledgeControls)
        controls.isPaused = true
        try f.settings.saveKnowledgeControls(controls)
        #expect(f.compiler.browserReadAuthorization(meetingIDs: f.ids).meetingIDs == f.ids)
        await gate.release(); await f.management.waitUntilIdle()
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeRevision>()) == 0)
    }

    @Test func canonicalPauseDoesNotCancelAnActiveMeetingArticle() async throws {
        let f = try fixture()
        let gate = Gate()
        f.queue.register(kind: .meetingArticle) { _ in await gate.wait() }
        let work = try KnowledgeQueuedWork.article(meetingID: f.meeting.id, generator: "synthetic", provider: .appleOnDevice,
            model: "on-device", fingerprint: "synthetic", force: false)
        let operation = Task { try await f.queue.submit(work, explicit: true) }
        try await wait(gate)
        var controls = try #require(f.settings.knowledgeControls)
        controls.isPaused = true
        try f.settings.saveKnowledgeControls(controls)
        await gate.release()
        #expect(try await operation.value == KnowledgeJobQueue.Outcome.completed)
    }

    @Test func scopedRefreshCannotStrandAnUnrelatedCancellationBarrier() async throws {
        let providerGate = Gate(), eraseGate = Gate()
        let f = try fixture(gate: providerGate, erase: { _, _, _ in await eraseGate.wait() })
        let operation = Task { await f.compiler.compile(meetingID: f.meeting.id, trigger: .explicit) }
        try await wait(providerGate)
        f.queue.cancel(kind: .meetingArticle)
        try await wait(eraseGate)
        var controls = try #require(f.settings.knowledgeControls)
        controls.isPaused = true
        try f.settings.saveKnowledgeControls(controls)
        try await Task.sleep(for: .milliseconds(10))
        await providerGate.release(); await eraseGate.release()
        _ = await operation.value
        await f.queue.waitUntilIdle()
        controls = try #require(f.settings.knowledgeControls); controls.isPaused = false
        try f.settings.saveKnowledgeControls(controls)
        #expect(await f.compiler.compile(meetingID: f.meeting.id, trigger: .explicit) == .completed)
    }

    @Test func cancelledSourceIdentityRequiresAnExplicitRebuildAfterRestoration() async throws {
        let gate = Gate()
        let f = try fixture(gate: gate)
        let original = try #require(f.meeting.recordings.first?.transcript).segments
        let operation = Task { await f.compiler.compile(meetingID: f.meeting.id, trigger: .explicit) }
        try await wait(gate)
        let transcript = try #require(f.meeting.recordings.first?.transcript)
        transcript.segments = [.init(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "Changed source.")]
        try f.container.mainContext.save()
        await gate.release()
        #expect(await operation.value == .deferred)
        transcript.segments = original
        try f.container.mainContext.save()
        let normal = try await f.management.preview(meetingIDs: f.ids, rebuild: false)
        #expect(normal.requiresRebuild)
        f.management.start(normal); await f.management.waitUntilIdle()
        #expect(f.management.failed)
        #expect(await f.provider.calls == 1)
        let rebuild = try await f.management.preview(meetingIDs: f.ids, rebuild: true)
        f.management.start(rebuild); await f.management.waitUntilIdle()
        #expect(f.management.progress?.completed == 1)
        #expect(await f.provider.calls == 2)
    }
}
}
