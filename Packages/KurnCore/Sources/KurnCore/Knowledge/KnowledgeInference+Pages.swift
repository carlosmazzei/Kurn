//
//  KnowledgeInference+Pages.swift
//  KurnCore
//
//  Derived suggestions over the pages of one authorized read, computed on read.
//

import Foundation

extension KnowledgeInference {
    /// What the derivations suggest about a set of identities. Review-only: nothing here is evidence,
    /// stored or applied.
    public struct Suggestions: Equatable, Sendable {
        public let edges: [DerivedEdge]
        public let commitments: [DerivedCommitment]
        public let sameAs: [SameAsCandidate]
        /// Any derivation hit its bound, so the lists may be incomplete.
        public let isTruncated: Bool
    }

    /// Runs the three derivations over `pages` and keeps what touches `ids` (an edge, a commitment's owner
    /// or action, a candidate's either side). Identities are the ones the pages show, so a merged identity
    /// counts as the one it was merged into. With `now`, commitments read only claims whose stated period is running
    /// then. Deterministic for any page order.
    public static func suggestions(from pages: [KnowledgeWikiPage], touching ids: Set<UUID>, at now: Date? = nil) throws -> Suggestions {
        var entities: [UUID: KnowledgeWikiSnapshot.Entity] = [:]
        var edges: [UUID: KnowledgeGraph.Edge] = [:]
        var facts: [UUID: KnowledgeWikiSnapshot.Fact] = [:]
        for page in pages { entities[page.entity.id] = entities[page.entity.id] ?? page.entity }
        for item in pages.flatMap({ $0.sections.flatMap(\.entries) }) where facts[item.fact.id] == nil {
            let fact = item.fact
            entities[item.subject.id] = entities[item.subject.id] ?? item.subject
            let objectID = item.object?.id ?? fact.objectID
            if let object = item.object {
                entities[object.id] = entities[object.id] ?? object
                edges[fact.id] = KnowledgeGraph.Edge(
                    factID: fact.id, sourceID: item.subject.id, targetID: object.id, predicate: fact.predicate,
                    polarity: fact.qualifiers.polarity, modality: fact.qualifiers.modality,
                    evidenceID: fact.source.evidence.first?.id)
            }
            facts[fact.id] = KnowledgeWikiSnapshot.Fact(
                id: fact.id, subjectID: item.subject.id, predicate: fact.predicate, objectID: objectID,
                value: fact.value, qualifiers: fact.qualifiers, source: fact.source)
        }
        let sorted = edges.values.sorted { $0.factID.uuidString < $1.factID.uuidString }
        let derived = derive(from: sorted.filter { $0.sourceID != $0.targetID })
        let ordered = facts.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let commitments = deriveCurrentCommitments(from: ordered, at: now)
        let sameAs = try deriveSameAsCandidates(
            from: entities.values.sorted { $0.id.uuidString < $1.id.uuidString }, profile: .experimental)
        return Suggestions(
            edges: derived.edges.filter { ids.contains($0.sourceID) || ids.contains($0.targetID) },
            commitments: commitments.commitments.filter { ids.contains($0.ownerID) || ids.contains($0.actionID) },
            sameAs: sameAs.candidates.filter { ids.contains($0.firstID) || ids.contains($0.secondID) },
            isTruncated: derived.isTruncated || commitments.isTruncated || sameAs.isTruncated)
    }
}
