import Foundation

extension KnowledgeCompilationCoordinator {
    func readKnowledgeReview(meetingIDs: Set<UUID>) async throws -> KnowledgeReviewRead {
        let store = await jobQueue.writer()
        return try await store.reviewInbox(meetingIDs: meetingIDs, authorization: { [weak self] in
            await self?.browserReadAuthorization(meetingIDs: meetingIDs)
                ?? KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
        })
    }

    func decideKnowledgeReview(_ command: KnowledgeReviewCommand, snapshot: KnowledgeEntityMutationSnapshot) async throws {
        let store = await jobQueue.writer()
        let ids = Set(snapshot.sources.map(\.meetingID))
        try await store.reviewDecision(command, snapshot: snapshot, authorization: { [weak self] in
            await self?.browserReadAuthorization(meetingIDs: ids)
                ?? KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
        })
    }
}
