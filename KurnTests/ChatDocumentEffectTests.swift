import AgentHarness
import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct ChatDocumentEffectTests {
    private func setup() throws -> (SwiftDataAgentSessionStore, ChatSession) {
        let context = ModelContext(TestModelContainer.make())
        let session = ChatSession(meeting: nil, title: "Document task")
        context.insert(session)
        let store = SwiftDataAgentSessionStore(context: context)
        try store.writePresentation(session, turns: [], scope: nil, artifacts: [])
        return (store, session)
    }
    private func execution(_ session: ChatSession, name: String = "create_document", id: String = UUID().uuidString) throws -> AgentToolExecutionContext {
        AgentToolExecutionContext(sessionID: session.id.uuidString,
            invocation: try AgentToolInvocation(id: id, requestID: "request", callID: "provider-call", toolName: name))
    }
    private let create: JSONValue = .object(["title": .string("Report"), "markdown": .string("Initial")])

    @Test func knownCommittedInvocationReplaysWithoutDuplicatingAndSurvivesReopen() async throws {
        let (store, session) = try setup()
        let workspace = ChatDocumentWorkspace()
        let writer = ChatDocumentEffectWriter(store: store, sessionID: session.id.uuidString)
        let executor = ChatDocumentEffectExecutor(writer: writer, workspace: workspace)
        let context = try execution(session)
        let first = try await executor.execute("create_document", arguments: create, context: context)
        let revision = session.canonicalRevision
        #expect(try await executor.execute("create_document", arguments: create, context: context) == first)
        #expect(session.canonicalRevision == revision && session.harnessRecords.count == 1 && session.harnessRevisions.count == 1)
        let reopenedContext = ModelContext(store.context.container)
        let reopened = SwiftDataAgentSessionStore(context: reopenedContext)
        let restored = try reopened.session(session.id.uuidString).harnessSnapshot()
        #expect(restored.artifacts.count == 1 && restored.artifacts.first?.markdown == "Initial")
        let retry = ChatDocumentEffectWriter(store: reopened, sessionID: session.id.uuidString)
        #expect(try retry.commit("create_document", arguments: create, execution: context).output == first)
        #expect(await workspace.snapshot() == restored.artifacts)
    }

    @Test func appendReceiptReplaysOldResultWithoutRewindingCurrentRevision() async throws {
        let (store, session) = try setup()
        let writer = ChatDocumentEffectWriter(store: store, sessionID: session.id.uuidString)
        let first = try writer.commit("create_document", arguments: create, execution: execution(session))
        let id = try #require(first.artifacts.first?.id)
        let arguments = JSONValue.object(["document_id": .string(id.uuidString), "markdown": .string("Added")])
        let original = try execution(session, name: "append_to_document")
        let second = try writer.commit("append_to_document", arguments: arguments, execution: original)
        _ = try writer.commit("append_to_document", arguments: arguments, execution: execution(session, name: "append_to_document"))
        let retry = try writer.commit("append_to_document", arguments: arguments, execution: original)
        #expect(retry.output == second.output)
        #expect(retry.artifacts.first?.version == 3 && retry.artifacts.first?.markdown == "Initial\n\nAdded\n\nAdded")
        #expect(session.harnessRecords.count == 3 && session.harnessRevisions.count == 3)
    }

    @Test func receiptIdentityConflictsRejectChangedArgumentsAndRequest() throws {
        let (store, session) = try setup()
        let writer = ChatDocumentEffectWriter(store: store, sessionID: session.id.uuidString)
        let context = try execution(session)
        _ = try writer.commit("create_document", arguments: create, execution: context)
        #expect(throws: AgentSessionStoreError.conflict) {
            try writer.commit("create_document", arguments: .object(["title": .string("Changed"), "markdown": .string("Other")]), execution: context)
        }
        let changed = AgentToolExecutionContext(sessionID: session.id.uuidString, invocation: try AgentToolInvocation(
            id: context.invocation.id, requestID: "different-request", callID: "provider-call", toolName: "create_document"))
        #expect(throws: AgentSessionStoreError.conflict) { try writer.commit("create_document", arguments: create, execution: changed) }
        #expect(try session.harnessSnapshot().artifacts.count == 1)
    }

    @Test func failedSaveCannotPublishMutationReceiptOrSuccess() async throws {
        enum Failure: Error { case disk }
        let (store, session) = try setup()
        let before = try store.snapshot(session)
        let failing = SwiftDataAgentSessionStore(context: store.context, save: { _ in throw Failure.disk })
        let workspace = ChatDocumentWorkspace()
        let executor = ChatDocumentEffectExecutor(writer: ChatDocumentEffectWriter(store: failing, sessionID: session.id.uuidString), workspace: workspace)
        let tool = try #require(ChatDocumentTools.make(workspace: workspace, mutation: { name, arguments, context in
            try await executor.execute(name, arguments: arguments, context: context)
        }).first { $0.spec.name == "create_document" })
        let output = try await tool.executeWithContext(create, execution(session))
        #expect(output.isError && output.metrics[.mutationsCommitted] == nil)
        #expect(await workspace.snapshot().isEmpty)
        #expect(session.harnessRecords.isEmpty && session.harnessRevisions.isEmpty)
        #expect(try store.snapshot(session).entries == before.entries && session.canonicalRevision == before.revision)
        // A later successful save cannot accidentally flush a staged failed mutation.
        try store.context.save()
        #expect(try ModelContext(store.context.container).fetchCount(FetchDescriptor<HarnessArtifactRevision>()) == 0)
    }

    @Test func concurrentAppendsSerializeThroughCommitAndPublication() async throws {
        let (store, session) = try setup()
        let workspace = ChatDocumentWorkspace()
        let executor = ChatDocumentEffectExecutor(writer: ChatDocumentEffectWriter(store: store, sessionID: session.id.uuidString), workspace: workspace)
        _ = try await executor.execute("create_document", arguments: create, context: execution(session))
        let id = try #require(await workspace.snapshot().first?.id)
        let contexts = try (0..<8).map { _ in try execution(session, name: "append_to_document") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, context) in contexts.enumerated() {
                group.addTask {
                    _ = try await executor.execute("append_to_document", arguments: .object([
                        "document_id": .string(id.uuidString), "markdown": .string("Section \(index)")]), context: context)
                }
            }
            try await group.waitForAll()
        }
        let artifact = try await workspace.read(id)
        #expect(artifact.version == 9 && session.harnessRecords.count == 9)
        for index in 0..<8 { #expect(artifact.markdown.components(separatedBy: "Section \(index)").count == 2) }
        #expect(try session.harnessSnapshot().artifacts == [artifact])
    }

    @Test func cancellationAfterSaveStillPublishesCommittedSnapshotAndReceipt() async throws {
        let (store, session) = try setup()
        let workspace = ChatDocumentWorkspace()
        let cancelling = SwiftDataAgentSessionStore(context: store.context, save: { context in
            try context.save()
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let executor = ChatDocumentEffectExecutor(writer: ChatDocumentEffectWriter(store: cancelling, sessionID: session.id.uuidString), workspace: workspace)
        let context = try execution(session)
        let arguments = create
        let task = Task { try await executor.execute("create_document", arguments: arguments, context: context) }
        let output = try await task.value
        #expect(!output.isError && output.metrics[.mutationsCommitted] == 1)
        let published = await workspace.snapshot()
        #expect(try session.harnessSnapshot().artifacts == published)
        #expect(session.harnessRecords.count == 1)
    }

    @Test func firstMutationPersistsAcceptedQuestionInExistingConversationOnlyOnce() async throws {
        let (store, session) = try setup()
        let old = PersistedChatTurn(id: UUID(), role: .assistant, text: "Earlier answer", usage: nil, costUSD: nil, elapsedSeconds: nil)
        let accepted = PersistedChatTurn(id: UUID(), role: .user, text: "Create two documents", usage: nil, costUSD: nil, elapsedSeconds: nil)
        try store.writePresentation(session, turns: [old], scope: nil, artifacts: [])
        let writer = ChatDocumentEffectWriter(store: store, sessionID: session.id.uuidString, prepareSession: {
            // Repeating this preparation after the first mutation would rewind its artifacts.
            try store.writePresentation(session, turns: [old, accepted], scope: nil, artifacts: [])
        }, origin: ChatArtifactOrigin(question: accepted.text, modelIdentifier: "test"))
        let workspace = ChatDocumentWorkspace()
        let executor = ChatDocumentEffectExecutor(writer: writer, workspace: workspace)
        _ = try await executor.execute("create_document", arguments: create, context: execution(session))
        _ = try await executor.execute("create_document", arguments: create, context: execution(session))
        let restored = try session.harnessSnapshot()
        #expect(restored.turns.map(\.id) == [old.id, accepted.id])
        #expect(restored.artifacts.count == 2 && restored.turns.last?.artifacts?.count == 2)
        #expect(restored.turns.first?.artifacts == nil)
    }
}
