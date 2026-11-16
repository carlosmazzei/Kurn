import Foundation

extension KnowledgeCompilationCoordinator {
    func readKnowledgeBrowser(meetingIDs: Set<UUID>, selection: KnowledgeEvidenceSelection? = nil) async throws -> KnowledgeBrowserRead {
        let store = await jobQueue.writer()
        return try await store.browserRead(meetingIDs: meetingIDs, selection: selection, authorization: { [weak self] in
            guard let self else {
                return KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
            }
            return await self.browserReadAuthorization(meetingIDs: meetingIDs)
        })
    }
}
