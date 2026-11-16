import Foundation
import KurnCore

enum MeetingKnowledgeState: Equatable, Sendable {
    case idle, loading, unavailable
    case loaded(MeetingKnowledgeRead)
}

/// Read-only contributions from exactly one authorized meeting. The global
/// revision is a freshness token, never a cross-library count shown in UI.
struct MeetingKnowledgeRead: Sendable, Equatable {
    struct Contribution: Sendable, Equatable, Identifiable {
        let id: UUID
        let name: String
        let facts: [KnowledgeWikiSnapshot.Fact]
    }

    let meetingID: UUID
    let contributions: [Contribution]
    let assertionCount: Int
    let evidenceCount: Int

    init(meetingID: UUID, wiki: KnowledgeWikiSnapshot) throws {
        guard wiki.facts.allSatisfy({ $0.source.meetingID == meetingID }) else { throw KnowledgeWikiStoreError.scopeDenied }
        let pages = try KnowledgeWikiProjector.project(wiki)
        self.meetingID = meetingID
        self.contributions = pages.map {
            Contribution(id: $0.entity.id, name: $0.entity.name, facts: $0.sections.flatMap(\.entries).map(\.fact))
        }.sorted {
            let left = KnowledgeEntityResolver.normalizedName($0.name)
            let right = KnowledgeEntityResolver.normalizedName($1.name)
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
        self.assertionCount = Set(wiki.facts.map(\.id)).count
        self.evidenceCount = Set(wiki.facts.flatMap { $0.source.evidence.map(\.id) }).count
    }

    var summary: String {
        String(format: NSLocalizedString("detail.knowledge.counts", comment: "Meeting contribution counts"),
            contributions.count, assertionCount, evidenceCount)
    }
}

extension KnowledgeCompilationCoordinator {
    func generateLocalMeetingNotes(_ meeting: Meeting, wiki: WikiCoordinator) async -> WikiCoordinator.GenerationOutcome {
        do {
            _ = try await readMeetingKnowledge(meetingID: meeting.id)
            try meetingReadAuthorization(meetingID: meeting.id).authorize(classifications: [])
            return await wiki.generate(meeting, trigger: .explicit, force: true, localOnly: true)
        } catch {
            return .skipped
        }
    }

    /// Reading never requires a usable provider and never queues extraction or
    /// publication. The detail route authorizes this meeting alone, not a scope
    /// label or every meeting in the library.
    func readMeetingKnowledge(meetingID: UUID) async throws -> MeetingKnowledgeRead {
        let store = await jobQueue.writer()
        let snapshot = try await store.wikiProjectionSnapshot(meetingIDs: [meetingID], scope: "workspace", authorization: { [weak self] in
            guard let self else {
                return KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
            }
            return await self.meetingReadAuthorization(meetingID: meetingID)
        })
        return try MeetingKnowledgeRead(meetingID: meetingID, wiki: snapshot.wiki)
    }
}
