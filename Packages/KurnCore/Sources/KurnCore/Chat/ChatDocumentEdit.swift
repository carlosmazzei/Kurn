import Foundation

/// A domain edit can be planned without publishing it to a workspace or saving it.
public enum ChatDocumentEdit: Sendable {
    case create(title: String, markdown: String)
    case update(UUID, title: String?, markdown: String)
    case append(UUID, markdown: String)

    public func applying(to artifacts: [ChatDocumentArtifact]) throws -> (artifact: ChatDocumentArtifact, artifacts: [ChatDocumentArtifact]) {
        _ = try ChatDocumentWorkspace(artifacts: artifacts)
        let artifact: ChatDocumentArtifact
        switch self {
        case .create(let title, let markdown):
            artifact = ChatDocumentArtifact(title: title, markdown: markdown)
        case .update(let id, let title, let markdown):
            let current = try current(id, in: artifacts)
            artifact = ChatDocumentArtifact(id: id, title: title ?? current.title, markdown: markdown, version: current.version + 1)
        case .append(let id, let markdown):
            let current = try current(id, in: artifacts)
            // A whitespace-only append is invalid even if the existing body is valid.
            _ = try ChatDocumentWorkspace(artifacts: [ChatDocumentArtifact(title: current.title, markdown: markdown)])
            artifact = ChatDocumentArtifact(id: id, title: current.title, markdown: current.markdown + "\n\n" + markdown, version: current.version + 1)
        }
        let result = (artifacts.filter { $0.id != artifact.id } + [artifact]).sorted { $0.id.uuidString < $1.id.uuidString }
        _ = try ChatDocumentWorkspace(artifacts: result)
        return (artifact, result)
    }

    private func current(_ id: UUID, in artifacts: [ChatDocumentArtifact]) throws -> ChatDocumentArtifact {
        guard let current = artifacts.first(where: { $0.id == id }) else { throw ChatDocumentError("Unknown document ID.") }
        guard current.version < Int.max else { throw ChatDocumentError("Document version limit reached.") }
        return current
    }
}
