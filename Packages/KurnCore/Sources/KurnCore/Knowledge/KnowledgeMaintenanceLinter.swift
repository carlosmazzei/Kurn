import Foundation

/// Read-only rules. Recommendations are descriptions for future human/host
/// workflows, never commands, automatic merges, deletions or model tools.
public enum KnowledgeMaintenanceLinter {
    public static let findingLimit = 8_192

    public static func inspect(_ input: KnowledgeMaintenanceInput) throws -> KnowledgeMaintenanceReport {
        try validate(input)
        let entities = Set(input.entities.map(\.id))
        var findings = input.findings
        for entity in input.entities where entity.isOrphan {
            findings.append(.init(code: .orphanEntity, subjects: [.init(.entity, entity.id)]))
        }
        switch input.projection {
        case .missing where !input.assertionIDs.isEmpty: findings.append(.init(code: .projectionMissing, subjects: []))
        case .stale: findings.append(.init(code: .staleProjection, subjects: []))
        case .unreadable: findings.append(.init(code: .artifactUnreadable, subjects: []))
        default: break
        }
        // Only current projections are inspected in detail. Stale cache IDs
        // and counts may describe sources no longer permitted by the host.
        if input.projection == .current {
            for page in input.pages where entities.contains(page.entityID) {
                let subject = [KnowledgeMaintenanceFinding.Reference(.entity, page.entityID)]
                if page.revision != input.revision { findings.append(.init(code: .staleProjection, subjects: subject)) }
                if !page.entityLinks.isSubset(of: entities) { findings.append(.init(code: .brokenEntityLink, subjects: subject)) }
                if !page.evidenceLinks.isSubset(of: input.evidenceIDs) { findings.append(.init(code: .brokenEvidenceLink, subjects: subject)) }
                if !page.assertionIDs.isSubset(of: input.assertionIDs) || !page.matchesCanonical {
                    findings.append(.init(code: .invalidProjection, subjects: subject))
                }
                if !page.narrativeAssertionIDs.isSubset(of: page.assertionIDs.intersection(input.assertionIDs)) {
                    findings.append(.init(code: .invalidNarrative, subjects: subject))
                }
            }
            if input.pages.contains(where: { !entities.contains($0.entityID) }) {
                findings.append(.init(code: .invalidProjection, subjects: []))
            }
        }
        for candidate in input.candidates where candidate.leftID != candidate.rightID
            && entities.contains(candidate.leftID) && entities.contains(candidate.rightID) {
            findings.append(.init(code: .duplicateCandidate, subjects: [.init(.entity, candidate.leftID), .init(.entity, candidate.rightID)]))
        }
        for item in input.coverage {
            let code: KnowledgeMaintenanceFinding.Code?
            switch item.state {
            case .current: code = item.examinedSegments < item.totalSegments ? .coverageGap : nil
            case .missingCompilation: code = .compilationMissing
            case .sourceChanged: code = .sourceChanged
            case .policyChanged: code = .policyChanged
            case .transcriptMissing: code = .transcriptMissing
            case .unreadable: code = .artifactUnreadable
            }
            if let code { findings.append(.init(code: code, subjects: [.init(.recording, item.recordingID)])) }
        }
        findings = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
        guard findings.count <= findingLimit else { throw KnowledgeMaintenanceError.limitExceeded }
        return KnowledgeMaintenanceReport(version: 1, revision: input.revision, isComplete: input.isComplete,
            coverage: input.coverage.sorted { $0.recordingID.uuidString < $1.recordingID.uuidString }, findings: findings)
    }

    private static func validate(_ input: KnowledgeMaintenanceInput) throws {
        guard input.entities.count <= KnowledgeWikiProjector.entityLimit, input.pages.count <= KnowledgeWikiProjector.entityLimit,
              input.assertionIDs.count <= KnowledgeWikiProjector.factLimit, input.evidenceIDs.count <= KnowledgeWikiProjector.evidenceLimit,
              input.candidates.count <= findingLimit, input.findings.count <= findingLimit, input.coverage.count <= 1_024 else {
            throw KnowledgeMaintenanceError.limitExceeded
        }
        guard input.revision >= 0, Set(input.entities.map(\.id)).count == input.entities.count,
              Set(input.pages.map(\.entityID)).count == input.pages.count,
              Set(input.coverage.map(\.recordingID)).count == input.coverage.count,
              input.coverage.allSatisfy({ $0.totalSegments >= 0 && (0...$0.totalSegments).contains($0.examinedSegments) }) else {
            throw KnowledgeMaintenanceError.invalidInput
        }
    }
}
