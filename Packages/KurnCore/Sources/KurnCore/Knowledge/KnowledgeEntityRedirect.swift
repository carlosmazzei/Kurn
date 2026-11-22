import Foundation

public struct KnowledgeEntityRedirect: Sendable, Equatable {
    public let id: UUID
    public let kind: KnowledgeEntityKind
    public let targetID: UUID?
    public init(id: UUID, kind: KnowledgeEntityKind, targetID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.targetID = targetID
    }
}

public enum KnowledgeEntityRedirectGraph {
    /// Read-only traversal. Never path-compress: each individual edge has its
    /// own reversible human decision, and assertion/evidence IDs stay intact.
    public static func resolve(_ id: UUID, nodes: [UUID: KnowledgeEntityRedirect], maximumDepth: Int = 64) throws -> UUID {
        guard (1...1_024).contains(maximumDepth) else { throw KnowledgeEntityResolutionError.redirectLimit }
        guard let original = nodes[id], original.id == id else { throw KnowledgeEntityResolutionError.missingEntity }
        var seen: Set<UUID> = []
        var current = id
        for _ in 0..<maximumDepth {
            guard seen.insert(current).inserted else { throw KnowledgeEntityResolutionError.redirectCycle }
            guard let node = nodes[current], node.id == current else { throw KnowledgeEntityResolutionError.missingEntity }
            guard node.kind == original.kind else { throw KnowledgeEntityResolutionError.kindMismatch }
            guard let next = node.targetID else { return current }
            current = next
        }
        throw KnowledgeEntityResolutionError.redirectLimit
    }
}
