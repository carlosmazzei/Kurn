import Foundation
import KurnCore

/// Routes carry identifiers only. Every destination is resolved again from the
/// currently authorized sources; navigation history is never a content cache.
enum KnowledgeBrowserRoute: Hashable, Sendable {
    case entity(UUID)
    /// The scoped timeline (K3.3), projected from the same pages as the reader.
    case timeline
    /// An entity's state compared between two days (K3.4).
    case compare(UUID)
    /// The relationships around an entity (K4.3), from the same pages.
    case graph(UUID)
    case evidence(assertionID: UUID, evidenceID: UUID)
    case transcript(assertionID: UUID, evidenceID: UUID)

    var evidenceSelection: KnowledgeEvidenceSelection? {
        switch self {
        case .entity, .timeline, .compare, .graph: nil
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

/// The occasion a meeting was recorded at (spec §20.1), for the graph's
/// context lanes. A meeting with no link is in context `unknown`.
struct KnowledgeBrowserContext: Equatable, Sendable {
    /// nil for the unknown context.
    let id: UUID?
    let kind: KnowledgeContextKind
    let name: String
    /// What its sources inherit; a meeting with no context is internal.
    var classification: KnowledgeClassification = .internal

    static let unknown = KnowledgeBrowserContext(id: nil, kind: .unknown, name: "")
}

struct KnowledgeBrowserRead: Equatable, Sendable {
    let meetingIDs: Set<UUID>
    let pages: [KnowledgeWikiPage]
    let meetingTitles: [UUID: String]
    /// Each meeting's context; a meeting missing here is in context `unknown`.
    let meetingContexts: [UUID: KnowledgeBrowserContext]

    /// The classification every selected meeting's knowledge inherits.
    var sourceClassifications: [KnowledgeClassification] {
        meetingIDs.sorted { $0.uuidString < $1.uuidString }.map { meetingContexts[$0]?.classification ?? .internal }
    }

    /// The canonical revision the read was taken at, kept even when it holds no visible claim.
    let revision: Int
    let selectedEvidence: KnowledgeEvidenceRead?
    let policyRevisionKey: String
    let allowsEmbedding: Bool

    var searchCorpus: KnowledgeSearchCorpus {
        KnowledgeSearchCorpus(pages: pages, meetingIDs: meetingIDs, allowsEmbedding: allowsEmbedding)
    }

    init(meetingIDs: Set<UUID>, wiki: KnowledgeWikiSnapshot, meetingTitles: [UUID: String],
         selectedEvidence: KnowledgeEvidenceRead? = nil, policyRevisionKey: String = "", allowsEmbedding: Bool = false,
         meetingContexts: [UUID: KnowledgeBrowserContext] = [:]) throws {
        guard !meetingIDs.isEmpty, meetingIDs.count <= 16, Set(meetingTitles.keys) == meetingIDs,
              Set(meetingContexts.keys).isSubset(of: meetingIDs),
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
        self.meetingContexts = meetingContexts
        revision = wiki.revision
        self.selectedEvidence = selectedEvidence
        self.policyRevisionKey = policyRevisionKey
        self.allowsEmbedding = allowsEmbedding
    }
}

enum KnowledgeBrowserLoadState: Equatable, Sendable {
    case idle, loading, unavailable
    case loaded(KnowledgeBrowserRead)
}
