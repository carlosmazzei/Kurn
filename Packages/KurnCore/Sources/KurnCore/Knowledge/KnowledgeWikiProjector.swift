import Foundation

public struct KnowledgeWikiPage: Codable, Equatable, Sendable {
    public let entity: KnowledgeWikiSnapshot.Entity
    public let revision: Int
    public let sections: [Section]
    public let narrative: KnowledgeWikiNarrative?

    public struct Section: Codable, Equatable, Sendable {
        public let kind: Kind
        public let entries: [Entry]
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case claims, decisions, actions, risks, questions, metrics
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let fact: KnowledgeWikiSnapshot.Fact
        public let subject: KnowledgeWikiSnapshot.Entity
        public let object: KnowledgeWikiSnapshot.Entity?
    }

    public var markdown: String { KnowledgeWikiMarkdown.render(self) }
}

/// No temporal reduction or last-mention-wins: every supported, visible claim
/// retains its attribution, polarity, modality and both time dimensions.
public enum KnowledgeWikiProjector {
    public static let entityLimit = 2_048
    public static let factLimit = 4_096
    public static let evidenceLimit = 16_384

    public static func project(_ snapshot: KnowledgeWikiSnapshot,
                               narratives: [KnowledgeWikiNarrative] = []) throws -> [KnowledgeWikiPage] {
        guard snapshot.entities.count <= entityLimit, snapshot.facts.count <= factLimit,
              snapshot.facts.reduce(0, { $0 + $1.source.evidence.count }) <= evidenceLimit else {
            throw KnowledgeWikiProjectionError.projectionLimit
        }
        guard snapshot.revision >= 0, Set(snapshot.entities.map(\.id)).count == snapshot.entities.count,
              Set(snapshot.facts.map(\.id)).count == snapshot.facts.count else { throw KnowledgeWikiProjectionError.invalidSnapshot }
        let entities = Dictionary(uniqueKeysWithValues: snapshot.entities.map { ($0.id, $0) })
        let nodes = entities.mapValues { KnowledgeEntityRedirect(id: $0.id, kind: $0.kind, targetID: $0.targetID) }
        var roots: [UUID: UUID] = [:]
        for entity in snapshot.entities {
            guard !entity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KnowledgeWikiProjectionError.invalidSnapshot }
            roots[entity.id] = try KnowledgeEntityRedirectGraph.resolve(entity.id, nodes: nodes)
        }
        var entries: [UUID: [KnowledgeWikiPage.Entry]] = [:]
        var evidenceIDs: Set<UUID> = []
        for fact in snapshot.facts {
            try validate(fact, entities: entities, evidenceIDs: &evidenceIDs)
            guard let subjectID = roots[fact.subjectID], let subject = entities[subjectID] else {
                throw KnowledgeWikiProjectionError.invalidSnapshot
            }
            let object = fact.objectID.flatMap { roots[$0] }.flatMap { entities[$0] }
            let entry = KnowledgeWikiPage.Entry(fact: fact, subject: subject, object: object)
            entries[subjectID, default: []].append(entry)
            if let object, object.id != subjectID { entries[object.id, default: []].append(entry) }
        }
        guard narratives.count <= entries.count, Set(narratives.map(\.entityID)).count == narratives.count else {
            throw KnowledgeWikiProjectionError.invalidNarrative
        }
        let byEntity = Dictionary(uniqueKeysWithValues: narratives.map { ($0.entityID, $0) })
        guard Set(byEntity.keys).isSubset(of: Set(entries.keys)) else { throw KnowledgeWikiProjectionError.invalidNarrative }
        return try entries.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
            guard let root = entities[id] else { throw KnowledgeWikiProjectionError.invalidSnapshot }
            let aliases = Set(snapshot.entities.filter { roots[$0.id] == id }.flatMap { $0.aliases + [$0.name] }).subtracting([root.name])
            let entity = KnowledgeWikiSnapshot.Entity(id: id, kind: root.kind, name: root.name, aliases: aliases.sorted())
            let ordered = (entries[id] ?? []).sorted {
                if $0.fact.source.recordedAt != $1.fact.source.recordedAt { return $0.fact.source.recordedAt < $1.fact.source.recordedAt }
                return $0.fact.id.uuidString < $1.fact.id.uuidString
            }
            let sections = KnowledgeWikiPage.Kind.allCases.compactMap { kind -> KnowledgeWikiPage.Section? in
                let selected = ordered.filter { section($0) == kind }
                return selected.isEmpty ? nil : KnowledgeWikiPage.Section(kind: kind, entries: selected)
            }
            if let narrative = byEntity[id] { try validate(narrative, assertionIDs: Set(ordered.map { $0.fact.id })) }
            return KnowledgeWikiPage(entity: entity, revision: snapshot.revision, sections: sections, narrative: byEntity[id])
        }
    }

    private static func validate(_ fact: KnowledgeWikiSnapshot.Fact, entities: [UUID: KnowledgeWikiSnapshot.Entity],
                                 evidenceIDs: inout Set<UUID>) throws {
        guard let subject = entities[fact.subjectID], fact.objectID.map({ entities[$0] != nil }) ?? true,
              fact.predicate.violation(subjectKind: subject.kind, objectKind: fact.objectID.flatMap { entities[$0]?.kind }, value: fact.value) == nil,
              fact.qualifiers.review.isVisible, fact.qualifiers.authority != .rejected, !fact.source.evidence.isEmpty,
              fact.source.recordedAt.timeIntervalSince1970.isFinite else { throw KnowledgeWikiProjectionError.invalidSnapshot }
        for evidence in fact.source.evidence {
            guard evidenceIDs.insert(evidence.id).inserted, !evidence.segmentIDs.isEmpty,
                  Set(evidence.segmentIDs).count == evidence.segmentIDs.count, !evidence.quote.isEmpty,
                  !evidence.attributedSpeaker.isEmpty, evidence.startMs >= 0, evidence.endMs > evidence.startMs else {
                throw KnowledgeWikiProjectionError.invalidSnapshot
            }
        }
    }

    private static func validate(_ narrative: KnowledgeWikiNarrative, assertionIDs: Set<UUID>) throws {
        guard narrative.version == 1 else { throw KnowledgeWikiProjectionError.unsupportedNarrative }
        guard !narrative.paragraphs.isEmpty, narrative.paragraphs.count <= 32,
              narrative.paragraphs.reduce(0, { $0 + $1.text.utf8.count }) <= 16_384 else { throw KnowledgeWikiProjectionError.invalidNarrative }
        for paragraph in narrative.paragraphs {
            guard !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, paragraph.text.utf8.count <= 2_048,
                  !paragraph.assertionIDs.isEmpty, paragraph.assertionIDs.count <= 16,
                  Set(paragraph.assertionIDs).count == paragraph.assertionIDs.count,
                  Set(paragraph.assertionIDs).isSubset(of: assertionIDs) else { throw KnowledgeWikiProjectionError.invalidNarrative }
        }
    }

    /// The section a projected entry belongs to — also the grouping the
    /// meeting Knowledge tab presents, so it stays public and shared.
    public static func section(_ entry: KnowledgeWikiPage.Entry) -> KnowledgeWikiPage.Kind {
        switch entry.subject.kind {
        case .decisionThread: .decisions
        case .actionItem: .actions
        case .risk: .risks
        case .question: .questions
        case .metric: .metrics
        default: entry.fact.qualifiers.claimKind == .internalDecision ? .decisions : .claims
        }
    }
}
