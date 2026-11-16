import Foundation
import KurnCore

/// Routes carry identifiers only. Every destination is resolved again from the
/// currently authorized sources; navigation history is never a content cache.
enum KnowledgeBrowserRoute: Hashable, Sendable {
    case entity(UUID)
    case evidence(assertionID: UUID, evidenceID: UUID)
    case transcript(assertionID: UUID, evidenceID: UUID)

    var evidenceSelection: KnowledgeEvidenceSelection? {
        switch self {
        case .entity: nil
        case let .evidence(assertionID, evidenceID), let .transcript(assertionID, evidenceID):
            KnowledgeEvidenceSelection(assertionID: assertionID, evidenceID: evidenceID)
        }
    }
}

struct KnowledgeEvidenceSelection: Hashable, Sendable {
    let assertionID: UUID
    let evidenceID: UUID
}

struct KnowledgeEvidenceRead: Equatable, Sendable {
    let entry: KnowledgeWikiPage.Entry
    let evidence: KnowledgeWikiSnapshot.Evidence
    let meetingTitle: String
    let fileName: String
    let transcriptFingerprint: String
    let segments: [TranscriptSegment]
}

struct KnowledgeBrowserRead: Equatable, Sendable {
    let meetingIDs: Set<UUID>
    let pages: [KnowledgeWikiPage]
    let meetingTitles: [UUID: String]
    let selectedEvidence: KnowledgeEvidenceRead?

    init(meetingIDs: Set<UUID>, wiki: KnowledgeWikiSnapshot, meetingTitles: [UUID: String],
         selectedEvidence: KnowledgeEvidenceRead? = nil) throws {
        guard !meetingIDs.isEmpty, meetingIDs.count <= 16, Set(meetingTitles.keys) == meetingIDs,
              wiki.facts.allSatisfy({ meetingIDs.contains($0.source.meetingID) }) else { throw KnowledgeWikiStoreError.scopeDenied }
        let pages = try KnowledgeWikiProjector.project(wiki)
        if let selectedEvidence {
            guard pages.contains(where: { $0.sections.contains(where: { $0.entries.contains(selectedEvidence.entry) }) }),
                  selectedEvidence.entry.fact.source.evidence.contains(selectedEvidence.evidence) else {
                throw KnowledgeWikiStoreError.scopeDenied
            }
        }
        self.meetingIDs = meetingIDs
        self.pages = pages.sorted {
            let left = KnowledgeEntityResolver.normalizedName($0.entity.name)
            let right = KnowledgeEntityResolver.normalizedName($1.entity.name)
            return left == right ? $0.entity.id.uuidString < $1.entity.id.uuidString : left < right
        }
        self.meetingTitles = meetingTitles
        self.selectedEvidence = selectedEvidence
    }
}

enum KnowledgeBrowserLoadState: Equatable, Sendable {
    case idle, loading, unavailable
    case loaded(KnowledgeBrowserRead)
}
