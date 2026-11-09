import Foundation

public struct ChatDocumentArtifact: Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let markdown: String
    public let version: Int

    public init(id: UUID = UUID(), title: String, markdown: String, version: Int = 1) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.version = version
    }
}

public actor ChatDocumentWorkspace {
    public static let maximumScalars = 200_000
    private var artifacts: [UUID: ChatDocumentArtifact]

    public init() { artifacts = [:] }

    public init(artifacts: [ChatDocumentArtifact]) throws {
        var restored: [UUID: ChatDocumentArtifact] = [:]
        for artifact in artifacts {
            try Self.validate(title: artifact.title, markdown: artifact.markdown)
            guard artifact.version > 0, restored[artifact.id] == nil else {
                throw ChatDocumentError("Invalid version or duplicate document ID.")
            }
            restored[artifact.id] = artifact
        }
        self.artifacts = restored
    }

    public func snapshot() -> [ChatDocumentArtifact] {
        artifacts.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func read(_ id: UUID) throws -> ChatDocumentArtifact {
        guard let artifact = artifacts[id] else { throw ChatDocumentError("Unknown document ID.") }
        return artifact
    }

    public func create(title: String, markdown: String) throws -> ChatDocumentArtifact {
        try Task.checkCancellation()
        try Self.validate(title: title, markdown: markdown)
        let artifact = ChatDocumentArtifact(title: title, markdown: markdown)
        artifacts[artifact.id] = artifact
        return artifact
    }

    public func update(_ id: UUID, markdown: String, title: String?) throws -> ChatDocumentArtifact {
        let current = try read(id)
        return try replace(current, title: title ?? current.title, markdown: markdown)
    }

    public func append(_ id: UUID, markdown: String) throws -> ChatDocumentArtifact {
        let current = try read(id)
        try Self.validate(title: current.title, markdown: markdown)
        return try replace(current, title: current.title, markdown: current.markdown + "\n\n" + markdown)
    }

    private func replace(_ current: ChatDocumentArtifact, title: String, markdown: String) throws -> ChatDocumentArtifact {
        try Task.checkCancellation()
        try Self.validate(title: title, markdown: markdown)
        guard current.version < Int.max else { throw ChatDocumentError("Document version limit reached.") }
        let artifact = ChatDocumentArtifact(id: current.id, title: title, markdown: markdown, version: current.version + 1)
        artifacts[current.id] = artifact
        return artifact
    }

    private static func validate(title: String, markdown: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.unicodeScalars.count <= 500 else {
            throw ChatDocumentError("Title must contain text and be at most 500 Unicode scalars.")
        }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              markdown.unicodeScalars.count <= maximumScalars else {
            throw ChatDocumentError("Markdown must contain text and be at most 200000 Unicode scalars.")
        }
    }
}

public struct ChatDocumentError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
