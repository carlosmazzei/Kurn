import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeCompilationQueueTests {
    @MainActor private final class PolicyState {
        var policy = KnowledgeProcessingPolicy.defaultDeny()
        var enabled = true
        var authorization: KnowledgeExtractionAuthorization {
            KnowledgeExtractionAuthorization(featureEnabled: enabled, policies: [policy], sourceClassifications: [.internal], userConsentedToRemote: true)
        }
    }

    private actor Gate {
        var started = false
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async {
            started = true
            guard !released else { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() {
            released = true
            continuations.forEach { $0.resume() }
            continuations = []
        }
    }

    private actor Provider: LLMProvider {
        let provider = AIProvider.appleOnDevice
        let failAt: Int?
        let gateAt: Int?
        let gate: Gate?
        var calls = 0
        init(failAt: Int? = nil, gateAt: Int? = nil, gate: Gate? = nil) {
            self.failAt = failAt
            self.gateAt = gateAt
            self.gate = gate
        }
        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult { SummaryResult(sections: []) }
        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
            calls += 1
            if calls == gateAt { await gate?.wait() }
            if calls == failAt { throw KnowledgeQueueError.workFailed }
            let input = try #require(messages.first?.content.data(using: .utf8))
            let raw = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
            let segments = try #require(raw["segments"] as? [[String: Any]])
            let first = try #require(segments.first)
            let anchor = try #require(first["id"] as? String)
            let quote = try #require(first["text"] as? String)
            let wire: [String: Any] = ["version": 1,
                "entities": [["ref": "e1", "kind": "topic", "name": "Example topic", "aliases": []]],
                "assertions": [["ref": "a1", "subject": "e1", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
                    "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                    "confidence": "low", "attributedToSegmentID": anchor, "evidence": [["segmentIDs": [anchor], "quote": quote]]]],
                "events": [], "examinedSegmentIDs": segments.compactMap { $0["id"] as? String }]
            return String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let meeting: Meeting
        let settings: AppSettings
        let queue: KnowledgeJobQueue
        let coordinator: KnowledgeCompilationCoordinator
        let policy: PolicyState
        let breaker: ProviderCircuitBreaker
    }

    private func fixture(recordings: Int = 1, provider: Provider = Provider(), foreground: Bool = true) throws -> Fixture {
        let schema = KurnModelGraph.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.autosaveEnabled = false
        let meeting = Meeting(title: "Example compilation")
        context.insert(meeting)
        for index in 0..<recordings {
            let recording = Recording(meeting: meeting, fileName: "synthetic-\(index).m4a", duration: 2, transcriptionStatus: .done)
            context.insert(recording)
            let transcript = Transcript(recording: recording, segments: [TranscriptSegment(speakerLabel: "Speaker 1",
                startTime: 0, endTime: 2, text: "Example topic is open (\(index)).")], language: "en")
            context.insert(transcript)
            recording.transcript = transcript
        }
        try context.save()
        let defaults = try #require(UserDefaults(suiteName: "knowledge-compile-tests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.knowledgeEnabled = true
        var controls = try #require(settings.knowledgeControls)
        controls.automaticCompilation = true
        try settings.saveKnowledgeControls(controls)
        settings.aiProviderID = AIProvider.appleOnDevice.id
        let queue = KnowledgeJobQueue(container: container, foreground: foreground)
        let policy = PolicyState()
        let breakerDefaults = try #require(UserDefaults(suiteName: "knowledge-circuit-tests-\(UUID().uuidString)"))
        let breaker = ProviderCircuitBreaker(store: UserDefaultsProviderCircuitStore(defaults: breakerDefaults))
        let coordinator = KnowledgeCompilationCoordinator(queue: queue, settings: settings, authorization: { policy.authorization },
            resolveProvider: { _, _ in provider }, isProviderUsable: { _ in true }, providerCircuitBreaker: breaker)
        return Fixture(container: container, meeting: meeting, settings: settings, queue: queue, coordinator: coordinator,
                       policy: policy, breaker: breaker)
    }

    private func wait(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await gate.started) {
            guard ContinuousClock.now < deadline else { throw KnowledgeQueueError.workFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func meetingContributionsReadOfflineWithoutGeneratingOrAcknowledgingWork() async throws {
        let provider = Provider()
        let f = try fixture(provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        let calls = await provider.calls
        f.settings.aiProviderID = AIProvider.openAI.id // Reading needs no cloud key/provider.
        let result = try await f.coordinator.readMeetingKnowledge(meetingID: f.meeting.id)
        #expect(result.assertionCount == 1)
        #expect(result.passageCount == 1)
        #expect(result.contributions.first?.name == "Example topic")
        #expect(await provider.calls == calls)
        let store = await f.queue.writer()
        #expect(try await store.pendingProjection()?.number == 1)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeJob>()) == 1)
        let wiki = WikiCoordinator(modelContext: f.container.mainContext, appSettings: f.settings, jobQueue: f.queue)
        #expect(await f.coordinator.generateLocalMeetingNotes(f.meeting, wiki: wiki) == .skipped)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeJob>()) == 1)
        f.policy.enabled = false
        await #expect(throws: KnowledgeWikiStoreError.scopeDenied) { try await f.coordinator.readMeetingKnowledge(meetingID: f.meeting.id) }
        f.policy.enabled = true
        f.settings.knowledgeEnabled = false
        await #expect(throws: KnowledgeWikiStoreError.scopeDenied) { try await f.coordinator.readMeetingKnowledge(meetingID: f.meeting.id) }
    }

    @Test func meetingReadDoesNotReuseChangedSourcesOrRevokedContexts() async throws {
        let f = try fixture()
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        #expect(try await f.coordinator.readMeetingKnowledge(meetingID: f.meeting.id).assertionCount == 1)
        let transcript = try #require(f.meeting.recordings.first?.transcript)
        var segments = transcript.segments
        segments[0].text += " Updated."
        transcript.segments = segments
        try f.container.mainContext.save()
        #expect(try await f.coordinator.readMeetingKnowledge(meetingID: f.meeting.id).assertionCount == 0)
        let context = KnowledgeContext(kind: .internalMeeting, name: "Synthetic restricted context", policyID: UUID().uuidString)
        f.container.mainContext.insert(context)
        f.container.mainContext.insert(SourceContextLink(meetingID: f.meeting.id, contextID: context.id))
        try f.container.mainContext.save()
        await #expect(throws: KnowledgeWikiStoreError.scopeDenied) { try await f.coordinator.readMeetingKnowledge(meetingID: f.meeting.id) }
    }

    @Test func canonicalCommitCompletesTheQueueRowAndRetainsProvenance() async throws {
        let provider = Provider()
        let f = try fixture(recordings: 2, provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        let read = ModelContext(f.container)
        let job = try #require(read.fetch(FetchDescriptor<KnowledgeJob>()).first)
        let revision = try #require(read.fetch(FetchDescriptor<KnowledgeRevision>()).first)
        #expect(revision.jobID == job.id)
        #expect(revision.projectionPending)
        #expect(revision.assertionCount == 2)
        #expect(job.stateRaw == "succeeded")
        let bytes = try #require(job.checkpointData)
        let provenance = try #require(JSONStorage.decodeAuthoritative(KnowledgeCommitProvenance.self, from: bytes).decodedValue)
        #expect(provenance.recordings.count == 2)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        #expect(await provider.calls == 2)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeRevision>()) == 1)
    }

    @Test func retryRestoresCompletedRecordingsAfterAProviderFailure() async throws {
        let provider = Provider(failAt: 2)
        let f = try fixture(recordings: 2, provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .failed)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeAssertion>()) == 0)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit) == .completed)
        #expect(await provider.calls == 3)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeAssertion>()) == 2)
    }

    @Test func capturePauseRetainsEarlierRecordingsAndResumesOnlyTheInterruptedOne() async throws {
        let gate = Gate()
        let provider = Provider(gateAt: 2, gate: gate)
        let f = try fixture(recordings: 2, provider: provider)
        let task = Task { await f.coordinator.compile(meetingID: f.meeting.id) }
        try await wait(gate)
        f.queue.setRecording(true)
        await gate.release()
        #expect(await task.value == .deferred)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeRevision>()) == 0)
        let jobs = try await f.queue.writer().queuedJobs(kinds: ["extraction"])
        let bytes = try #require(jobs.first?.envelope?.progress)
        let checkpoint = try #require(JSONStorage.decodeAuthoritative(KnowledgeCompilationCheckpoint.self, from: bytes).decodedValue)
        #expect(checkpoint.recordings.count == 1)
        f.queue.setRecording(false)
        await f.queue.waitUntilIdle()
        #expect(await provider.calls == 3)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeAssertion>()) == 2)
    }

    @Test func policyRevisionChangeDiscardsTheOldWorkAndDoesNotPublishItsReply() async throws {
        let gate = Gate()
        let provider = Provider(gateAt: 1, gate: gate)
        let f = try fixture(provider: provider)
        let task = Task { await f.coordinator.compile(meetingID: f.meeting.id) }
        try await wait(gate)
        f.policy.policy.revision += 1
        await gate.release()
        #expect(await task.value == .deferred)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeAssertion>()) == 0)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        #expect(await provider.calls == 2)
        let jobs = try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeJob>())
        #expect(jobs.count == 2)
        #expect(Set(jobs.map(\.idempotencyKey)).count == 2)
    }

    @Test func changedSourceCannotBePublishedAndDeletionCannotRecreateItsJob() async throws {
        for delete in [false, true] {
            let gate = Gate()
            let provider = Provider(gateAt: 1, gate: gate)
            let f = try fixture(provider: provider)
            let task = Task { await f.coordinator.compile(meetingID: f.meeting.id) }
            try await wait(gate)
            if delete {
                try MeetingLibrary(context: f.container.mainContext).deleteMeeting(f.meeting)
            } else {
                let transcript = try #require(f.meeting.recordings.first?.transcript)
                transcript.segments = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "Corrected source.")]
                try f.container.mainContext.save()
            }
            await gate.release()
            #expect(await task.value == .deferred)
            let read = ModelContext(f.container)
            #expect(try read.fetchCount(FetchDescriptor<KnowledgeAssertion>()) == 0)
            #expect(try read.fetchCount(FetchDescriptor<KnowledgeRevision>()) == 0)
            if delete {
                // Only the deletion tombstone (K2.8) remains; no work job is recreated.
                let tombstone = KnowledgeJobKind.deletion.rawValue
                #expect(try read.fetchCount(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw != tombstone })) == 0)
                #expect(try read.fetchCount(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == tombstone })) == 1)
            }
        }
    }

    @Test func featureRevocationDefersWithoutPublishingAndCloudIsBlockedEvenWithPolicyConsent() async throws {
        let gate = Gate()
        let provider = Provider(gateAt: 1, gate: gate)
        let f = try fixture(provider: provider)
        let task = Task { await f.coordinator.compile(meetingID: f.meeting.id) }
        try await wait(gate)
        f.settings.knowledgeEnabled = false
        await gate.release()
        #expect(await task.value == .deferred)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeRevision>()) == 0)
        f.settings.knowledgeEnabled = true
        f.settings.aiProviderID = AIProvider.openAI.id
        var controls = try #require(f.settings.knowledgeControls)
        controls.providerID = AIProvider.openAI.id
        try f.settings.saveKnowledgeControls(controls)
        f.policy.policy.allowedRemoteProviderIDs = [AIProvider.openAI.id]
        f.policy.policy.maxRemoteClassification = .restricted
        #expect(await f.coordinator.compile(meetingID: UUID(), trigger: .explicit) == .deferred)
        #expect(f.coordinator.lastFailureCode == "cloud_review_required")
        #expect(await provider.calls == 1)
        f.settings.knowledgeEnabled = false
        f.settings.wikiEnabled = true
        #expect(await f.coordinator.compile(meetingID: UUID()) == .deferred)
        #expect(f.coordinator.lastFailureCode == "feature_disabled")
    }

    @Test func explicitCompileForExcludedMeetingReportsTheDeferredReason() async throws {
        let provider = Provider()
        let f = try fixture(provider: provider)
        var controls = try #require(f.settings.knowledgeControls)
        controls.excludedMeetingIDs = [f.meeting.id]
        try f.settings.saveKnowledgeControls(controls)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit) == .deferred)
        #expect(f.coordinator.lastFailureCode == "policy_denied")
        #expect(await provider.calls == 0)
    }

    @Test func explicitCompilePublishesLiveProgressAndAFactCountResult() async throws {
        let gate = Gate()
        let provider = Provider(gateAt: 1, gate: gate)
        let f = try fixture(recordings: 2, provider: provider)
        let task = Task { await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) }
        try await wait(gate)
        // Mid-run the tab sees a real phase, a partial fraction and labels.
        let live = try #require(f.coordinator.progress(for: f.meeting.id))
        #expect(live.phase == .extracting(recording: 1, of: 2))
        #expect(live.fraction > 0 && live.fraction < 1)
        #expect(live.startedAt <= Date())
        #expect(!live.providerLabel.isEmpty)
        await gate.release()
        #expect(await task.value == .completed)
        // Progress leaves with the run; the transient note reports the count.
        #expect(f.coordinator.progress(for: f.meeting.id) == nil)
        let result = try #require(f.coordinator.result(for: f.meeting.id))
        #expect(result.factCount == 2)
        #expect(result.modelEmpty == false)
    }

    @Test func stoppingARunningUpdateDiscardsItWithoutAFailure() async throws {
        let gate = Gate()
        let provider = Provider(gateAt: 1, gate: gate)
        let f = try fixture(provider: provider)
        let task = Task { await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) }
        try await wait(gate)
        f.coordinator.stopUpdate(meetingID: f.meeting.id)
        #expect(f.coordinator.progress(for: f.meeting.id) == nil)
        await gate.release()
        #expect(await task.value == .deferred)
        // Stopped, not failed: no inline failure and nothing published.
        #expect(f.coordinator.lastExplicitFailure == nil)
        #expect(f.coordinator.result(for: f.meeting.id) == nil)
    }

    @Test func forcedCompileRecompilesAnAlreadyCurrentMeeting() async throws {
        let provider = Provider()
        let f = try fixture(provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        #expect(await provider.calls == 1)
        // A plain compile replays the current provenance without calling out.
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        #expect(await provider.calls == 1)
        // The explicit Update forces a fresh extraction pass.
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) == .completed)
        #expect(await provider.calls == 2)
    }

    @Test func secondForcedCompileCoalescesWhileOneRuns() async throws {
        let gate = Gate()
        let provider = Provider(gateAt: 1, gate: gate)
        let f = try fixture(provider: provider)
        let first = Task { await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) }
        try await wait(gate)
        // A second tap joins silently — no second extraction, no failure row.
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) == .deferred)
        await gate.release()
        #expect(await first.value == .completed)
        #expect(await provider.calls == 1)
    }

    @Test func explicitCompileBypassesAndClosesABlockedProvider() async throws {
        let provider = Provider()
        let f = try fixture(provider: provider)
        await f.breaker.recordFailure(providerID: AIProvider.appleOnDevice.id, failure: .configuration)
        // A configuration failure requires an explicit retry: automatic defers.
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .deferred)
        #expect(f.coordinator.lastFailureCode == "provider_blocked")
        #expect(await provider.calls == 0)
        // The explicit update bypasses the open circuit, then records success.
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) == .completed)
        // …and the deferred automatic row retries once the circuit closes.
        #expect(await provider.calls == 2)
        #expect(await f.breaker.record(for: AIProvider.appleOnDevice.id) == nil)
    }

    @Test func explicitCompileFailureRecordsOnTheBreaker() async throws {
        let provider = Provider(failAt: 1)
        let f = try fixture(provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) == .failed)
        let record = await f.breaker.record(for: AIProvider.appleOnDevice.id)
        #expect(record?.consecutiveFailures == 1)
    }

    @Test func progressAndFailureStateClearConsistentlyWhenACompileFails() async throws {
        let provider = Provider(failAt: 1)
        let f = try fixture(provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, force: true) == .failed)
        #expect(f.coordinator.progress(for: f.meeting.id) == nil)
        #expect(f.coordinator.result(for: f.meeting.id) == nil)
        #expect(f.coordinator.lastExplicitFailure?.meetingID == f.meeting.id)
        #expect(f.coordinator.lastExplicitFailure?.code != nil)
    }

    @Test func explicitRebuildGenerationIsIdempotentAndRetiresPreviousMachineAssertions() async throws {
        let provider = Provider()
        let f = try fixture(provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        let generation = UUID()
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, rebuildGeneration: generation) == .completed)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id, trigger: .explicit, rebuildGeneration: generation) == .completed)
        #expect(await provider.calls == 2)
        let rows = try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeAssertion>())
        #expect(rows.filter { $0.retractedAt == nil }.count == 1)
        #expect(rows.filter { $0.retractedAt != nil }.count == 1)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .failed)
        #expect(f.coordinator.lastFailureCode == "knowledge_obsolete_job")
    }

    @Test func futureRecordingCheckpointIsPreservedAndNeverReachesTheProvider() async throws {
        let provider = Provider()
        let f = try fixture(provider: provider, foreground: false)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .deferred)
        let store = await f.queue.writer()
        let jobs = try await store.queuedJobs(kinds: ["extraction"])
        let job = try #require(jobs.first)
        let claimed = try await store.claimJob(id: job.id)
        let handle = try #require(claimed)
        var future = KnowledgeCompilationCheckpoint(workKey: handle.work.key)
        future.version = 999
        let bytes = try KnowledgeStoreRows.authoritativeData(future)
        try await store.storeJobProgress(bytes, handle: handle)
        try await store.finishJob(handle, interrupted: true)
        f.queue.setForeground(true)
        await f.queue.waitUntilIdle()
        #expect(await provider.calls == 0)
        let pending = try await store.queuedJobs(kinds: ["extraction"])
        #expect(pending.first?.envelope?.progress == bytes)
    }
    @Test func realFailuresEmitContentFreeReliabilityEventsWhileDeferralsDoNot() async throws {
        let capture = CompilationReliabilityCapture()
        ReliabilityLog.handler = { capture.record($0) }
        defer { ReliabilityLog.handler = nil }
        let provider = Provider(failAt: 1)
        let f = try fixture(provider: provider)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .failed)
        let event = try #require(capture.events.first { $0.operation == "knowledge_compilation" && $0.outcome == .failed })
        #expect(event.code == "knowledge_work_failed")
        #expect(event.elapsedSeconds != nil)
        #expect(!event.operationID.value.isEmpty)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("Example"))
        f.settings.knowledgeEnabled = false
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .deferred)
        // The circuit breaker records its own provider_circuit failure beside
        // this one; the compile event itself stays single and content-free.
        #expect(capture.events.filter { $0.outcome == .failed && $0.operation == "knowledge_compilation" }.count == 1)
    }

    @Test func oldPipelineIntentIsNotRelabeledAsTheCurrentExtractor() async throws {
        let provider = Provider()
        let f = try fixture(provider: provider, foreground: false)
        let auth = f.policy.authorization
        let store = await f.queue.writer()
        let token = try await store.snapshot(meetingID: f.meeting.id, scope: "workspace", provider: .appleOnDevice, authorization: { auth })
        let current = try KnowledgeQueuedWork.extraction(snapshot: token, provider: .appleOnDevice, model: f.settings.summaryModel(for: .appleOnDevice))
        let identity = try KnowledgeCompilationIdentity(scope: "workspace", meetingID: f.meeting.id,
            transcriptFingerprint: token.transcriptFingerprint, extractorVersion: "knowledge-extractor-v1", generation: current.generation)
        let old = KnowledgeQueuedWork(key: try identity.idempotencyKey(), kind: .extraction, meetingID: current.meetingID,
            pipelineVersion: identity.extractorVersion, provider: current.provider, model: current.model, sourceFingerprint: current.sourceFingerprint,
            force: false, explicitlyRequested: false, priorArticleVersion: nil, generation: current.generation, compilation: current.compilation)
        let row = try await store.enqueue(old, explicitRetry: false, restartCompleted: false)
        f.queue.setForeground(true)
        await f.queue.waitUntilIdle()
        #expect(try await store.jobState(id: row.id) == .cancelled)
        #expect(await provider.calls == 0)
        #expect(await f.coordinator.compile(meetingID: f.meeting.id) == .completed)
        #expect(await provider.calls == 1)
    }

}
}

/// ReliabilityLog invokes a Sendable handler; the serial test reads only
/// through the same lock, so no event/content capture crosses unsafely.
private final class CompilationReliabilityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ReliabilityEvent] = []
    func record(_ event: ReliabilityEvent) { lock.withLock { values.append(event) } }
    var events: [ReliabilityEvent] { lock.withLock { values } }
}
