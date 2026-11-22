import Foundation
import KurnCore
import SwiftData

enum KnowledgeMaintenanceRows {
    static let historyLimit = 4_096

    static func decode<Value: Decodable>(_ type: Value.Type, _ bytes: Data?) throws -> Value {
        let result = JSONStorage.decodeAuthoritative(type, from: bytes ?? Data())
        if case .unsupportedVersion = result { throw KnowledgeMaintenanceError.unsupportedArtifact }
        guard let value = result.decodedValue else { throw KnowledgeMaintenanceError.invalidInput }
        return value
    }

    static func isFuture(_ error: Error) -> Bool {
        (error as? KnowledgeMaintenanceError) == .unsupportedArtifact
            || (error as? KnowledgeEntityStoreError) == .unsupportedPayload
            || (error as? KnowledgeWikiStoreError) == .unsupportedProjection
            || (error as? KnowledgeWikiProjectionError) == .unsupportedNarrative
            || (error as? KnowledgeStoreError) == .unsupportedProvenanceVersion
    }

    struct Compilation {
        let job: KnowledgeJob
        let identity: KnowledgeCompilationIdentity
        let revision: KnowledgeRevision
    }

    static func latest(source: KnowledgeStoreSnapshot, in context: ModelContext) throws -> Compilation? {
        let meetingID = source.meetingID
        let kind = KnowledgeJobKind.extraction.rawValue
        let succeeded = KnowledgeJobState.succeeded.rawValue
        var descriptor = FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
            $0.meetingID == meetingID && $0.kindRaw == kind && $0.stateRaw == succeeded
        })
        descriptor.fetchLimit = historyLimit + 1
        let jobs = try context.fetch(descriptor)
        guard jobs.count <= historyLimit else { throw KnowledgeMaintenanceError.limitExceeded }
        var latest: Compilation?
        for job in jobs {
            try Task.checkCancellation()
            guard let identity = KnowledgeCompilationIdentity(idempotencyKey: job.idempotencyKey) else {
                throw KnowledgeMaintenanceError.unsupportedArtifact
            }
            guard identity.scope == source.scope else { continue }
            guard identity.schemaVersion == 1 else { throw KnowledgeMaintenanceError.unsupportedArtifact }
            let id = job.id
            let revisions = try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.jobID == id }))
            guard revisions.count == 1, let revision = revisions.first,
                  identity.meetingID == source.meetingID, identity.extractorVersion == job.pipelineVersion else {
                throw KnowledgeMaintenanceError.invalidInput
            }
            if revision.number > (latest?.revision.number ?? 0) { latest = Compilation(job: job, identity: identity, revision: revision) }
        }
        return latest
    }

    static func compilation(source: KnowledgeStoreSnapshot, input: inout KnowledgeMaintenanceInput,
                            in context: ModelContext) throws -> Set<UUID> {
        do {
            guard let latest = try latest(source: source, in: context) else {
                addCoverage(source, state: .missingCompilation, to: &input)
                return []
            }
            guard latest.revision.policyRevisionKey == source.policyRevisionKey else {
                addCoverage(source, state: .policyChanged, to: &input)
                return []
            }
            guard latest.identity.transcriptFingerprint == source.transcriptFingerprint else {
                addCoverage(source, state: .sourceChanged, to: &input)
                return []
            }
            let provenance = try decode(KnowledgeCommitProvenance.self, latest.job.checkpointData)
            let coverage = try decode([KnowledgeCommitProvenance.Coverage].self, latest.job.coverageData)
            let recordings = source.recordings.filter { $0.transcriptID != nil && !$0.segments.isEmpty }
            guard Set(provenance.recordings.map(\.recordingID)) == Set(recordings.map(\.id)),
                  Set(provenance.recordings.map(\.recordingID)).count == provenance.recordings.count,
                  Set(coverage.map(\.recordingID)).count == coverage.count,
                  Set(coverage.map(\.recordingID)).isSubset(of: Set(recordings.map(\.id))) else { throw KnowledgeMaintenanceError.invalidInput }
            for recording in provenance.recordings {
                guard recording.transcriptFingerprint == recordings.first(where: { $0.id == recording.recordingID })?.fingerprint,
                      !recording.passes.isEmpty else { throw KnowledgeMaintenanceError.invalidInput }
            }
            for recording in source.recordings {
                let anchors = Set(recording.segments.map { $0.id.uuidString.lowercased() })
                let examined = coverage.first { $0.recordingID == recording.id }?.examinedSegmentIDs ?? []
                let valid = Set(examined).count == examined.count && Set(examined).isSubset(of: anchors)
                input.coverage.append(.init(recordingID: recording.id, totalSegments: anchors.count,
                    examinedSegments: valid ? examined.count : 0,
                    state: recording.transcriptID == nil ? .transcriptMissing : (valid ? .current : .unreadable)))
                if !valid { input.isComplete = false }
            }
            return Set(provenance.recordings.flatMap { $0.passes.flatMap { $0.entityIDs.values } })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isFuture(error) { throw KnowledgeMaintenanceError.unsupportedArtifact }
            if (error as? KnowledgeMaintenanceError) == .limitExceeded { throw error }
            input.isComplete = false
            input.findings.append(.init(code: .artifactUnreadable, subjects: [.init(.meeting, source.meetingID)]))
            addCoverage(source, state: .unreadable, to: &input)
            return []
        }
    }

    private static func addCoverage(_ source: KnowledgeStoreSnapshot, state: KnowledgeMaintenanceCoverage.State,
                                    to input: inout KnowledgeMaintenanceInput) {
        input.coverage += source.recordings.map {
            .init(recordingID: $0.id, totalSegments: $0.segments.count, examinedSegments: 0,
                state: $0.transcriptID == nil ? .transcriptMissing : state)
        }
    }
}
