import Foundation

public struct ChatArtifactReference: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let version: Int

    public init(_ artifact: ChatDocumentArtifact) {
        id = artifact.id
        title = artifact.title
        version = artifact.version
    }

    public func label(localize: (String) -> String) -> String {
        String(format: localize("chat.artifact.reference"), title, version)
    }

    public static func updating(_ references: [Self], from previous: [ChatDocumentArtifact],
                                to current: [ChatDocumentArtifact]) -> [Self] {
        var result = references
        for artifact in current where !previous.contains(where: { $0.id == artifact.id && $0.version == artifact.version }) {
            let reference = Self(artifact)
            if let index = result.firstIndex(where: { $0.id == artifact.id }) { result[index] = reference }
            else { result.append(reference) }
        }
        return result
    }
}
