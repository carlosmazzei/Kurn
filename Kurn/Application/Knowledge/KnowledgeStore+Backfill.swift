import Foundation
import KurnCore
import SwiftData

extension KnowledgeStore {
    /// Read-only, local preview. No enqueue, model call or projection write.
    func backfillRead(meetingIDs: Set<UUID>, model: String,
                      authorization: @Sendable () async -> KnowledgeSourceAuthorization) async throws -> KnowledgeBackfillRead {
        let auth = await authorization()
        try Task.checkCancellation()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: meetingIDs, scope: "workspace", auth: auth, operation: .extraction, in: context)
        var result: [KnowledgeBackfillRead.Source] = []
        var bytes = 0
        for source in sources {
            try Task.checkCancellation()
            let id = source.meetingID
            guard let meeting = try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first,
                  meeting.title.utf8.count <= 8_192 else { throw KnowledgeSettingsError.unavailable }
            let segments = source.recordings.flatMap(\.segments)
            bytes += segments.reduce(0) { $0 + $1.text.utf8.count }
            guard bytes <= 8_388_608 else { throw KnowledgeSettingsError.limitExceeded }
            var input = KnowledgeMaintenanceInput(revision: 0)
            _ = try KnowledgeMaintenanceRows.compilation(source: source, input: &input, in: context)
            var current = input.isComplete && !segments.isEmpty && !input.coverage.isEmpty
                && input.coverage.allSatisfy { $0.state == .current && $0.examinedSegments == $0.totalSegments }
            do { _ = try KnowledgeWikiSourceRows.snapshot(sources: [source], in: context) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if KnowledgeMaintenanceRows.isFuture(error) { throw error }
                current = false
            }
            let work = try KnowledgeQueuedWork.extraction(snapshot: source, provider: .appleOnDevice, model: model)
            let key = work.key
            let previous = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.idempotencyKey == key })).first
            let rebuild = !current && [KnowledgeJobState.succeeded.rawValue, KnowledgeJobState.cancelled.rawValue].contains(previous?.stateRaw ?? "")
            result.append(.init(id: id, title: meeting.title, fingerprint: source.transcriptFingerprint, segments: segments.count,
                characters: segments.reduce(0) { $0 + $1.text.count }, isCurrent: current, requiresRebuild: rebuild))
        }
        return KnowledgeBackfillRead(policyRevisionKey: KnowledgePolicyEvaluator.revisionKey(auth.policies), sources: result)
    }
}
