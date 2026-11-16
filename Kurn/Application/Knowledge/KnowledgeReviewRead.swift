import Foundation
import KurnCore

struct KnowledgeReviewRead: Equatable, Sendable {
    struct Candidate: Equatable, Sendable, Identifiable {
        let id: UUID
        let source: KnowledgeEntityResolutionValue
        let target: KnowledgeEntityResolutionValue
        let isDismissed: Bool
    }
    struct Merge: Equatable, Sendable, Identifiable {
        let receipt: KnowledgeEntityMergeReceipt
        let sourceName: String
        let targetName: String
        let isUndone: Bool
        var id: UUID { receipt.operationID }
    }
    struct Warning: Equatable, Sendable, Identifiable {
        let id: String
        let kind: KnowledgeReviewHint.Kind
        let entries: [KnowledgeWikiPage.Entry]
    }
    let snapshot: KnowledgeEntityMutationSnapshot
    let candidates: [Candidate]
    let merges: [Merge]
    let warnings: [Warning]
    let evidenceUnavailable: Bool
    let isTruncated: Bool
    let allowsMutation: Bool
    var meetingIDs: Set<UUID> { Set(snapshot.sources.map(\.meetingID)) }
}

enum KnowledgeReviewCommand: Hashable, Sendable {
    case merge(UUID), undo(UUID), dismiss(UUID), reopen(UUID)
}
