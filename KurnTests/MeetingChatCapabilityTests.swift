import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

/// The run's model capability snapshot (NH07, C03): resolved before any request, recorded with the
/// run, and a model known to lack tools is refused before anything is sent.
@MainActor
struct MeetingChatCapabilityTests {
    private func service(_ defaults: UserDefaults) -> HarnessChatService {
        HarnessChatService(contextWindows: ModelContextWindowStore(defaults: defaults), refreshMetadata: { _, _, _ in .unsupported })
    }

    @Test func aRunRecordsTheSnapshotInItsStepsAndItsBranch() async throws {
        let suite = "MeetingChatCapabilityTests.recorded.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Monday.")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: service(defaults))
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "gpt-5.4")
        await vm.waitUntilSettled()
        #expect(vm.error == nil)

        let session = try #require(vm.pastSessions().first)
        let resolution = try #require(session.turns.last?.steps?.compactMap(\.contextResolution).first)
        let capabilities = try #require(resolution.capabilities)
        #expect(capabilities.modelID == "gpt-5.4" && capabilities.source == .catalog)
        #expect(capabilities.tools == .supported && capabilities.reasoning == .supported)
        // The effort the OpenAI adapter sends for this model is the one recorded.
        #expect(capabilities.reasoningEffort == OpenAIProvider.agentReasoningEffort(provider: .openAI, model: "gpt-5.4"))
        #expect(capabilities.reasoningEffort == "low")

        let snapshot = try await SwiftDataAgentSessionStore(context: context).load(sessionID: session.id.uuidString)
        let branch = try #require(AgentRunBranch.all(in: snapshot.entries).last)
        #expect(branch.capabilities == capabilities)
    }

    @Test func aModelWithoutToolsIsRefusedBeforeAnyRequest() async throws {
        let suite = "MeetingChatCapabilityTests.refused.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Never sent.")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: service(defaults))
        vm.configure(meeting: meeting, modelContext: context)
        vm.send(question: "When?", provider: .openAI, model: "o1-mini")
        await vm.waitUntilSettled()
        guard case .apiError(_, let message)? = vm.error else {
            Issue.record("Expected the tools refusal")
            return
        }
        #expect(message == NSLocalizedString("chat.model.tools_unsupported", comment: ""))
        #expect(await model.requests.isEmpty)
    }

    @Test func providerFactsQualifyAnAliasAndExpireWithTheirMetadata() throws {
        let suite = "MeetingChatCapabilityTests.reported.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let windows = ModelContextWindowStore(defaults: defaults, now: { now })
        windows.recordCapabilities(AgentReportedCapabilities(canonicalModelID: "gemini-2.5-flash", fetchedAt: now),
                                   provider: .google, model: "gemini-alias")
        // A later report adds a fact without forgetting the alias.
        windows.recordCapabilities(AgentReportedCapabilities(reasoning: false, fetchedAt: now), provider: .google, model: "gemini-alias")
        let value = windows.capabilities(for: .google, model: "gemini-alias", api: "gemini", reasoningEffort: nil)
        #expect(value.canonicalModelID == "gemini-2.5-flash" && value.tools == .supported)
        #expect(value.reasoning == .unsupported && value.source == .api)
        // An empty report is not stored, and another endpoint's model knows nothing.
        windows.recordCapabilities(AgentReportedCapabilities(fetchedAt: now), provider: .google, model: "other")
        #expect(windows.reportedCapabilities(for: .google, model: "other") == nil)

        let later = ModelContextWindowStore(defaults: defaults, now: { now.addingTimeInterval(2 * ModelContextWindows.metadataLifetime) })
        let expired = later.capabilities(for: .google, model: "gemini-alias", api: "gemini", reasoningEffort: nil)
        #expect(expired.canonicalModelID == nil && expired.tools == .unknown)
    }

    @Test func capabilityLinesNameEveryFact() {
        let value = AgentModelCapabilities(api: "openAIResponses", modelID: "alias", canonicalModelID: "gpt-5.4",
                                           tools: .supported, reasoning: .unknown, reasoningEffort: "low",
                                           imageInput: .unsupported, promptCache: .automatic, source: .catalog)
        #expect(ChatContextPresentation.capabilityLines(value) { $0 } == [
            "chat.capability.canonical", "chat.capability.tools", "chat.capability.reasoning", "chat.capability.effort",
            "chat.capability.images", "chat.capability.cache"
        ])
        let localized = ChatContextPresentation.capabilityLines(value) { key in
            ["chat.capability.tools": "Tools: %@", "chat.capability.support.supported": "yes"][key] ?? key
        }
        #expect(localized.contains("Tools: yes"))
        let plain = AgentModelCapabilities(api: "gemini", modelID: "m")
        #expect(ChatContextPresentation.capabilityLines(plain) { $0 }.count == 4)
    }
}
