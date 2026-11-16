import Foundation
import KurnCore
import SwiftData

extension KnowledgeStore {
    /// One fresh context, with no suspension between authorization, canonical
    /// evidence validation and reading source metadata/transcript bytes.
    func browserRead(meetingIDs: Set<UUID>, selection: KnowledgeEvidenceSelection? = nil,
                     authorization: @Sendable () async -> KnowledgeSourceAuthorization) async throws -> KnowledgeBrowserRead {
        let auth = await authorization()
        try Task.checkCancellation()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: meetingIDs, scope: "workspace", auth: auth, in: context)
        let snapshot = try KnowledgeWikiSourceRows.snapshot(sources: sources, in: context)
        var titles: [UUID: String] = [:]
        for id in meetingIDs {
            guard let meeting = try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first else {
                throw KnowledgeStoreError.sourceMissing
            }
            titles[id] = meeting.title
        }
        let evidence = try selection.map {
            try KnowledgeBrowserSourceRows.read($0, wiki: snapshot.wiki, sources: sources, titles: titles, in: context)
        }
        let allowsEmbedding = (try? auth.authorize(classifications: sources.map(\.contextClassification), operation: .embedding)) != nil
        return try KnowledgeBrowserRead(meetingIDs: meetingIDs, wiki: snapshot.wiki, meetingTitles: titles, selectedEvidence: evidence,
            policyRevisionKey: snapshot.policyRevisionKey, allowsEmbedding: allowsEmbedding)
    }
}

private enum KnowledgeBrowserSourceRows {
    static func read(_ selection: KnowledgeEvidenceSelection, wiki: KnowledgeWikiSnapshot, sources: [KnowledgeStoreSnapshot],
                     titles: [UUID: String], in context: ModelContext) throws -> KnowledgeEvidenceRead {
        let pages = try KnowledgeWikiProjector.project(wiki)
        guard let entry = pages.lazy.flatMap({ $0.sections.flatMap(\.entries) }).first(where: { $0.fact.id == selection.assertionID }),
              let evidence = entry.fact.source.evidence.first(where: { $0.id == selection.evidenceID }),
              let source = sources.first(where: { $0.meetingID == entry.fact.source.meetingID }),
              let recordingSource = source.recordings.first(where: { $0.id == evidence.recordingID }),
              let fingerprint = recordingSource.fingerprint, let title = titles[source.meetingID] else {
            throw KnowledgeWikiStoreError.scopeDenied
        }
        let recordingID = evidence.recordingID
        guard let recording = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.id == recordingID })).first,
              recording.meeting?.id == source.meetingID, recording.isReadyForConsumption else { throw KnowledgeStoreError.sourceNotReady }
        return KnowledgeEvidenceRead(entry: entry, evidence: evidence, meetingTitle: title, fileName: recording.fileName,
            transcriptFingerprint: fingerprint, segments: recordingSource.segments)
    }
}
