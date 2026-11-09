import Foundation

public enum ChatArtifactPresentation {
    public static func latest(_ reference: ChatArtifactReference, in artifacts: [ChatDocumentArtifact]) -> ChatDocumentArtifact? {
        artifacts.first { $0.id == reference.id }
    }

    public static func preview(_ artifact: ChatDocumentArtifact) -> String {
        String(artifact.markdown.unicodeScalars.prefix(280))
    }

    public static func version(_ reference: ChatArtifactReference, latest: ChatDocumentArtifact,
                               localize: (String) -> String) -> String {
        if reference.version < latest.version {
            return String(format: localize("chat.artifact.version.current"), reference.version, latest.version)
        }
        return String(format: localize("chat.artifact.version"), latest.version)
    }
}
