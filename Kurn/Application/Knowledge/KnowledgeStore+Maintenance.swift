import Foundation
import KurnCore
import SwiftData

struct KnowledgeScopedMaintenanceReport: Codable, Equatable, Sendable {
    let scope: String
    let policyRevisionKey: String
    let sources: [KnowledgeEntityResolutionSnapshot.Source]
    let report: KnowledgeMaintenanceReport
}

/// Per meeting, the segments the latest compilation examined in each recording (`get_coverage`):
/// counts and states only, the same measure as the maintenance report's coverage.
struct KnowledgeCoverageRead: Equatable, Sendable {
    struct Meeting: Equatable, Sendable {
        let meetingID: UUID
        let recordings: [KnowledgeMaintenanceCoverage]
        let classification: KnowledgeClassification
    }

    let revision: Int
    /// False when a compilation's coverage could not be read, so its counts are not complete.
    let isComplete: Bool
    let meetings: [Meeting]
    var meetingIDs: Set<UUID> { Set(meetings.map(\.meetingID)) }
    var sourceClassifications: [KnowledgeClassification] { meetings.map(\.classification) }
}

extension KnowledgeStore {
    /// The coverage part of `maintenanceReport` alone, grouped by meeting: no wiki, catalog or
    /// review reads, under the same `.semanticLint` source authorization.
    func coverageRead(meetingIDs: Set<UUID>, scope: String,
                      authorization: @Sendable () async -> KnowledgeSourceAuthorization) async throws -> KnowledgeCoverageRead {
        let auth = await authorization()
        try Task.checkCancellation()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: meetingIDs, scope: scope, auth: auth, operation: .semanticLint, in: context)
        let revision = try KnowledgeStoreRows.latestRevision(in: context)
        var isComplete = true
        var meetings: [KnowledgeCoverageRead.Meeting] = []
        for source in sources {
            var input = KnowledgeMaintenanceInput(revision: revision)
            _ = try KnowledgeMaintenanceRows.compilation(source: source, input: &input, in: context)
            isComplete = isComplete && input.isComplete
            meetings.append(.init(meetingID: source.meetingID, recordings: input.coverage, classification: source.contextClassification))
        }
        try Task.checkCancellation()
        return KnowledgeCoverageRead(revision: revision, isComplete: isComplete, meetings: meetings)
    }

    /// Local deterministic lint only. It neither calls a provider nor changes
    /// canonical data, pages, review state, jobs or outbox acknowledgements.
    func maintenanceReport(meetingIDs: Set<UUID>, scope: String,
                           authorization: @Sendable () async -> KnowledgeSourceAuthorization) async throws -> KnowledgeScopedMaintenanceReport {
        let auth = await authorization()
        try Task.checkCancellation()
        return try KnowledgeMaintenanceReader.read(meetingIDs: meetingIDs, scope: scope, auth: auth, container: modelContainer)
    }
}

private enum KnowledgeMaintenanceReader {
    static func read(meetingIDs: Set<UUID>, scope: String, auth: KnowledgeSourceAuthorization,
                     container: ModelContainer) throws -> KnowledgeScopedMaintenanceReport {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sources = try KnowledgeWikiSourceRows.sources(meetingIDs: meetingIDs, scope: scope, auth: auth, operation: .semanticLint, in: context)
        var input = KnowledgeMaintenanceInput(revision: try KnowledgeStoreRows.latestRevision(in: context))
        var currentEntityIDs: Set<UUID> = []
        for source in sources { currentEntityIDs.formUnion(try KnowledgeMaintenanceRows.compilation(source: source, input: &input, in: context)) }
        guard currentEntityIDs.count <= KnowledgeWikiProjector.entityLimit else { throw KnowledgeMaintenanceError.limitExceeded }
        var wiki: KnowledgeWikiSnapshot?
        do {
            wiki = try KnowledgeWikiSourceRows.snapshot(sources: sources, in: context).wiki
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if KnowledgeMaintenanceRows.isFuture(error) { throw KnowledgeMaintenanceError.unsupportedArtifact }
            if (error as? KnowledgeWikiProjectionError) == .projectionLimit { throw KnowledgeMaintenanceError.limitExceeded }
            unavailable(sources: sources, input: &input)
        }
        if let wiki, input.isComplete {
            do {
                try catalog(wiki: wiki, currentIDs: currentEntityIDs, input: &input, in: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if KnowledgeMaintenanceRows.isFuture(error) { throw KnowledgeMaintenanceError.unsupportedArtifact }
                if (error as? KnowledgeMaintenanceError) == .limitExceeded { throw error }
                unavailable(sources: sources, input: &input)
            }
            if input.isComplete {
                try KnowledgeMaintenanceProjectionRows.candidates(sources: sources, wiki: wiki, input: &input, in: context)
            }
        }
        try KnowledgeMaintenanceProjectionRows.inspect(sources: sources, wiki: input.isComplete ? wiki : nil, input: &input, in: context)
        try Task.checkCancellation()
        return KnowledgeScopedMaintenanceReport(scope: scope, policyRevisionKey: KnowledgePolicyEvaluator.revisionKey(auth.policies),
            sources: KnowledgeEntityResolutionRows.tokens(sources), report: try KnowledgeMaintenanceLinter.inspect(input))
    }

    private static func unavailable(sources: [KnowledgeStoreSnapshot], input: inout KnowledgeMaintenanceInput) {
        input.isComplete = false
        input.entities = []
        input.assertionIDs = []
        input.evidenceIDs = []
        input.pages = []
        input.candidates = []
        input.findings.append(.init(code: .canonicalUnavailable, subjects: sources.map { .init(.meeting, $0.meetingID) }))
    }

    private static func catalog(wiki: KnowledgeWikiSnapshot, currentIDs: Set<UUID>,
                                input: inout KnowledgeMaintenanceInput, in context: ModelContext) throws {
        let ids = Array(currentIDs)
        let rows = try context.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { ids.contains($0.id) }))
        guard rows.count == ids.count else { throw KnowledgeMaintenanceError.invalidInput }
        var entities = Dictionary(uniqueKeysWithValues: wiki.entities.map { ($0.id, KnowledgeMaintenanceInput.Entity(id: $0.id, isOrphan: false)) })
        for row in rows {
            guard let review = KnowledgeReviewState(rawValue: row.reviewStateRaw), KnowledgeEntityKind(rawValue: row.kindRaw) != nil else {
                throw KnowledgeMaintenanceError.invalidInput
            }
            if review.isVisible, row.mergedIntoID == nil, entities[row.id] == nil { entities[row.id] = .init(id: row.id, isOrphan: true) }
        }
        input.entities = Array(entities.values)
        input.assertionIDs = Set(wiki.facts.map(\.id))
        input.evidenceIDs = Set(wiki.facts.flatMap { $0.source.evidence.map(\.id) })
    }
}
