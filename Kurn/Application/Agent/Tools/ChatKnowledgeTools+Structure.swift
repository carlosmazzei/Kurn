import AgentHarness
import Foundation
import KurnCore

/// The K5.1 tools that read the knowledge's structure rather than one page: name resolution, an
/// entity's neighbourhood, its state between two days, open actions and the contexts the
/// meetings were recorded in. Each is a projection of the same authorized read as the other
/// knowledge tools (`KnowledgeGraphIndex`, `KnowledgeStateComparison`, `KnowledgeLifecycle`),
/// never a second store, and answers in `ChatKnowledgeToolText`'s compact form.
extension ChatKnowledgeTools {
    static let structureArguments: [String: Set<String>] = [
        "resolve_entity": ["name", "kind", "offset", "limit"],
        "get_graph": ["entityID", "depth", "includeTentative", "includeNegated", "includeInferred", "offset", "limit"],
        "compare_state": ["entityID", "from", "to", "asKnownThen", "offset", "limit"],
        "list_open_actions": ["entityID", "offset", "limit"],
        "list_contexts": ["offset", "limit"],
        "get_context": ["contextID", "offset", "limit"],
        "trace_influence": ["entityID", "offset", "limit"],
    ]

    /// Action statuses after which nothing is left to do, unless reopened.
    static let closedActionStatuses: Set<KnowledgeStatus> = [.completed, .cancelled]

    static func executeStructure(_ name: String, params: Parameters, read: KnowledgeBrowserRead,
                                 now: Date) throws -> AgentToolOutput {
        switch name {
        case "resolve_entity": return try resolveEntity(params, read: read)
        case "get_graph": return try graph(params, read: read)
        case "compare_state": return try compareState(params, read: read, now: now)
        case "list_open_actions": return try openActions(params, read: read, now: now)
        case "list_contexts": return contexts(params, read: read)
        case "trace_influence": return try traceInfluence(params, read: read)
        default: return try context(params, read: read)
        }
    }

    // MARK: - resolve_entity

    /// How a name matched an entity, best first.
    enum NameMatch: String, CaseIterable {
        case exactName, alias, prefix, partial
    }

    private static func resolveEntity(_ params: Parameters, read: KnowledgeBrowserRead) throws -> AgentToolOutput {
        let name = try params.string("name", limit: 200)
        let kind = try params.entityKind("kind")
        // Pages are in name order, which the index keeps within a match.
        let matches = read.pages.enumerated().compactMap { index, page -> (Int, NameMatch, KnowledgeWikiPage)? in
            guard kind.map({ $0 == page.entity.kind }) ?? true, let match = match(name, page.entity),
                  let rank = NameMatch.allCases.firstIndex(of: match) else { return nil }
            return (rank * read.pages.count + index, match, page)
        }.sorted { $0.0 < $1.0 }
        return ChatKnowledgeToolText.output(header: "entities matching the name (best first; entity | name | kind | match | claims):",
                                            lines: matches.map { ChatKnowledgeToolText.resolved($0.2, match: $0.1) },
                                            offset: params.offset, limit: params.limit, read: read)
    }

