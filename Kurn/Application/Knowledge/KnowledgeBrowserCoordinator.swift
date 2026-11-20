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

    func readKnowledgeCoverage(meetingIDs: Set<UUID>) async throws -> KnowledgeCoverageRead {
        let store = await jobQueue.writer()
        return try await store.coverageRead(meetingIDs: meetingIDs, scope: "workspace", authorization: { [weak self] in
            guard let self else {
                return KnowledgeSourceAuthorization(featureEnabled: false, meetingIDs: [], policies: [], sourceClassifications: [])
            }
            return await self.browserReadAuthorization(meetingIDs: meetingIDs)
        })
    }
}
