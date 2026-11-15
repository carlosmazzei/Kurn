import Foundation
import KurnCore
import SwiftData

enum KnowledgeWikiFactRows {
    static func fact(_ row: KnowledgeAssertion, origin: KnowledgeWikiSourceRows.Origin,
                     source: KnowledgeStoreSnapshot, in context: ModelContext) throws -> KnowledgeWikiSnapshot.Fact? {
        guard let review = KnowledgeReviewState(rawValue: row.reviewStateRaw),
              let authority = KnowledgeAuthorityStatus(rawValue: row.authorityStatusRaw) else { throw KnowledgeWikiStoreError.invalidCanonical }
        guard review.isVisible, authority != .rejected else { return nil }
        guard let predicate = KnowledgePredicate(rawValue: row.predicateRaw), let modality = KnowledgeModality(rawValue: row.modalityRaw),
              let polarity = KnowledgePolarity(rawValue: row.polarityRaw), let kind = KnowledgeClaimKind(rawValue: row.claimKindRaw),
              let confidence = KnowledgeConfidenceBand(rawValue: row.confidenceBandRaw) else { throw KnowledgeWikiStoreError.invalidCanonical }
        let evidence = try evidence(row, origin: origin, source: source, in: context)
        guard !evidence.isEmpty else { return nil }
        return KnowledgeWikiSnapshot.Fact(id: row.id, subjectID: row.subjectEntityID, predicate: predicate, objectID: row.objectEntityID,
            value: try row.valueData.map { try KnowledgeEntityResolutionRows.decode(KnowledgeTypedValue.self, $0) },
            qualifiers: .init(modality: modality, polarity: polarity, claimKind: kind, authority: authority, confidence: confidence, review: review,
                validFrom: try temporal(row.validFromText, precision: row.validFromPrecisionRaw),
                validTo: try temporal(row.validToText, precision: row.validToPrecisionRaw)),
            source: .init(meetingID: row.sourceMeetingID, recordedAt: row.recordedAt, evidence: evidence))
    }

    private static func temporal(_ text: String?, precision: String?) throws -> KnowledgeTemporalValue? {
        if text == nil, precision == nil { return nil }
        guard let text, let precision, let parsed = KnowledgeTemporalPrecision(rawValue: precision),
              let date = KnowledgeTemporalValue(text: text, precision: parsed) else { throw KnowledgeWikiStoreError.invalidCanonical }
        return date
    }

    private static func evidence(_ assertion: KnowledgeAssertion, origin: KnowledgeWikiSourceRows.Origin,
                                 source: KnowledgeStoreSnapshot, in context: ModelContext) throws -> [KnowledgeWikiSnapshot.Evidence] {
        let assertionID = assertion.id
        var descriptor = FetchDescriptor<KnowledgeEvidence>(predicate: #Predicate { $0.assertionID == assertionID && $0.isAvailable },
            sortBy: [SortDescriptor(\KnowledgeEvidence.startMs), SortDescriptor(\KnowledgeEvidence.endMs)])
        descriptor.fetchLimit = KnowledgeWikiProjector.evidenceLimit + 1
        let rows = try context.fetch(descriptor)
        guard rows.count <= KnowledgeWikiProjector.evidenceLimit else { throw KnowledgeWikiProjectionError.projectionLimit }
        guard let recording = source.recordings.first(where: { $0.id == origin.recordingID }),
              recording.fingerprint == origin.fingerprint else { return [] }
        let revision = try KnowledgeTranscriptRevision(segments: recording.segments, language: recording.language)
        let speaker = recording.segments.first { $0.id.uuidString.lowercased() == origin.attribution }?.speakerLabel
        guard let speaker else { throw KnowledgeWikiStoreError.invalidCanonical }
        let result = try rows.sorted {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
            return $0.id.uuidString < $1.id.uuidString
        }.map { row in
            guard row.meetingID == source.meetingID, row.recordingID == origin.recordingID,
                  row.transcriptFingerprint == origin.fingerprint else { throw KnowledgeWikiStoreError.invalidCanonical }
            let anchors = try KnowledgeEntityResolutionRows.decode([String].self, row.segmentIDsData)
            let claim = KnowledgeEvidenceClaim(segmentIDs: anchors, quote: row.quote, startMs: row.startMs, endMs: row.endMs)
            guard let checked = revision.resolve(claim, transcriptFingerprint: row.transcriptFingerprint),
                  row.quoteHash == KnowledgeStoreRows.digest(Data(checked.normalizedQuote.utf8)) else {
                throw KnowledgeWikiStoreError.invalidCanonical
            }
            return KnowledgeWikiSnapshot.Evidence(id: row.id, recordingID: origin.recordingID, segmentIDs: anchors,
                quote: row.quote, startMs: row.startMs, endMs: row.endMs, attributedSpeaker: speaker)
        }
        // The attribution anchor belongs to the assertion's combined evidence,
        // not necessarily every citation (the extraction contract permits this).
        return result.contains { $0.segmentIDs.contains(origin.attribution) } ? result : []
    }
}
