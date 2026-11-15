import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// The service also supports hosts without a view model. Prepare their accepted input lazily
/// before the first document effect, using the same durable store as the app composition.
@MainActor
struct HarnessStandaloneSessionPreparation {
    let context: ModelContext
    let sessionID: UUID
    let scope: ChatSourceScope
    let history: [ChatMessage]
    let question: String
    let artifacts: [ChatDocumentArtifact]
    let questionID = UUID()

    func prepare() throws {
        let store = SwiftDataAgentSessionStore(context: context)
        let target: ChatSession
        do { target = try store.session(sessionID.uuidString) }
        catch AgentSessionStoreError.notFound {
            target = ChatSession(meeting: nil, title: ChatSession.title(from: question))
            target.id = sessionID; context.insert(target)
        }
        let saved = try target.harnessSnapshot()
        var turns = history.enumerated().map { index, message -> PersistedChatTurn in
            let role: ChatMessage.Role = message.role == .assistant ? .assistant : .user
            if saved.turns.indices.contains(index), saved.turns[index].role == role, saved.turns[index].text == message.content {
                return saved.turns[index]
            }
            return PersistedChatTurn(id: UUID(), role: role, text: message.content, usage: nil, costUSD: nil, elapsedSeconds: nil)
        }
        turns.append(PersistedChatTurn(id: questionID, role: .user, text: question, usage: nil, costUSD: nil, elapsedSeconds: nil))
        let presentation = try HarnessPresentationReconciler.preserve(turns: turns, artifacts: artifacts, committed: (saved.turns, saved.artifacts))
        try store.writePresentation(target, turns: presentation.turns, scope: scope, artifacts: presentation.artifacts)
    }
}
