import Foundation
import KurnCore
import SwiftData

enum KnowledgeMaintenanceProjectionRows {
    static func inspect(sources: [KnowledgeStoreSnapshot], wiki: KnowledgeWikiSnapshot?,
                        input: inout KnowledgeMaintenanceInput, in context: ModelContext) throws {
        guard let first = sources.first else { throw KnowledgeMaintenanceError.invalidInput }
        let key = try KnowledgeWikiProjectionRows.key(scope: first.scope, meetingIDs: Set(sources.map(\.meetingID)))
        guard let row = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.idempotencyKey == key })).first else { return }
        do {
            let stored = try KnowledgeWikiProjectionRows.envelope(row)
            guard stored.sources == KnowledgeEntityResolutionRows.tokens(sources), stored.policyRevisionKey == first.policyRevisionKey,
                  stored.snapshot.revision == input.revision else {
                input.projection = .stale
                return // No old-policy or excluded-source identifiers/counts.
            }
            guard stored.pages.compactMap(\.narrative).allSatisfy({ $0.version == 1 }) else {
                throw KnowledgeMaintenanceError.unsupportedArtifact
            }
            guard let wiki else { input.projection = .unreadable; return }
            let expected = try KnowledgeWikiProjector.project(wiki)
            let byID = Dictionary(uniqueKeysWithValues: expected.map { ($0.entity.id, $0) })
            guard stored.pages.count <= KnowledgeWikiProjector.entityLimit,
                  Set(stored.pages.map { $0.entity.id }).count == stored.pages.count else { throw KnowledgeMaintenanceError.invalidInput }
            input.projection = .current
            for page in stored.pages {
                let entries = page.sections.flatMap(\.entries)
                var descriptor = KnowledgeMaintenanceInput.Page(entityID: page.entity.id, revision: page.revision)
                descriptor.entityLinks = Set(entries.flatMap { [$0.subject.id] + ($0.object.map { [$0.id] } ?? []) })
                descriptor.evidenceLinks = Set(entries.flatMap { $0.fact.source.evidence.map(\.id) })
                descriptor.assertionIDs = Set(entries.map { $0.fact.id })
                descriptor.narrativeAssertionIDs = Set(page.narrative?.paragraphs.flatMap(\.assertionIDs) ?? [])
                descriptor.matchesCanonical = page.entity == byID[page.entity.id]?.entity && page.sections == byID[page.entity.id]?.sections
                input.pages.append(descriptor)
            }
            if Set(byID.keys) != Set(stored.pages.map { $0.entity.id }) || stored.snapshot != wiki {
                input.findings.append(.init(code: .invalidProjection, subjects: []))
            }
            do {
                guard stored.pages.allSatisfy({ $0.narrative == nil || $0.narrative?.entityID == $0.entity.id }) else {
                    throw KnowledgeWikiProjectionError.invalidNarrative
                }
                _ = try KnowledgeWikiProjector.project(wiki, narratives: stored.pages.compactMap(\.narrative))
            } catch {
                if KnowledgeMaintenanceRows.isFuture(error) { throw KnowledgeMaintenanceError.unsupportedArtifact }
                input.findings.append(.init(code: .invalidNarrative, subjects: []))
            }
        } catch {
            if KnowledgeMaintenanceRows.isFuture(error) { throw KnowledgeMaintenanceError.unsupportedArtifact }
            if (error as? KnowledgeWikiProjectionError) == .projectionLimit { throw KnowledgeMaintenanceError.limitExceeded }
            input.projection = .unreadable
            input.isComplete = false
        }
    }

    static func candidates(sources: [KnowledgeStoreSnapshot], wiki: KnowledgeWikiSnapshot, input: inout KnowledgeMaintenanceInput,
                           in context: ModelContext) throws {
        let kind = KnowledgeReviewItemKind.mergeCandidate.rawValue
        let open = KnowledgeReviewItemState.open.rawValue
        var descriptor = FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.kindRaw == kind && $0.stateRaw == open })
        descriptor.fetchLimit = KnowledgeMaintenanceLinter.findingLimit + 1
        let rows = try context.fetch(descriptor)
        guard rows.count <= KnowledgeMaintenanceLinter.findingLimit else { throw KnowledgeMaintenanceError.limitExceeded }
        let entities = Set(input.entities.map(\.id))
        let nodes = Dictionary(uniqueKeysWithValues: wiki.entities.map {
            ($0.id, KnowledgeEntityRedirect(id: $0.id, kind: $0.kind, targetID: $0.targetID))
        })
        var roots: [UUID: UUID] = [:]
        for id in entities {
            if nodes[id] == nil { roots[id] = id } else { roots[id] = try KnowledgeEntityRedirectGraph.resolve(id, nodes: nodes) }
        }
        for row in rows {
            try Task.checkCancellation()
            // An unreadable/unselected subject envelope cannot establish an
            // authorized review or block this scope on another scope's schema.
            guard let subjects = try? KnowledgeMaintenanceRows.decode([UUID].self, row.subjectIDsData),
                  subjects.count == 2, Set(subjects).count == 2, Set(subjects).isSubset(of: entities) else { continue }
            do {
                let payload = try KnowledgeEntityResolutionRows.reviewPayload(row)
                guard let candidate = payload.candidate, payload.resolvedByOperationID == nil,
                      candidate.scope == sources.first?.scope, candidate.policyRevisionKey == sources.first?.policyRevisionKey,
                      let source = sources.first(where: { $0.meetingID == candidate.source.meetingID }),
                      source.transcriptFingerprint == candidate.source.fingerprint,
                      entities.contains(candidate.sourceID), entities.contains(candidate.match.entityID) else { continue }
                guard Set(subjects) == Set([candidate.sourceID, candidate.match.entityID]) else {
                    throw KnowledgeMaintenanceError.invalidInput
                }
                guard let left = roots[candidate.sourceID], let right = roots[candidate.match.entityID], left != right else { continue }
                input.candidates.append(.init(left, right))
            } catch {
                if KnowledgeMaintenanceRows.isFuture(error) { throw KnowledgeMaintenanceError.unsupportedArtifact }
                // The unreadable row cannot establish an authorized identity.
                // Do not return its ID, payload, count or speculative finding.
                throw KnowledgeMaintenanceError.invalidInput
            }
        }
    }
}
