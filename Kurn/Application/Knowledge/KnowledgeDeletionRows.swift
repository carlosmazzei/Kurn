import Foundation
import KurnCore
import SwiftData

/// What a deletion tombstone removes. Raw values are persisted in
/// `KnowledgeJob.strategyRaw` and never change once shipped.
enum KnowledgeDeletionScope: String, Sendable {
    /// The meeting is gone: every canonical row it supported, its context link
    /// and every cache that names it.
    case meeting
    /// One of its recordings is gone. Passes are per recording but provenance
    /// and entity origins are per compilation, so everything compiled from the
    /// meeting is removed; it can be recompiled from what remains.
    case source
    /// "Delete Knowledge": the whole canonical corpus, keeping meetings, their
    /// episodic wiki articles and the context configuration.
    case corpus
}

struct KnowledgeDeletionReceipt: Equatable, Sendable {
    let scope: KnowledgeDeletionScope
    let meetingID: UUID?
    let revision: Int
}

/// A tombstone is a `.deletion` job committed in the SAME save as the source
/// deletion, so a process death between the two cannot leave canonical rows
/// that quote a deleted transcript. The purge is one transaction per
/// tombstone: canonical rows, caches, the revision bump and the tombstone's
/// own removal commit together, and a death before that save replays it.
/// See CLAUDE.md "Knowledge deletion (K2.8)".
enum KnowledgeDeletionRows {
    static let pipeline = "knowledge-deletion-v1"

    static func key(_ scope: KnowledgeDeletionScope, meetingID: UUID?) -> String {
        "knowledge.deletion.v1:\(scope.rawValue):\(meetingID?.uuidString.lowercased() ?? UUID().uuidString.lowercased())"
    }

