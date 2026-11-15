import Foundation
import KurnCore
import SwiftData

extension KnowledgeStoreRows {
    static func authoritativeData<Value: Encodable>(_ value: Value) throws -> Data {
        guard let data = JSONStorage.encodeAuthoritative(value) else { throw KnowledgeStoreError.invalidCompilation }
        return data
    }

    // swiftlint:disable:next function_parameter_count
    static func insert(
        _ recordings: [ValidatedRecording], snapshot: KnowledgeStoreSnapshot, revisionID: UUID,
        extractorVersion: String, at now: Date, in context: ModelContext
    ) throws -> KnowledgeCommitProvenance {
        var provenance = KnowledgeCommitProvenance(recordings: [])
        for item in recordings {
            var passes: [KnowledgeCommitProvenance.Pass] = []
            for document in item.documents {
                // No automatic linking (especially people). K1.7 will replace
                // this conservative allocation with reviewed entity resolution.
                let entities = Dictionary(uniqueKeysWithValues: document.entities.map { ($0.ref, UUID()) })
                let assertions = Dictionary(uniqueKeysWithValues: document.assertions.map { ($0.ref, UUID()) })
                let events = Dictionary(uniqueKeysWithValues: document.events.map { ($0.ref, UUID()) })
                for entity in document.entities {
                    guard let id = entities[entity.ref] else { throw KnowledgeStoreError.invalidCompilation }
                    let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    context.insert(KnowledgeEntity(id: id, kind: entity.kind, canonicalName: name, normalizedName: normalized,
                        aliasesData: try authoritativeData(entity.aliases), createdAt: now))
                }
                var attribution: [String: String] = [:]
                let validator = KnowledgeEvidenceValidator(segments: try KnowledgeTranscriptSnapshot(
                    segments: item.source.segments, language: item.source.language).sourceSegments)
                for assertion in document.assertions {
                    guard let id = assertions[assertion.ref], let subjectID = entities[assertion.subject] else {
                        throw KnowledgeStoreError.invalidCompilation
                    }
                    let objectID = assertion.object.flatMap { entities[$0] }
                    let value = try assertion.value.map { try authoritativeData($0) }
                    context.insert(KnowledgeAssertion(id: id, subjectEntityID: subjectID, predicate: assertion.predicate,
                        objectEntityID: objectID, valueData: value, modality: assertion.modality, polarity: assertion.polarity,
                        claimKind: assertion.claimKind, authorityStatus: assertion.authorityStatus, confidenceBand: assertion.confidence,
                        validFrom: assertion.validFrom?.parsed, validTo: assertion.validTo?.parsed, recordedAt: now,
                        sourceMeetingID: snapshot.meetingID, contextID: snapshot.contextID, revisionID: revisionID, extractorVersion: extractorVersion))
                    attribution[id.uuidString.lowercased()] = assertion.attributedToSegmentID
                    for citation in assertion.evidence {
                        let checked = try validator.validate(citation.claim).get()
                        context.insert(KnowledgeEvidence(assertionID: id, meetingID: snapshot.meetingID, recordingID: item.source.id,
                            transcriptFingerprint: item.compilation.transcriptFingerprint,
                            segmentIDsData: try authoritativeData(checked.segmentIDs), quote: citation.quote,
                            quoteHash: digest(Data(checked.normalizedQuote.utf8)), startMs: checked.startMs, endMs: checked.endMs, createdAt: now))
                    }
                    if let objectID {
                        context.insert(KnowledgeRelation(subjectEntityID: subjectID, predicate: assertion.predicate, objectEntityID: objectID,
                            assertionID: id, isInferred: assertion.modality == .inferred, revisionID: revisionID))
                    }
                }
                for event in document.events {
                    guard let id = events[event.ref], let entityID = entities[event.entity], let assertionID = assertions[event.assertion] else {
                        throw KnowledgeStoreError.invalidCompilation
                    }
                    context.insert(KnowledgeEvent(id: id, entityID: entityID, kind: event.kind, assertionID: assertionID,
                        occurredAt: event.occurredAt?.parsed, recordedAt: now, sourceMeetingID: snapshot.meetingID,
                        contextID: snapshot.contextID, revisionID: revisionID))
                }
                passes.append(KnowledgeCommitProvenance.Pass(entityIDs: entities, assertionIDs: assertions,
                    eventIDs: events, attributionAnchors: attribution))
            }
            provenance.recordings.append(KnowledgeCommitProvenance.Recording(recordingID: item.source.id,
                transcriptFingerprint: item.compilation.transcriptFingerprint, strategy: item.compilation.strategy,
                targetedPassCount: item.compilation.targetedPassCount, passes: passes))
        }
        return provenance
    }
}
