import AgentHarness
import Foundation
import KurnCore
import Observation

/// A destructive document change the agent asks to make, shown for the person to allow or refuse.
struct ChatChangeRequest: Identifiable, Equatable {
    /// The tool call's ID.
    let id: String
    /// The document as it is now, if the call names one the conversation has.
    let document: ChatDocumentArtifact?
    /// The title it would get, when the call changes it.
    let newTitle: String?
    /// The body that would replace the document's.
    let markdown: String

    init(id: String, document: ChatDocumentArtifact?, newTitle: String?, markdown: String) {
        self.id = id; self.document = document; self.newTitle = newTitle; self.markdown = markdown
    }

    /// The request for `call` against the conversation's `documents`. Arguments the tool would
    /// reject still make a request: the tool validates them after a yes, as it always does.
    init(_ call: AgentToolCall, documents: [ChatDocumentArtifact]) {
        let values: [String: JSONValue]
        if case .object(let object) = call.arguments { values = object } else { values = [:] }
        func text(_ key: String) -> String? { if case .string(let value)? = values[key] { return value }; return nil }
        let documentID = text("document_id").flatMap(UUID.init(uuidString:))
        let document = documentID.flatMap { id in documents.first { $0.id == id } }
        let title = text("title").flatMap { $0 == document?.title ? nil : $0 }
        self.init(id: call.id, document: document, newTitle: title, markdown: text("markdown") ?? "")
    }

    /// The name the request shows for the document: its title, or the new one for a document the
    /// conversation does not have.
    var documentTitle: String { document?.title ?? newTitle ?? "" }
}

/// One destructive change at a time waits for the person (tool calls run one after another). A
/// cancelled run refuses the change it was waiting on, so a stop never leaves the run hanging.
@MainActor
@Observable
final class ChatChangeConfirmation {
    private(set) var pending: ChatChangeRequest?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    /// Waits for `answer`; false at once if another change is waiting or the task is cancelled.
    func request(_ request: ChatChangeRequest) async -> Bool {
        guard continuation == nil else { return false }
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation
                self.pending = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(false, to: id) }
        }
    }

    /// The person's answer to the change waiting, if `id` (when given) is still the one waiting.
    func answer(_ approved: Bool, to id: String? = nil) {
        guard let continuation, id == nil || id == pending?.id else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: approved)
    }
}
