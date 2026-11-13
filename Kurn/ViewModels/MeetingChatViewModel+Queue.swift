import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// Input the person queues while a reply runs (NH08): *steering* ("Orientar") enters the run after
/// its current tool batch, a *follow-up* ("Depois desta tarefa") once it would otherwise finish.
/// Every change is saved in the conversation's `.queue` record before it is acknowledged; a stop,
/// a failed run or a reopened conversation hands what was not answered back to the composer.
extension MeetingChatViewModel {
    /// Queues `text` for the running reply. Returns whether it was accepted (saved); an input
    /// that could not be saved stays with the person, and the chat says so.
    @discardableResult
    func queue(_ text: String, as kind: AgentInputQueue.Kind) async -> Bool {
        guard let inputQueue, isResponding, phase != .cancelling else { return false }
        do {
            try await inputQueue.enqueue(text, as: kind)
            return true
        } catch AgentInputQueue.QueueError.emptyText {
            return false
        } catch {
            self.error = .apiError(statusCode: 0, message: NSLocalizedString("chat.queue.save_failed",
                                                                              comment: "Queued message not saved"))
            return false
        }
    }

    /// Removes a queued item before the run takes it.
    func removeQueued(_ id: String) async {
        try? await inputQueue?.remove(id)
    }

    /// Takes a queued item back into the composer to edit, removing it from the queue.
    func editQueued(_ item: AgentInputQueue.Item) async {
        guard (try? await inputQueue?.remove(item.id)) != nil else { return }
        restoreToDraft([item.text])
    }

    /// Creates the running reply's queue, saved in the open conversation, and mirrors its lists.
    func startInputQueue() -> AgentInputQueue {
        let queue = AgentInputQueue(persist: { [weak self] snapshot in try await self?.saveQueue(snapshot) })
        inputQueue = queue
        queueObserver?.cancel()
        queueObserver = Task { [weak self] in
            for await snapshot in await queue.updates() { self?.queued = snapshot }
        }
        return queue
    }

    func stopInputQueue() {
        queueObserver?.cancel()
        queueObserver = nil
        inputQueue = nil
        queued = AgentInputQueue.Snapshot()
    }

    /// Hands back what a run did not answer: `taken` — queued input it took in before it stopped —
    /// and whatever is still queued.
    func restoreUnansweredInput(_ taken: [String]) async {
        let pending = (try? await inputQueue?.clear()) ?? []
        restoreToDraft(taken + pending.map(\.text))
    }

    /// Adds `texts` to the text handed back to the composer, one paragraph each.
    func restoreToDraft(_ texts: [String]) {
        let restored = texts.filter { !$0.isEmpty }
        guard !restored.isEmpty else { return }
        restoredDraft = ([restoredDraft].compactMap { $0 } + restored).joined(separator: "\n\n")
    }

    /// A conversation reopened after a process died with input still queued gives it back.
    func restoreLeftoverQueue(of session: ChatSession) {
        guard let modelContext = session.modelContext else { return }
        let store = SwiftDataAgentSessionStore(context: modelContext)
        let leftover = ChatInputQueueRecord.load(from: session, store: store)
        guard !leftover.isEmpty else { return }
        restoreToDraft((leftover.steering + leftover.followUp).map(\.text))
        try? ChatInputQueueRecord.save(AgentInputQueue.Snapshot(), in: session, store: store)
    }

    func saveQueue(_ snapshot: AgentInputQueue.Snapshot) throws {
        guard let session = artifactSession, let modelContext = session.modelContext else { return }
        try ChatInputQueueRecord.save(snapshot, in: session, store: SwiftDataAgentSessionStore(context: modelContext))
    }

    /// The conversation with a run's exchanges shown from `index` (its reply turn): the run's own
    /// reply there, then each queued input it took in as a question turn — keeping the input's
    /// identity — followed by its reply. A run with a single exchange shows `fallback`, its text.
    static func presenting(_ exchanges: [AgentRunSnapshot.Exchange], fallback: String,
                           in turns: [Turn], from index: Int) -> [Turn] {
        var turns = turns
        guard exchanges.count > 1 else {
            turns[index].text = fallback
            return turns
        }
        turns[index].text = exchanges[0].text
        for (offset, exchange) in exchanges.enumerated().dropFirst() {
            let reply = index + offset * 2
            if turns.count <= reply {
                turns.append(Turn(id: exchange.inputID.flatMap(UUID.init(uuidString:)) ?? UUID(), role: .user,
                                  text: exchange.input ?? ""))
                turns.append(Turn(role: .assistant, text: ""))
            }
            turns[reply].text = exchange.text
        }
        return turns
    }
}