    /// Accent- and case-folded: the exact name, an alias, a name or alias that starts with the
    /// query, or one holding every word of it.
    static func match(_ query: String, _ entity: KnowledgeWikiSnapshot.Entity) -> NameMatch? {
        let wanted = KnowledgeEntityResolver.normalizedName(query)
        guard !wanted.isEmpty else { return nil }
        let name = KnowledgeEntityResolver.normalizedName(entity.name)
        let aliases = entity.aliases.map(KnowledgeEntityResolver.normalizedName)
        if name == wanted { return .exactName }
        if aliases.contains(wanted) { return .alias }
        let all = [name] + aliases
        if all.contains(where: { $0.hasPrefix(wanted) }) { return .prefix }
        let words = tokens(wanted)
        return all.contains { words.isSubset(of: tokens($0)) } ? .partial : nil
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    // MARK: - get_graph

    private static func graph(_ params: Parameters, read: KnowledgeBrowserRead) throws -> AgentToolOutput {
        let id = try params.uuid("entityID")
        // Inferred relations stay hidden unless asked for, as in the Graph Explorer (K4.3).
        let depth = try params.integer("depth", fallback: 1, range: 0...KnowledgeGraph.Query.maximumDepth)
        let query = try KnowledgeGraph.Query(rootID: id, depth: depth,
                                             includesTentative: params.bool("includeTentative", fallback: true),
                                             includesNegated: params.bool("includeNegated", fallback: true),
                                             includesInferred: params.bool("includeInferred", fallback: false))
        guard let graph = KnowledgeGraphIndex(pages: read.pages).query(query) else { throw Invalid("Unknown entityID.") }
        let names = Dictionary(graph.nodes.map { ($0.id, $0.entity.name) }, uniquingKeysWith: { first, _ in first })
        let lines = graph.nodes.map(ChatKnowledgeToolText.node) + graph.edges.map { ChatKnowledgeToolText.edge($0, names: names) }
        return ChatKnowledgeToolText.output(header: ChatKnowledgeToolText.graphHeader(graph, names: names), lines: lines,
                                            offset: params.offset, limit: params.limit, read: read)
    }

    // MARK: - compare_state

    private static func compareState(_ params: Parameters, read: KnowledgeBrowserRead, now: Date) throws -> AgentToolOutput {
        let id = try params.uuid("entityID")
        guard let page = read.pages.first(where: { $0.entity.id == id }) else { throw Invalid("Unknown entityID.") }
        let from = try params.day("from"), to = try params.day("to")
        let (first, second) = (from.bounds?.lower ?? .distantPast) <= (to.bounds?.lower ?? .distantPast) ? (from, to) : (to, from)
        let asKnownThen = try params.bool("asKnownThen", fallback: false)
        guard let earlier = KnowledgeStateComparison.Point.endOfDay(first, knownAt: asKnownThen ? nil : now),
              let later = KnowledgeStateComparison.Point.endOfDay(second, knownAt: asKnownThen ? nil : now) else {
            throw Invalid("Invalid from or to.")
        }
        let comparison = KnowledgeStateComparison.compare(entityID: id, earlier: earlier, later: later,
                                                          claims: KnowledgeStateComparison.claims(from: read.pages))
        let names = ChatKnowledgeToolText.names(read.pages)
        let lines = comparison.changes.map { ChatKnowledgeToolText.change($0, entity: page.entity, names: names) }
            + comparison.earlier.conflicts.map { ChatKnowledgeToolText.conflict($0, side: "earlier") }
            + comparison.later.conflicts.map { ChatKnowledgeToolText.conflict($0, side: "later") }
        let known = asKnownThen ? "as known at the end of each day" : "as known now"
        let header = "state of entity \(id.uuidString) | \(ChatSourceToolText.field(page.entity.name, limit: 200))"
            + " | from \(first.text) to \(second.text) (end of each day, \(known))"
            + "\nchanges (kind | claim | before | certainty | assertions), then conflicts:"
        return ChatKnowledgeToolText.output(header: header, lines: lines, offset: params.offset, limit: params.limit, read: read)
    }

    // MARK: - trace_influence

    private static func traceInfluence(_ params: Parameters, read: KnowledgeBrowserRead) throws -> AgentToolOutput {
        let id = try params.uuid("entityID")
        guard let page = read.pages.first(where: { $0.entity.id == id }) else { throw Invalid("Unknown entityID.") }
        let steps = KnowledgeInfluenceTrace.trace(entityID: id, pages: read.pages)
        let header = "influence on entity \(id.uuidString) | \(ChatSourceToolText.field(page.entity.name, limit: 200))"
            + "\nsteps in stated order (assertion | claim | qualifiers | meeting | speakers | replaces | evidence):"
        return ChatKnowledgeToolText.output(header: header, lines: steps.map(ChatKnowledgeToolText.influence),
                                            offset: params.offset, limit: params.limit, read: read)
    }

    // MARK: - list_open_actions

    private static func openActions(_ params: Parameters, read: KnowledgeBrowserRead, now: Date) throws -> AgentToolOutput {
        let filter = try params.optionalUUID("entityID")
        if let filter, !read.pages.contains(where: { $0.entity.id == filter }) { throw Invalid("Unknown entityID.") }
        let claims = KnowledgeStateComparison.claims(from: read.pages)
        let actions = read.pages.compactMap { page -> ChatKnowledgeToolText.OpenAction? in
            guard page.entity.kind == .actionItem else { return nil }
            let entries = page.sections.flatMap(\.entries)
            if let filter, page.entity.id != filter,
               !entries.contains(where: { $0.subject.id == filter || $0.object?.id == filter }) { return nil }
            let projection = KnowledgeLifecycle.action.project(entityID: page.entity.id, knownAt: now, claims: claims)
            let state = projection.state(at: now)
            // Only a definite completion or cancellation closes an action; a possible one is listed.
            if let state, state.certainty == .definite, closedActionStatuses.contains(state.status) { return nil }
            let holdings = KnowledgeTemporalReducer.state(of: page.entity.id, validAt: now, knownAt: now, claims: claims)
            return ChatKnowledgeToolText.OpenAction(page: page, projection: projection, state: state, holdings: holdings)
        }
        let names = ChatKnowledgeToolText.names(read.pages)
        return ChatKnowledgeToolText.output(
            header: "open actions as of \(ChatSourceToolText.date(now)) (action | name | status | assigned | due | anomalies):",
            lines: actions.map { ChatKnowledgeToolText.openAction($0, names: names) }, offset: params.offset, limit: params.limit, read: read)
    }

    // MARK: - list_contexts / get_context

    /// The selected meetings grouped by the context each was recorded in, in the Graph
    /// Explorer's lane order: by kind, `unknown` last, then by name.
    static func contextGroups(_ read: KnowledgeBrowserRead) -> [(context: KnowledgeBrowserContext, meetings: [UUID])] {
        let grouped = Dictionary(grouping: read.meetingIDs) { read.meetingContexts[$0]?.id }
        return grouped.map { id, meetings in
            let context = id.flatMap { id in meetings.lazy.compactMap { read.meetingContexts[$0] }.first { $0.id == id } } ?? .unknown
            let ordered = meetings.sorted {
                (read.meetingTitles[$0] ?? "", $0.uuidString) < (read.meetingTitles[$1] ?? "", $1.uuidString)
            }
            return (context, ordered)
        }.sorted { lhs, rhs in
            let left = KnowledgeContextKind.allCases.firstIndex(of: lhs.context.kind) ?? 0
            let right = KnowledgeContextKind.allCases.firstIndex(of: rhs.context.kind) ?? 0
            return (left, KnowledgeEntityResolver.normalizedName(lhs.context.name), lhs.context.id?.uuidString ?? "")
                < (right, KnowledgeEntityResolver.normalizedName(rhs.context.name), rhs.context.id?.uuidString ?? "")
        }
    }

    private static func contexts(_ params: Parameters, read: KnowledgeBrowserRead) -> AgentToolOutput {
        ChatKnowledgeToolText.output(header: "contexts of the selected meetings (context | kind | name | meetings):",
                                     lines: contextGroups(read).map { ChatKnowledgeToolText.context($0.context, meetings: $0.meetings.count) },
                                     offset: params.offset, limit: params.limit, read: read)
    }

    private static func context(_ params: Parameters, read: KnowledgeBrowserRead) throws -> AgentToolOutput {
        guard case .string(let text) = params.values["contextID"] else { throw Invalid("Invalid contextID.") }
        let wanted: UUID?
        if text == "unknown" {
            wanted = nil
        } else {
            guard let id = UUID(uuidString: text) else { throw Invalid("Invalid contextID.") }
            wanted = id
        }
        guard let group = contextGroups(read).first(where: { $0.context.id == wanted }) else { throw Invalid("Unknown contextID.") }
        var claims: [UUID: Set<UUID>] = [:]
        for entry in read.pages.flatMap({ $0.sections.flatMap(\.entries) }) {
            claims[entry.fact.source.meetingID, default: []].insert(entry.fact.id)
        }
        let header = String(ChatKnowledgeToolText.context(group.context, meetings: group.meetings.count).text.dropFirst(2))
            + "\nmeetings (meeting | title | claims):"
        let lines = group.meetings.map { id in
            ChatKnowledgeToolText.meeting(id, title: read.meetingTitles[id] ?? "", claims: claims[id]?.count ?? 0)
        }
        return ChatKnowledgeToolText.output(header: header, lines: lines, offset: params.offset, limit: params.limit, read: read)
    }

    // MARK: - Schemas

    static func structureSchema(_ name: String) -> (properties: [String: JSONValue], required: [String], description: String) {
        let uuid: JSONValue = .object(["type": .string("string"), "format": .string("uuid")])
        let flag: JSONValue = .object(["type": .string("boolean")])
        let day: JSONValue = .object([
            "type": .string("string"),
            "minLength": .number(10),
            "maxLength": .number(10),
            "description": .string("Calendar day formatted as yyyy-MM-dd.")
        ])
        switch name {
        case "resolve_entity":
            return (["name": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200)]),
                     "kind": .object(["type": .string("string"), "enum": .array(KnowledgeEntityKind.allCases.map { .string($0.rawValue) })])],
                    ["name"],
                    "Find the entities a name refers to (exact name, alias, prefix or every word), optionally of one kind, "
                        + "to get the entityID the other knowledge tools take.")
        case "get_graph":
            return (["entityID": uuid,
                     "depth": .object(["type": .string("integer"), "minimum": .number(0),
                                       "maximum": .number(Double(KnowledgeGraph.Query.maximumDepth))]),
                     "includeTentative": flag, "includeNegated": flag, "includeInferred": flag],
                    ["entityID"],
                    "Read the relationships around one entity (default depth 1, inferred relations hidden unless asked for): "
                        + "nodes, then edges, each edge one claim in its stated direction with its evidence ID.")
        case "compare_state":
            return (["entityID": uuid, "from": day, "to": day, "asKnownThen": flag],
                    ["entityID", "from", "to"],
                    "Compare what held for one entity at the end of two days (yyyy-MM-dd): what changed, started, ended "
                        + "or stayed, as known now or, with asKnownThen, as known on each day; conflicts stay conflicts.")
        case "trace_influence":
            return (["entityID": uuid], ["entityID"],
                    "Trace what shaped one entity's current state, in stated order: each claim about or naming it, "
                        + "the earlier claims on the same subject and predicate it replaces, its meeting, speakers and "
                        + "evidence IDs.")
        case "list_open_actions":
            return (["entityID": uuid], [],
                    "List action items not definitely completed or cancelled, with status, assignees and due dates, "
                        + "optionally only those linked to one entity (a person, team or project).")
        case "list_contexts":
            return ([:], [], "List the contexts (occasions such as an internal meeting or a vendor discussion) the selected "
                        + "meetings were recorded in; meetings with none are in context \"unknown\".")
        default:
            return (["contextID": .object(["type": .string("string"),
                                           "description": .string("A context ID from list_contexts, or \"unknown\".")])],
                    ["contextID"], "Read one context: its kind, name and the selected meetings recorded in it.")
        }
    }
}

extension ChatKnowledgeTools.Parameters {
    func bool(_ key: String, fallback: Bool) throws -> Bool {
        guard let value = values[key] else { return fallback }
        guard case .bool(let flag) = value else { throw ChatKnowledgeTools.Invalid("Invalid \(key).") }
        return flag
    }

    func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        do {
            return try Self.integer(values[key], fallback: fallback, range: range)
        } catch {
            throw ChatKnowledgeTools.Invalid("Invalid \(key).")
        }
    }

    func day(_ key: String) throws -> KnowledgeTemporalValue {
        guard case .string(let text) = values[key], let day = KnowledgeTemporalValue(text: text, precision: .day) else {
            throw ChatKnowledgeTools.Invalid("Invalid \(key); expected yyyy-MM-dd.")
        }
        return day
    }

    func entityKind(_ key: String) throws -> KnowledgeEntityKind? {
        guard let value = values[key] else { return nil }
        guard case .string(let text) = value, let kind = KnowledgeEntityKind(rawValue: text) else {
            throw ChatKnowledgeTools.Invalid("Invalid \(key).")
        }
        return kind
    }
}
