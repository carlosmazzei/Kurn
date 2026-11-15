import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingChatHarnessFailureTests {
    private func ask(_ vm: MeetingChatViewModel, question: String = "Question") {
        vm.send(question: question, provider: .openAI, model: "gpt-4o")
    }

    private func waitUntilDone(_ vm: MeetingChatViewModel) async {
        for _ in 0..<2_000 where vm.isResponding { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!vm.isResponding)
    }

    @Test func factoryErrorsAndUnconfiguredHarnessUseExistingAppErrorMapping() async {
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in throw AppError.invalidProviderURL })
        ask(vm, question: " \n ")
        #expect(vm.turns.isEmpty)
        ask(vm)
        await waitUntilDone(vm)
        guard case .invalidProviderURL = vm.error else { Issue.record("Expected invalidProviderURL"); return }
        #expect(vm.retryableQuestion == "Question")
        let unconfigured = MeetingChatViewModel(agentModelFactory: { _, _ in ChatAgentModel() })
        ask(unconfigured)
        await waitUntilDone(unconfigured)
        guard case .apiError(0, _) = unconfigured.error else { Issue.record("Expected apiError"); return }
        #expect(unconfigured.turns.map(\.role) == [.user])
    }

    @Test(arguments: [false, true]) func providerFailuresDropPartialStepsAndLeaveARetryableQuestion(appError: Bool) async {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel(appError: appError ? .invalidProviderURL : nil, fails: !appError)
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        ask(vm)
        await waitUntilDone(vm)
        #expect(vm.turns.map(\.role) == [.user])
        #expect(vm.retryableQuestion == "Question")
        if appError {
            guard case .invalidProviderURL = vm.error else { Issue.record("Expected invalidProviderURL"); return }
        }
        else {
            guard case .apiError(0, _) = vm.error else { Issue.record("Expected wrapped provider error"); return }
        }
    }

    @Test func emptyResolvedScopeAndPartsAreValidatedBeforeCallingTheModel() async {
        let context = ModelContext(TestModelContainer.make())
        let model = ChatAgentModel([AgentTurnResponse(text: "Should not run")])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: nil, modelContext: context)
        ask(vm)
        await waitUntilDone(vm)
        guard case .apiError(_, let sourceMessage) = vm.error else { Issue.record("Expected source validation error"); return }
        #expect(sourceMessage == NSLocalizedString("chat.sources.validation.meetings", comment: "No meetings"))
        #expect(await model.requests.isEmpty)
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        vm.reset()
        vm.updateScope(ChatSourceScope(kind: .meetings, selectedIDs: [meeting.id], parts: []))
        ask(vm)
        await waitUntilDone(vm)
        guard case .apiError(_, let partsMessage) = vm.error else { Issue.record("Expected part validation error"); return }
        #expect(partsMessage == NSLocalizedString("chat.sources.validation.parts", comment: "No parts"))
        #expect(await model.requests.isEmpty)
        vm.reset()
        vm.updateScope(ChatSourceScope(kind: .meetings, selectedIDs: [meeting.id], parts: [.transcript]))
        ask(vm)
        await waitUntilDone(vm)
        #expect(vm.error == nil)
        #expect(vm.turns.last?.text == "Should not run")
    }

    @Test func wikiSettingGatesGlobalAndOverridePartsWithoutMutatingSavedSelection() {
        let id = UUID()
        let scope = ChatSourceScope(kind: .library, parts: [.wiki, .summary], partOverrides: [id: [.wiki]])
        let off = HarnessChatService(isWikiEnabled: { false }).effectiveScope(scope)
        #expect(off.parts == [.summary])
        #expect(off.parts(for: id).isEmpty)
        #expect(scope.parts(for: id) == [.wiki])
        #expect(HarnessChatService(isWikiEnabled: { true }).effectiveScope(scope) == scope)
    }

    @Test func invalidSavedStateIsNotSilentlyReplacedAndCrossMeetingLoadsAreRejected() throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let vm = MeetingChatViewModel()
        vm.configure(meeting: meeting, modelContext: context)
        let other = ChatSession(meeting: nil, title: "Other scope")
        vm.load(session: other)
        #expect(vm.currentSessionID == nil)
        let session = ChatSession(meeting: meeting, title: "Saved")
        context.insert(session)
        #expect(try session.harnessSnapshot().scope == nil)
        #expect(try session.harnessSnapshot().artifacts.isEmpty == true)
        session.scopeData = Data("broken".utf8)
        vm.load(session: session)
        #expect(vm.error != nil)
        #expect(vm.currentSessionID == nil)
        session.scopeData = nil
        session.artifactsData = Data("broken".utf8)
        vm.load(session: session)
        #expect(vm.error != nil)
        session.artifactsData = JSONStorage.encodeAuthoritative([ChatDocumentArtifact(title: "Invalid", markdown: "Body", version: 0)])
        vm.load(session: session)
        #expect(vm.error != nil)
        #expect(vm.artifacts.isEmpty)
        session.artifactsData = nil
        session.scopeData = JSONStorage.encodeAuthoritative(ChatSourceScope(kind: .library, selectedIDs: [UUID()], parts: [.summary]))
        vm.load(session: session)
        #expect(vm.error == nil)
        #expect(vm.scope.kind == .meetings)
        #expect(vm.scope.selectedIDs == [meeting.id])
        #expect(vm.scope.parts == [.summary])
        vm.reset()
        #expect(vm.currentSessionID == nil)
        #expect(vm.artifacts.isEmpty)
        #expect(vm.scope.selectedIDs == [meeting.id])
    }

    @Test func outputLimitIsPersistedAsAStructuredStop() async {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "Cut off", stopReason: .maxTokens)])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        ask(vm)
        await waitUntilDone(vm)
        #expect(vm.turns.last?.text == "Cut off")
        #expect(vm.retryableQuestion == nil)
        #expect(ChatRunNotice.text(steps: vm.turns.last?.steps ?? [], hasAnswer: true, localize: { $0 }) != nil)
        #expect(vm.turns.last?.steps.last?.stopReason == .outputLimit)
        #expect(vm.pastSessions().first?.turns.last?.steps?.last?.stopReason == .outputLimit)
    }

    @Test func failedDocumentMutationAndProviderFailurePreserveTheDiagnosticTrace() async throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = MeetingFixtures.transcribed("Planning", in: context)
        let model = ChatAgentModel([AgentTurnResponse(text: "", toolCalls: [try chatAgentCall("create_document", arguments: .object([
            "title": .string(""), "markdown": .string("Body")
        ]))])])
        let vm = MeetingChatViewModel(agentModelFactory: { _, _ in model })
        vm.configure(meeting: meeting, modelContext: context)
        ask(vm)
        await waitUntilDone(vm)
        #expect(vm.error != nil)
        #expect(vm.artifacts.isEmpty)
        let session = try #require(vm.pastSessions().first)
        #expect(session.turns.map(\.role) == [.user])
        #expect(session.turns.first?.steps?.contains { $0.contextResolution != nil } == true)
        #expect(session.turns.first?.steps?.contains { $0.diagnostic?.kind == .runFailed } == true)
        #expect(vm.retryableQuestion == "Question")
    }
}
