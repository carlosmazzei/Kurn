import Foundation
import KurnCore

/// The derived suggestions the Graph Explorer lists (K7.4, CLAUDE.md "Knowledge derived edges
/// (K7.4)"): relations, current owners with their due date, and identities that may be one. They
/// are inferred from stated claims on this read, never stored and never evidence, so each row says
/// how it was reached and the reader decides; nothing here merges or rewrites a claim.
extension KnowledgeGraphPresentation {
    struct Suggestion: Equatable, Identifiable {
        enum Kind: Equatable { case derivedEdge, commitment, sameAs }

        let id: String
        let kind: Kind
        /// The suggestion as a sentence.
        let text: String
        /// How it was reached and what it needs.
        let detail: String
        /// The first stated claim it follows from, for its cited passage; nil for a name match.
        let evidence: KnowledgeBrowserRoute?
    }

    /// The suggestions that touch the shown nodes, in the order the derivations return them. Only
    /// computed when the reader asked for inferred relationships; a derivation that cannot run
    /// shows none rather than failing the drawing.
    static func suggestions(pages: [KnowledgeWikiPage], touching nodeIDs: Set<UUID>, now: Date) -> [Suggestion] {
        guard let found = try? KnowledgeInference.suggestions(from: pages, touching: nodeIDs, at: now) else { return [] }
        let names = Dictionary(
            pages.flatMap { page in
                [(page.entity.id, page.entity.name)] + page.sections.flatMap(\.entries).flatMap { entry in
                    [(entry.subject.id, entry.subject.name)] + (entry.object.map { [($0.id, $0.name)] } ?? [])
                }
            }, uniquingKeysWith: { first, _ in first })
        let routes = evidenceRoutes(pages)
        func name(_ id: UUID) -> String { names[id] ?? copy("unnamed") }

        let edges = found.edges.map { edge in
            let predicate = NSLocalizedString("knowledge.predicate." + edge.predicate.rawValue, comment: "Claim predicate")
            return Suggestion(
                id: "edge:" + edge.premiseFactIDs.map(\.uuidString).joined(separator: ","), kind: .derivedEdge,
                text: String(format: NSLocalizedString("detail.knowledge.claim", comment: "Subject, predicate and object in source direction"),
                             name(edge.sourceID), predicate, name(edge.targetID)),
                detail: String(format: copy("suggestion.derived"), edge.premiseFactIDs.count),
                evidence: edge.premiseFactIDs.first.flatMap { routes[$0] })
        }
        let commitments = found.commitments.map { commitment in
            Suggestion(
                id: "commitment:" + commitment.premiseFactIDs.map(\.uuidString).joined(separator: ","), kind: .commitment,
                text: String(format: copy("suggestion.commitment"), name(commitment.ownerID), name(commitment.actionID), commitment.due.text),
                detail: String(format: copy("suggestion.derived"), commitment.premiseFactIDs.count),
                evidence: commitment.premiseFactIDs.first.flatMap { routes[$0] })
        }
        let sameAs = found.sameAs.map { candidate in
            Suggestion(
                id: "same:\(candidate.firstID.uuidString),\(candidate.secondID.uuidString)", kind: .sameAs,
                text: String(format: copy("suggestion.same_as"), name(candidate.firstID), name(candidate.secondID)),
                detail: String(format: copy("suggestion.same_as_detail"), candidate.score), evidence: nil)
        }
        return edges + commitments + sameAs
    }

    /// Each stated claim's first cited passage, by claim ID.
    private static func evidenceRoutes(_ pages: [KnowledgeWikiPage]) -> [UUID: KnowledgeBrowserRoute] {
        var routes: [UUID: KnowledgeBrowserRoute] = [:]
        for entry in pages.flatMap({ $0.sections.flatMap(\.entries) }) where routes[entry.fact.id] == nil {
            if let evidence = entry.fact.source.evidence.first {
                routes[entry.fact.id] = .evidence(assertionID: entry.fact.id, evidenceID: evidence.id)
            }
        }
        return routes
    }
}
