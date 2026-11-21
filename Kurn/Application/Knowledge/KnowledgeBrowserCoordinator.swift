import Foundation
import KurnCore

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

    /// The K6.2 export bundle of these meetings, encoded as JSON. `.export` is authorized before
    /// the read and again against the read's own classifications.
    func exportKnowledge(meetingIDs: Set<UUID>, now: Date = Date()) async throws -> Data {
        try browserReadAuthorization(meetingIDs: meetingIDs).authorize(classifications: [], operation: .export)
        let read = try await readKnowledgeBrowser(meetingIDs: meetingIDs)
        try Task.checkCancellation()
        try browserReadAuthorization(meetingIDs: meetingIDs).authorize(classifications: read.sourceClassifications, operation: .export)
        let bundle = KnowledgeExportBundle(revision: read.revision, exportedAt: now, meetingTitles: read.meetingTitles, pages: read.pages)
        return try bundle.encoded()
    }
}
