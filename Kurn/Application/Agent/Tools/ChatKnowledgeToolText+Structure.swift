import Foundation
import KurnCore

/// Lines for the structure tools (`ChatKnowledgeTools+Structure`), in the same compact form as
/// the other knowledge tools: IDs the model passes back and vocabulary raw values.
extension ChatKnowledgeToolText {
    static func resolved(_ page: KnowledgeWikiPage, match: ChatKnowledgeTools.NameMatch) -> Rendered {
        let name = ChatSourceToolText.renderedField(page.entity.name, limit: 200)
        var line = "- entity \(page.entity.id.uuidString) | \(name.text) | kind: \(page.entity.kind.rawValue)"
            + " | match: \(match.rawValue) | claims: \(Set(page.sections.flatMap(\.entries).map(\.fact.id)).count)"
        if !page.entity.aliases.isEmpty {
            line += " | aliases: " + page.entity.aliases.prefix(10).map { ChatSourceToolText.field($0, limit: 100) }.joined(separator: ", ")
        }
        return Rendered(text: line, omittedScalars: name.omittedScalars)
    }

    static func graphHeader(_ graph: KnowledgeGraph, names: [UUID: String]) -> String {
        let root = graph.query.rootID
        var header = "graph around entity \(root.uuidString) | \(ChatSourceToolText.field(names[root] ?? "", limit: 200))"
            + " | depth: \(graph.query.depth) | nodes: \(graph.nodes.count) | edges: \(graph.edges.count)"
        if graph.isTruncated { header += " | truncated: a node or edge bound was reached" }
        if !graph.frontier.isEmpty {
            header += "\nmore to explore from: " + graph.frontier.prefix(20).map(\.uuidString).joined(separator: ", ")
        }
        if !graph.supersessionCycles.isEmpty {
            header += "\nsupersedes cycles (not ordered): "
                + graph.supersessionCycles.map { "[" + $0.map(\.uuidString).joined(separator: ", ") + "]" }.joined(separator: "; ")
        }
        return header + "\nnodes (node | name | kind | depth), then edges (edge assertion | claim | modality | evidence):"
    }

    static func node(_ node: KnowledgeGraph.Node) -> Rendered {
        let name = ChatSourceToolText.renderedField(node.entity.name, limit: 200)
        return Rendered(text: "- node \(node.id.uuidString) | \(name.text) | kind: \(node.entity.kind.rawValue) | depth: \(node.depth)",
                        omittedScalars: name.omittedScalars)
    }

    static func edge(_ edge: KnowledgeGraph.Edge, names: [UUID: String]) -> Rendered {
        let claim = [names[edge.sourceID] ?? "", edge.predicate.rawValue, names[edge.targetID] ?? ""].joined(separator: " ")
        let text = ChatSourceToolText.renderedField(edge.polarity == .negative ? "NOT " + claim : claim, limit: 400)
        var line = "- edge \(edge.factID.uuidString) | \(text.text) | modality: \(edge.modality.rawValue)"
        if edge.isTentative { line += " | tentative" }
        if let evidence = edge.evidenceID { line += " | evidence \(evidence.uuidString)" }
        return Rendered(text: line, omittedScalars: text.omittedScalars)
    }