    /// Unsaved tombstones for the sources that have none yet, for the caller to
    /// insert into the transaction that deletes the sources.
    static func tombstones(for meetingIDs: Set<UUID>, scope: KnowledgeDeletionScope, in context: ModelContext) throws -> [KnowledgeJob] {
        precondition(scope != .corpus)
        let kind = KnowledgeJobKind.deletion.rawValue
        let pending = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == kind }))
        return meetingIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let key = key(scope, meetingID: id)
            guard !pending.contains(where: { $0.idempotencyKey == key }) else { return nil }
            return tombstone(scope, meetingID: id)
        }
    }

    static func tombstone(_ scope: KnowledgeDeletionScope, meetingID: UUID?) -> KnowledgeJob {
        let job = KnowledgeJob(idempotencyKey: key(scope, meetingID: meetingID), kind: .deletion,
            meetingID: meetingID, pipelineVersion: pipeline)
        job.strategyRaw = scope.rawValue
        return job
    }

    static func pendingCount(in context: ModelContext) throws -> Int {
        let kind = KnowledgeJobKind.deletion.rawValue
        return try context.fetchCount(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == kind }))
    }

    /// Purges the oldest tombstone. Returns nil when none is left.
    static func purgeNext(container: ModelContainer, beforeSave: () throws -> Void) throws -> KnowledgeDeletionReceipt? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let kind = KnowledgeJobKind.deletion.rawValue
        var descriptor = FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == kind },
            sortBy: [SortDescriptor(\KnowledgeJob.createdAt), SortDescriptor(\KnowledgeJob.idempotencyKey)])
        descriptor.fetchLimit = 1
        guard let tombstone = try context.fetch(descriptor).first else { return nil }
        guard tombstone.pipelineVersion == pipeline, let scope = tombstone.strategyRaw.flatMap(KnowledgeDeletionScope.init(rawValue:)),
              (scope == .corpus) == (tombstone.meetingID == nil) else { throw KnowledgeStoreError.invalidJob }
        var purge = Purge(context: context)
        if let meetingID = tombstone.meetingID {
            try purge.meeting(meetingID, unlinkContext: scope == .meeting)
        } else {
            try purge.corpus()
        }
        let revision = try KnowledgeStoreRows.latestRevision(in: context) + 1
        // Every canonical read and cache compares this number: the bump makes
        // each page/search/review snapshot taken before the purge stale.
        let bump = KnowledgeRevision(number: revision, policyRevisionKey: pipeline, assertionCount: 0)
        bump.projectionPending = false
        context.insert(bump)
        context.delete(tombstone)
        try beforeSave()
        try context.save()
        return KnowledgeDeletionReceipt(scope: scope, meetingID: tombstone.meetingID, revision: revision)
    }

    private struct Purge {
        let context: ModelContext
        var deletedJobIDs: Set<UUID> = []
        var settledRevisionIDs: Set<UUID> = []

        init(context: ModelContext) { self.context = context }

        mutating func meeting(_ meetingID: UUID, unlinkContext: Bool) throws {
            let extraction = KnowledgeJobKind.extraction.rawValue
            let jobs = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
                $0.meetingID == meetingID && $0.kindRaw == extraction
            }))
            // Unreadable provenance cannot name its entities; the assertions
            // and events below still do, and the job itself is removed.
            var candidates = Set(jobs.flatMap { job -> [UUID] in
                guard job.stateRaw == KnowledgeJobState.succeeded.rawValue, let bytes = job.checkpointData,
                      let provenance = try? KnowledgeEntityResolutionRows.decode(KnowledgeCommitProvenance.self, bytes) else { return [] }
                return provenance.recordings.flatMap { $0.passes.flatMap { Array($0.entityIDs.values) } }
            })
            let assertions = try context.fetch(FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate { $0.sourceMeetingID == meetingID }))
            let assertionIDs = Set(assertions.map(\.id))
            candidates.formUnion(assertions.map(\.subjectEntityID))
            candidates.formUnion(assertions.compactMap(\.objectEntityID))
            let events = try context.fetch(FetchDescriptor<KnowledgeEvent>(predicate: #Predicate { $0.sourceMeetingID == meetingID }))
            candidates.formUnion(events.map(\.entityID))
            let eventIDs = Set(events.map(\.id))
            let evidence = try context.fetch(FetchDescriptor<KnowledgeEvidence>(predicate: #Predicate { $0.meetingID == meetingID }))
            let assertionList = Array(assertionIDs)
            let relations = try context.fetch(FetchDescriptor<KnowledgeRelation>(predicate: #Predicate { assertionList.contains($0.assertionID) }))
            // Another source's claim keeps an entity alive; only what nothing
            // else supports is exclusive to this one.
            let candidateList = Array(candidates)
            var otherAssertions = try context.fetch(FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate {
                candidateList.contains($0.subjectEntityID)
            }))
            for id in candidateList {
                otherAssertions += try context.fetch(FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate { $0.objectEntityID == id }))
            }
            otherAssertions.removeAll { assertionIDs.contains($0.id) }
            let otherEvents = try context.fetch(FetchDescriptor<KnowledgeEvent>(predicate: #Predicate { candidateList.contains($0.entityID) }))
                .filter { !eventIDs.contains($0.id) }
            var exclusive = candidates
            exclusive.subtract(otherAssertions.map(\.subjectEntityID))
            exclusive.subtract(otherAssertions.compactMap(\.objectEntityID))
            exclusive.subtract(otherEvents.map(\.entityID))

            for row in assertions { context.delete(row) }
            for row in events { context.delete(row) }
            for row in evidence { context.delete(row) }
            for row in relations { context.delete(row) }
            for job in jobs { deletedJobIDs.insert(job.id); context.delete(job) }
            try entities(exclusive)
            try reviews(entities: exclusive, meetingID: meetingID)
            try projections(meetingID: meetingID)
            if unlinkContext {
                let links = try context.fetch(FetchDescriptor<SourceContextLink>(predicate: #Predicate { $0.meetingID == meetingID }))
                for row in links { context.delete(row) }
            }
            try settleRevisions()
        }

        mutating func corpus() throws {
            for row in try context.fetch(FetchDescriptor<KnowledgeEntity>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<KnowledgeAssertion>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<KnowledgeEvidence>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<KnowledgeEvent>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<KnowledgeRelation>()) { context.delete(row) }
            for row in try context.fetch(FetchDescriptor<KnowledgeReview>()) { context.delete(row) }
            // The episodic article queue and the context configuration are not
            // canonical knowledge; every other job is. Other tombstones stay:
            // a deleted meeting's context link is removed only by its own purge.
            let article = KnowledgeJobKind.meetingArticle.rawValue
            let deletion = KnowledgeJobKind.deletion.rawValue
            let jobs = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate {
                $0.kindRaw != article && $0.kindRaw != deletion
            }))
            for job in jobs {
                deletedJobIDs.insert(job.id)
                context.delete(job)
            }
            for revision in try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.projectionPending })) {
                revision.projectionPending = false
            }
        }

        private func entities(_ ids: Set<UUID>) throws {
            guard !ids.isEmpty else { return }
            let list = Array(ids)
            for row in try context.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { list.contains($0.id) })) { context.delete(row) }
            // A surviving identity merged into a removed one stands alone again;
            // its own name, aliases and claims are untouched.
            for id in list {
                let members = try context.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { $0.mergedIntoID == id }))
                for member in members where !ids.contains(member.id) {
                    member.mergedIntoID = nil
                    member.updatedAt = Date()
                }
            }
        }

        /// Identity candidates and merge audits name the identities they join
        /// and the sources they were proven against.
        private mutating func reviews(entities: Set<UUID>, meetingID: UUID) throws {
            for row in try context.fetch(FetchDescriptor<KnowledgeReview>()) {
                let subjects = (try? KnowledgeEntityResolutionRows.decode([UUID].self, row.subjectIDsData)) ?? []
                let payload = try? KnowledgeEntityResolutionRows.reviewPayload(row)
                var names = !entities.isDisjoint(with: subjects)
                if let candidate = payload?.candidate, candidate.source.meetingID == meetingID { names = true }
                if let merge = payload?.merge {
                    if merge.sources.contains(where: { $0.meetingID == meetingID })
                        || merge.origins.contains(where: { $0.meetingID == meetingID }) { names = true }
                    if names {
                        settledRevisionIDs.insert(merge.applied.revisionID)
                        if let undone = merge.undone { settledRevisionIDs.insert(undone.revisionID) }
                    }
                }
                if names { context.delete(row) }
            }
        }

        /// Pages are rebuildable caches. One that cannot be read cannot prove
        /// it excludes the source, so it goes too.
        private mutating func projections(meetingID: UUID) throws {
            let kind = KnowledgeJobKind.projection.rawValue
            for job in try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == kind })) {
                let sources = (try? KnowledgeWikiProjectionRows.envelope(job))?.sources.map(\.meetingID)
                guard sources?.contains(meetingID) ?? true else { continue }
                deletedJobIDs.insert(job.id)
                context.delete(job)
            }
        }

        /// A revision whose job or audit is gone can never be acknowledged by
        /// a publication; leaving it pending would block the outbox forever.
        private func settleRevisions() throws {
            for revision in try context.fetch(FetchDescriptor<KnowledgeRevision>(predicate: #Predicate { $0.projectionPending })) {
                if revision.jobID.map(deletedJobIDs.contains) ?? false || settledRevisionIDs.contains(revision.id) {
                    revision.projectionPending = false
                }
            }
        }
    }
}
