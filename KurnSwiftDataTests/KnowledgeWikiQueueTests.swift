import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeWikiQueueTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(KurnModelGraph.currentModels)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func makeSettings() throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "knowledge-wiki-tests-\(UUID().uuidString)"))
        return AppSettings(defaults: defaults)
    }

    private struct CircuitStore: ProviderCircuitStateStoring {
        func load() -> [String: ProviderCircuitRecord] { [:] }
        func save(_ records: [String: ProviderCircuitRecord]) {}
    }

    private func freshCircuit() -> ProviderCircuitBreaker { ProviderCircuitBreaker(store: CircuitStore()) }

    private func transcribed(_ title: String, in context: ModelContext) throws -> Meeting {
        let meeting = Meeting(title: title)
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "\(UUID().uuidString).m4a", duration: 60, transcriptionStatus: .done)
        context.insert(recording)
        let transcript = Transcript(recording: recording,
            segments: [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 4, text: "Synthetic planning statement")], language: "en")
        context.insert(transcript)
        recording.transcript = transcript
        try context.save()
        return meeting
    }

    private actor ImmediateProvider: LLMProvider {
        let provider = AIProvider.openAI
        var callCount = 0
        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
            callCount += 1
            return SummaryResult(sections: [SummarySection(title: "Notes", body: "Synthetic result")])
        }
        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String { "" }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        var started = false
        func wait() async {
            started = true
            guard !open else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            open = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct DelayedProvider: LLMProvider {
        let provider = AIProvider.openAI
        let gate: Gate
        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult {
            await gate.wait() // Deliberately ignores cancellation until released.
            return SummaryResult(sections: [SummarySection(title: "Notes", body: "Synthetic result")])
        }
        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String { "" }
    }

    private func wait(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await gate.started) {
            guard ContinuousClock.now < deadline else { throw KnowledgeQueueError.workFailed }
            await Task.yield()
        }
    }

    @Test func recordingPauseRejectsALateProviderResultAndDoesNotReplayThePaidCall() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let settings = try makeSettings()
        settings.wikiEnabled = true
        settings.aiProviderID = AIProvider.openAI.id
        let gate = Gate()
        let llm = DelayedProvider(gate: gate)
        let queue = KnowledgeJobQueue(container: container)
        let wiki = WikiCoordinator(modelContext: context, appSettings: settings, providerCircuitBreaker: freshCircuit(),
            wikiService: WikiService(summaryService: SummaryService(resolveProvider: { _, _ in llm })), isProviderUsable: { _ in true }, jobQueue: queue)
        let meeting = try transcribed("Example meeting", in: context)
        let task = Task { await wiki.generate(meeting) }
        try await wait(gate)
        queue.setRecording(true)
        await gate.release()
        let outcome = await task.value
        #expect(outcome == .skipped)
        #expect(meeting.wikiArticle == nil)
        queue.setRecording(false)
        await queue.waitUntilIdle()
        let pending = try await queue.writer().queuedJobs(kinds: ["meetingArticle"])
        #expect(pending.first?.code == "explicit_retry_required")
        #expect(meeting.wikiArticle == nil)
    }

    @Test func deletingAMeetingPurgesItsJobsAndALateResponseCannotRecreateThem() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let settings = try makeSettings()
        settings.wikiEnabled = true
        settings.aiProviderID = AIProvider.openAI.id
        let gate = Gate()
        let llm = DelayedProvider(gate: gate)
        let queue = KnowledgeJobQueue(container: container)
        let wiki = WikiCoordinator(modelContext: context, appSettings: settings, providerCircuitBreaker: freshCircuit(),
            wikiService: WikiService(summaryService: SummaryService(resolveProvider: { _, _ in llm })), isProviderUsable: { _ in true }, jobQueue: queue)
        let meeting = try transcribed("Example deletion", in: context)
        let task = Task { await wiki.generate(meeting) }
        try await wait(gate)
        let library = MeetingLibrary(context: context)
        try library.deleteMeeting(meeting)
        await gate.release()
        _ = await task.value
        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<KnowledgeJob>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<WikiArticle>()) == 0)
        #expect(try read.fetchCount(FetchDescriptor<Meeting>()) == 0)
    }

    @Test func clearWikiErasesCompletedJobProgressAndAllowsAFreshGeneration() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let settings = try makeSettings()
        settings.wikiEnabled = true
        settings.aiProviderID = AIProvider.openAI.id
        let llm = ImmediateProvider()
        let queue = KnowledgeJobQueue(container: container)
        let wiki = WikiCoordinator(modelContext: context, appSettings: settings, providerCircuitBreaker: freshCircuit(),
            wikiService: WikiService(summaryService: SummaryService(resolveProvider: { _, _ in llm })), isProviderUsable: { _ in true }, jobQueue: queue)
        let meeting = try transcribed("Example clear", in: context)
        #expect(await wiki.generate(meeting) == .generated)
        wiki.clearWiki()
        // A new request is allowed, but the asynchronous erase barrier must
        // finish before its fresh generation can run.
        _ = await wiki.generate(meeting, trigger: .explicit)
        await queue.waitUntilIdle()
        #expect(meeting.wikiArticle != nil)
        let read = ModelContext(container)
        #expect(try read.fetchCount(FetchDescriptor<KnowledgeJob>()) == 1)
    }
    @Test func recoveringAForcedRemoteRebuildDoesNotMistakeTheOldArticleForNewOutput() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let settings = try makeSettings()
        settings.wikiEnabled = true
        settings.aiProviderID = AIProvider.openAI.id
        let llm = ImmediateProvider()
        let queue = KnowledgeJobQueue(container: container)
        let wiki = WikiCoordinator(modelContext: context, appSettings: settings, providerCircuitBreaker: freshCircuit(),
            wikiService: WikiService(summaryService: SummaryService(resolveProvider: { _, _ in llm })), isProviderUsable: { _ in true }, jobQueue: queue)
        let meeting = try transcribed("Example rebuild recovery", in: context)
        #expect(await wiki.generate(meeting) == .generated)
        meeting.wikiArticle?.updatedAt = Date(timeIntervalSince1970: 4_000_000_000)
        try context.save()
        queue.setForeground(false)
        #expect(await wiki.generate(meeting, force: true) == .skipped)
        let store = await queue.writer()
        let records = try await store.queuedJobs(kinds: ["meetingArticle"])
        let record = try #require(records.first)
        let claimed = try await store.claimJob(id: record.id)
        let handle = try #require(claimed)
        try await store.markJobStarted(handle)
        // Simulate a new worker/process observing a remote call that might
        // have started. The old matching article does not satisfy Rebuild.
        queue.setForeground(true)
        await queue.waitUntilIdle()
        let pending = try await store.queuedJobs(kinds: ["meetingArticle"])
        #expect(pending.first?.code == "explicit_retry_required")
        #expect((await llm.callCount) == 1)
    }

}
}
