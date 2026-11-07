import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessTests {
    private func ask(_ vm: MeetingChatViewModel, _ question: String = "Create minutes") {
        vm.send(question: question, transcriptText: nil, candidates: [], provider: .openAI, model: "gpt-4o")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func harnessProducesStepsArtifactsUsageAndRestoresForRevision() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let create = try chatAgentCall("create_document", arguments: .object(["title": .string("Minutes"), "markdown": .string("# Decisions")]))
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources"), create], usage: AgentUsage(inputTokens: 10, outputTokens: 2)),
            AgentTurnResponse(text: "Created the minutes.", usage: AgentUsage(inputTokens: 20, outputTokens: 5))
        ])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model }, harnessService: HarnessChatService(isWikiEnabled: { false }))
        vm.configure(meeting: meeting, modelContext: context)
        vm.updateScope(ChatSourceScope(kind: .library, selectedIDs: [UUID()], parts: [.transcript, .wiki]))
        #expect(vm.scope.kind == .meetings)
        #expect(vm.scope.selectedIDs == [meeting.id])
        var editor = vm.scopeEditor
        let changed = editor.setSelection(kind: .tags, selectedIDs: [UUID()])
        #expect(!changed)
        ask(vm)
        await waitUntil { !vm.isResponding }
        #expect(vm.error == nil)
        #expect(vm.turns.map(\.role) == [.user, .assistant])
        #expect(vm.turns.last?.text == "Created the minutes.")
        #expect(vm.turns.last?.usage == TokenUsage(promptTokens: 30, completionTokens: 7))
        #expect((vm.turns.last?.costUSD ?? 0) > 0)
        #expect(vm.turns.last?.elapsedSeconds != nil)
        let steps = try #require(vm.turns.last?.steps)
        #expect(steps.filter { $0.kind == .tool }.map(\.toolName) == ["list_sources", "create_document"])
        #expect(steps.filter { $0.kind == .tool }.allSatisfy { $0.status == .finished })
        #expect(steps.last?.stopReason == .completed)
        #expect(steps.first { $0.toolName == "create_document" }?.arguments == .object(["title": .string("Minutes"), "markdown": .string("# Decisions")]))
        let artifact = try #require(vm.artifacts.first)
        #expect(artifact.title == "Minutes")
        #expect(artifact.version == 1)
        let session = try #require(vm.pastSessions().first)
        #expect(session.id == vm.currentSessionID)
        #expect(session.turns.last?.steps == steps)
        #expect(try session.harnessSnapshot().artifacts == [artifact])
        let requests = await model.requests
        #expect(!requests[0].tools.contains { $0.name == "read_wiki" })
        #expect(requests[0].systemPrompt.contains("SAME LANGUAGE as the question"))
        #expect(requests[1].messages.contains { if case .toolResult(_, "create_document", _, false) = $0 { return true }; return false })

        let revision = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("append_to_document", arguments: .object([
                "document_id": .string(artifact.id.uuidString), "markdown": .string("## Follow-up")
            ]))]), AgentTurnResponse(text: "Updated.")
        ])
        let restored = MeetingChatViewModel(agentModelFactory: { _, _ in revision })
        restored.configure(meeting: meeting, modelContext: context)
        restored.load(session: session)
        #expect(restored.artifacts == [artifact])
        #expect(restored.turns.last?.steps == steps)
        #expect(restored.scope == vm.scope)
        ask(restored, "Append follow-up")
        await waitUntil { !restored.isResponding }
        #expect(restored.error == nil)
        #expect(restored.artifacts.first?.version == 2)
        #expect(restored.artifacts.first?.markdown == "# Decisions\n\n## Follow-up")
        let revisionRequests = await revision.requests
        #expect(revisionRequests[0].systemPrompt.contains(artifact.id.uuidString))
        #expect(revisionRequests[0].messages.contains(.assistant(text: "Created the minutes.", toolCalls: [])))
    }

    @Test func libraryScopesAndRecoverableToolErrorsReachTheTimeline() async throws {
        let context = ModelContext(TestModelContainer.make())
        let chosen = MeetingFixtures.transcribed("Chosen", in: context)
        let other = MeetingFixtures.transcribed("Other", in: context)
        let tag = Kurn.Tag(name: "Project")
        context.insert(tag)
        chosen.tags = [tag]
        try context.save()
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("list_sources"), try chatAgentCall("read_transcript", arguments: .object([
                "meetingID": .string(chosen.id.uuidString)
            ])), try chatAgentCall("read_transcript", arguments: .object([
                "meetingID": .string(other.id.uuidString)
            ]))]), AgentTurnResponse(text: "No access to Other.")
        ])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: nil, modelContext: context)
        var editor = vm.scopeEditor
        editor.setSelection(kind: .tags, selectedIDs: [tag.id])
        editor.setParts([.summary])
        editor.setOverride([.transcript], for: chosen.id)
        vm.updateScope(editor.scope)
        ask(vm, "Read Other")
        await waitUntil { !vm.isResponding }
        #expect(vm.error == nil)
        #expect(vm.turns.last?.steps.contains { $0.toolName == "read_transcript" && $0.status == .failed } == true)
        #expect(vm.scope.kind == .tags)
        let session = try #require(vm.pastSessions().first)
        #expect(try session.harnessSnapshot().scope == editor.scope)
        let restored = MeetingChatViewModel()
        restored.configure(meeting: nil, modelContext: context)
        restored.load(session: session)
        #expect(restored.scope == editor.scope)
        #expect(restored.turns.last?.steps == vm.turns.last?.steps)
        let requests = await model.requests
        let content = requests[1].messages.compactMap { message -> String? in
            if case .toolResult(_, "list_sources", let content, _) = message { return content }
            return nil
        }.joined()
        #expect(content.contains(chosen.id.uuidString))
        #expect(!content.contains(other.id.uuidString))
        #expect(requests[1].messages.contains { message in
            if case .toolResult(_, "read_transcript", let content, false) = message {
                return content.contains("we ship on monday")
            }
            return false
        })
    }

    @Test func cancellationKeepsArtifactsAndRetryCannotBeOverwrittenByTheOldTask() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([
            AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("create_document", arguments: .object([
                "title": .string("Draft"), "markdown": .string("Body")
            ]))], usage: AgentUsage(inputTokens: 7, outputTokens: 3)),
            AgentTurnResponse(text: "Partial answer"), AgentTurnResponse(text: "Retried.")
        ], pauseAt: 1)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        ask(vm)
        await waitUntil { vm.turns.last?.text == "Partial answer" && vm.artifacts.count == 1 }
        #expect(vm.turns.last?.usage == TokenUsage(promptTokens: 7, completionTokens: 3))
        #expect((vm.turns.last?.costUSD ?? 0) > 0)
        #expect(try vm.pastSessions().first?.harnessSnapshot().artifacts == vm.artifacts)
        #expect(vm.pastSessions().first?.turns.isEmpty == true)
        let scope = vm.scope
        vm.updateScope(ChatSourceScope(kind: .library, parts: []))
        #expect(vm.scope == scope)
        ask(vm, "Ignored while busy")
        vm.cancel()
        #expect(vm.turns.map(\.role) == [.user])
        #expect(vm.retryableQuestion == "Create minutes")
        #expect(vm.error == nil)
        vm.dropRetryableQuestion()
        ask(vm, "Retry")
        await waitUntil { !vm.isResponding }
        #expect(vm.turns.map(\.text) == ["Retry", "Retried."])
        #expect(vm.artifacts.count == 1)
        for _ in 0..<2_000 {
            if await model.wasCancelled { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = await model.wasCancelled
        #expect(cancelled)
    }
}