    /// Every identity the pages name, by ID.
    static func names(_ pages: [KnowledgeWikiPage]) -> [UUID: String] {
        Dictionary(pages.flatMap { page in
            [(page.entity.id, page.entity.name)] + page.sections.flatMap(\.entries).flatMap { entry in
                [(entry.subject.id, entry.subject.name)] + (entry.object.map { [($0.id, $0.name)] } ?? [])
            }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// A holding in its stated direction, `NOT` first when negated.
    static func holding(_ holding: KnowledgeTemporalState.Holding, entity: KnowledgeWikiSnapshot.Entity,
                        names: [UUID: String]) -> String {
        let other = holding.otherEntityID.map { names[$0] ?? "" } ?? holding.value.map(valueText) ?? ""
        let parts = holding.direction == .outgoing ? [entity.name, holding.predicate.rawValue, other]
            : [other, holding.predicate.rawValue, entity.name]
        let claim = parts.filter { !$0.isEmpty }.joined(separator: " ")
        return holding.polarity == .negative ? "NOT " + claim : claim
    }

    static func change(_ change: KnowledgeStateComparison.Change, entity: KnowledgeWikiSnapshot.Entity,
                       names: [UUID: String]) -> Rendered {
        guard let shown = change.after ?? change.before else { return Rendered(text: "- \(change.kind.rawValue)") }
        let text = ChatSourceToolText.renderedField(holding(shown, entity: entity, names: names), limit: 400)
        var omitted = text.omittedScalars
        var line = "- \(change.kind.rawValue) | \(text.text)"
        if change.kind == .changed, let before = change.before {
            let earlier = ChatSourceToolText.renderedField(holding(before, entity: entity, names: names), limit: 400)
            line += " | before: \(earlier.text)"
            omitted += earlier.omittedScalars
        }
        let certainty = [change.before, change.after].compactMap { $0?.certainty.rawValue }
        line += " | certainty: " + (change.certaintyChanged ? certainty.joined(separator: " → ") : shown.certainty.rawValue)
        if shown.isTentative { line += " | tentative" }
        let claims = Set((change.before?.claimIDs ?? []) + (change.after?.claimIDs ?? [])).sorted { $0.uuidString < $1.uuidString }
        line += " | assertions " + claims.prefix(10).map(\.uuidString).joined(separator: ", ")
        return Rendered(text: line, omittedScalars: omitted)
    }

    static func conflict(_ conflict: KnowledgeTemporalState.Conflict, side: String) -> Rendered {
        Rendered(text: "- conflict at \(side) | \(conflict.predicate.rawValue) | \(conflict.reason.rawValue) | assertions "
            + conflict.claimIDs.prefix(10).map(\.uuidString).joined(separator: ", "))
    }

    struct OpenAction {
        let page: KnowledgeWikiPage
        let projection: KnowledgeLifecycleProjection
        let state: KnowledgeLifecycleProjection.Snapshot?
    }

    static func openAction(_ action: OpenAction) -> Rendered {
        let entity = action.page.entity
        let entries = action.page.sections.flatMap(\.entries).filter { $0.fact.qualifiers.polarity == .positive }
        let name = ChatSourceToolText.renderedField(entity.name, limit: 200)
        var line = "- action \(entity.id.uuidString) | \(name.text) | status: "
        if let state = action.state {
            let since = action.projection.transitions[state.transitionIndex].stated.text
            line += "\(state.status.rawValue) (\(state.certainty.rawValue), since \(since))"
        } else {
            line += "unknown"
        }
        let assigned = entries.compactMap { entry -> String? in
            if entry.fact.predicate == .assignedTo, entry.subject.id == entity.id { return entry.object?.name }
            if entry.fact.predicate == .owns, entry.object?.id == entity.id { return entry.subject.name }
            return nil
        }
        if !assigned.isEmpty {
            line += " | assigned: " + Array(Set(assigned)).sorted().prefix(5).map { ChatSourceToolText.field($0, limit: 100) }
                .joined(separator: ", ")
        }
        let due = entries.filter { $0.fact.predicate == .dueOn && $0.subject.id == entity.id }.compactMap { $0.fact.value.map(valueText) }
        if !due.isEmpty { line += " | due: " + Array(Set(due)).sorted().prefix(3).joined(separator: ", ") }
        let anomalies = Set(action.projection.anomalies.map(\.code.rawValue)).sorted()
        if !anomalies.isEmpty { line += " | anomalies: " + anomalies.joined(separator: ", ") }
        return Rendered(text: line, omittedScalars: name.omittedScalars)
    }

    static func context(_ context: KnowledgeBrowserContext, meetings: Int) -> Rendered {
        let name = ChatSourceToolText.renderedField(context.name, limit: 200)
        return Rendered(text: "- context \(context.id?.uuidString ?? "unknown") | kind: \(context.kind.rawValue)"
            + " | \(name.text.isEmpty ? "(no name)" : name.text) | meetings: \(meetings)", omittedScalars: name.omittedScalars)
    }

    static func meeting(_ id: UUID, title: String, claims: Int) -> Rendered {
        let shown = ChatSourceToolText.renderedField(title, limit: 200)
        return Rendered(text: "- meeting \(id.uuidString) | \(shown.text) | claims: \(claims)", omittedScalars: shown.omittedScalars)
    }
}
