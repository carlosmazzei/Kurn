import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K5.1: the knowledge tools that read structure — name resolution, the graph, state between two
/// days, open actions and contexts — over the same authorized read as the other knowledge tools.
@MainActor
struct ChatKnowledgeStructureToolsTests {
    private nonisolated static let review = UUID(), planning = UUID(), sync = UUID(), recording = UUID()
    private nonisolated static let project = UUID(), team = UUID(), person = UUID(), migrate = UUID(), runbook = UUID()
    private nonisolated static let proposedOwner = UUID(), formerOwner = UUID()
    private nonisolated static let now = Date(timeIntervalSince1970: 1_795_600_000)

    private nonisolated static func day(_ text: String) -> KnowledgeTemporalValue? {
        KnowledgeTemporalValue(text: text, precision: .day)
    }

    private nonisolated static func fact(_ subject: UUID, _ predicate: KnowledgePredicate, object: UUID? = nil,
                                         value: KnowledgeTypedValue? = nil, modality: KnowledgeModality = .reported,
                                         from: KnowledgeTemporalValue? = nil, to: KnowledgeTemporalValue? = nil,
                                         meeting: UUID = review) -> KnowledgeWikiSnapshot.Fact {
        .init(id: UUID(), subjectID: subject, predicate: predicate, objectID: object, value: value,
              qualifiers: .init(modality: modality, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                confidence: .medium, review: .machineExtracted, validFrom: from, validTo: to),
              source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_790_000_000), evidence: [
                  .init(id: UUID(), recordingID: recording, segmentIDs: ["s1"], quote: "Quoted.", startMs: 0, endMs: 1_000,
                        attributedSpeaker: "Speaker 1"),
              ]))
    }

    private nonisolated static func read() throws -> KnowledgeBrowserRead {
        let entities: [KnowledgeWikiSnapshot.Entity] = [
            .init(id: project, kind: .project, name: "Example portal", aliases: ["Portal"]),
            .init(id: team, kind: .team, name: "Platform team"),
            .init(id: person, kind: .person, name: "Avery Example"),
            .init(id: migrate, kind: .actionItem, name: "Migrate billing"),
            .init(id: runbook, kind: .actionItem, name: "Write runbook"),
            .init(id: proposedOwner, kind: .person, name: "Riley Example"),
            .init(id: formerOwner, kind: .person, name: "Former owner"),
        ]
        let facts = [
            fact(team, .blocks, object: project, from: KnowledgeTemporalValue(text: "2026-09", precision: .month),
                 to: KnowledgeTemporalValue(text: "2026-11", precision: .month)),
            fact(project, .hasStatus, value: .enumeration("open"), from: day("2026-10-05")),
            fact(project, .hasStatus, value: .enumeration("blocked"), from: day("2026-11-10"), meeting: planning),
            fact(migrate, .assignedTo, object: person, meeting: planning),
            fact(migrate, .assignedTo, object: proposedOwner, modality: .proposed, meeting: planning),
            fact(migrate, .assignedTo, object: formerOwner, to: day("2026-10-01"), meeting: planning),
            fact(migrate, .partOf, object: project, meeting: planning),
            fact(migrate, .hasStatus, value: .enumeration("committed"), from: day("2026-10-20"), meeting: planning),
            fact(migrate, .dueOn, value: day("2026-12-01").map { .date($0) }, meeting: planning),
            fact(runbook, .hasStatus, value: .enumeration("completed"), from: day("2026-10-15")),
            fact(team, .relatesTo, object: person, modality: .inferred),
        ]
        return try KnowledgeBrowserRead(meetingIDs: [review, planning], wiki: .init(revision: 4, entities: entities, facts: facts),
                                        meetingTitles: [review: "Weekly review", planning: "Planning"],
                                        meetingContexts: [review: .init(id: sync, kind: .vendorDiscussion, name: "Sync")])
    }

    private static func source() -> ChatKnowledgeSource {
        ChatKnowledgeSource(
            read: { _, _ in try read() },
            authorization: { ids in
                KnowledgeSourceAuthorization(featureEnabled: true, meetingIDs: ids, policies: [
                    KnowledgeProcessingPolicy(allowedRemoteProviderIDs: [AIProvider.openAI.id], maxRemoteClassification: .internal),
                ], sourceClassifications: [.internal])
            },
            remoteConsent: { _ in true })
    }

    private func run(_ name: String, _ arguments: [String: JSONValue]) async throws -> AgentToolOutput {
        let tools = ChatKnowledgeTools.make(source: Self.source(), meetings: [Self.review, Self.planning], provider: .openAI,
                                            now: { Self.now })
        return try await #require(tools.first { $0.spec.name == name }).execute(.object(arguments))
    }

    @Test func resolveEntityRanksExactNamesThenAliasesPrefixesAndWords() async throws {
        let exact = try await run("resolve_entity", ["name": .string("example PORTAL")])
        #expect(exact.content.contains("- entity \(Self.project.uuidString) | Example portal | kind: project | match: exactName"))
        let alias = try await run("resolve_entity", ["name": .string("Portal")])
        #expect(alias.content.contains("match: alias"))
        let prefix = try await run("resolve_entity", ["name": .string("exam")])
        #expect(prefix.content.contains("Example portal | kind: project | match: prefix") && !prefix.content.contains("Avery"))
        #expect(try await run("resolve_entity", ["name": .string("billing")]).content.contains("Migrate billing | kind: actionItem | match: partial"))
        // A whole word anywhere in the name, here narrowed to one kind.
        let typed = try await run("resolve_entity", ["name": .string("example"), "kind": .string("person")])
        #expect(typed.content.contains("Avery Example | kind: person | match: partial") && !typed.content.contains("Example portal"))
        #expect(try await run("resolve_entity", ["name": .string("portal"), "kind": .string("planet")]).isError)
        #expect(try await run("resolve_entity", ["name": .string(" ")]).isError)
    }

    @Test func theGraphHidesInferredRelationsUnlessAsked() async throws {
        let graph = try await run("get_graph", ["entityID": .string(Self.team.uuidString)])
        #expect(graph.content.hasPrefix("graph around entity \(Self.team.uuidString) | Platform team | depth: 1 | nodes: 2 | edges: 1"))
        #expect(graph.content.contains("- edge ") && graph.content.contains("| Platform team blocks Example portal | modality: reported"))
        // Endpoint node IDs tell same-named entities apart.
        #expect(graph.content.contains("| from \(Self.team.uuidString) to \(Self.project.uuidString)"))
        #expect(!graph.content.contains("Avery Example"))
        let inferred = try await run("get_graph", ["entityID": .string(Self.team.uuidString), "includeInferred": .bool(true)])
        #expect(inferred.content.contains("Platform team relatesTo Avery Example | modality: inferred"))
        #expect(try await run("get_graph", ["entityID": .string(UUID().uuidString)]).isError)
        #expect(try await run("get_graph", ["entityID": .string(Self.team.uuidString), "depth": .number(3)]).isError)
        #expect(try await run("get_graph", ["entityID": .string(Self.team.uuidString), "includeNegated": .string("yes")]).isError)
    }

    @Test func compareStateReportsChangesAndCertaintyShifts() async throws {
        // Days are taken in either order.
        let output = try await run("compare_state", ["entityID": .string(Self.project.uuidString),
                                                     "from": .string("2026-11-15"), "to": .string("2026-10-10")])
        #expect(output.content.contains("from 2026-10-10 to 2026-11-15 (end of each day, as known now)"))
        #expect(output.content.contains("- changed | Example portal hasStatus blocked | before: Example portal hasStatus open"))
        #expect(output.content.contains("- unchanged | Platform team blocks Example portal | certainty: definite → possible"))
        #expect(try await run("compare_state", ["entityID": .string(Self.project.uuidString),
                                                "from": .string("2026-10"), "to": .string("2026-11-15")]).isError)
        #expect(try await run("compare_state", ["entityID": .string(Self.project.uuidString), "from": .string("2026-10-10")]).isError)
    }

    @Test func traceInfluenceOrdersClaimsAndNamesWhatTheyReplace() async throws {
        let output = try await run("trace_influence", ["entityID": .string(Self.project.uuidString)])
        #expect(output.content.contains("influence on entity \(Self.project.uuidString)"))
        let lines = output.content.split(separator: "\n").map(String.init)
        let open = try #require(lines.firstIndex { $0.contains("Example portal hasStatus open") })
        let blocked = try #require(lines.firstIndex { $0.contains("Example portal hasStatus blocked") })
        #expect(open < blocked)
        #expect(lines[open].contains("replaces none"))
        #expect(!lines[blocked].contains("replaces none") && lines[blocked].contains("| speakers "))
        #expect(try await run("trace_influence", ["entityID": .string(UUID().uuidString)]).isError)
        #expect(try await run("trace_influence", [:]).isError)
    }

    @Test func openActionsLeaveOutDefinitelyCompletedOnes() async throws {
        let output = try await run("list_open_actions", [:])
        #expect(output.content.contains("- action \(Self.migrate.uuidString) | Migrate billing | status: committed (definite, since 2026-10-20)"
            + " | assigned: Avery Example, Riley Example (tentative) | due: 2026-12-01"))
        // An assignment that ended is not a current detail.
        #expect(!output.content.contains("Former owner"))
        #expect(!output.content.contains("Write runbook"))
        // Linked through its assignee or the project it is part of; not through an unrelated team.
        #expect(try await run("list_open_actions", ["entityID": .string(Self.person.uuidString)]).content.contains("Migrate billing"))
        #expect(try await run("list_open_actions", ["entityID": .string(Self.project.uuidString)]).content.contains("Migrate billing"))
        #expect(try await run("list_open_actions", ["entityID": .string(Self.team.uuidString)]).content.contains("page: no items of 0; end"))
        #expect(try await run("list_open_actions", ["entityID": .string(UUID().uuidString)]).isError)
    }

    @Test func contextsGroupTheMeetingsUnknownLast() async throws {
        let list = try await run("list_contexts", [:])
        let known = "- context \(Self.sync.uuidString) | kind: vendorDiscussion | Sync | meetings: 1"
        let unknown = "- context unknown | kind: unknown | (no name) | meetings: 1"
        let lines = list.content.split(separator: "\n").map(String.init)
        let first = try #require(lines.firstIndex(of: known)), last = try #require(lines.firstIndex(of: unknown))
        #expect(first < last)
        let context = try await run("get_context", ["contextID": .string(Self.sync.uuidString)])
        #expect(context.content.hasPrefix("context \(Self.sync.uuidString) | kind: vendorDiscussion | Sync | meetings: 1"))
        #expect(context.content.contains("- meeting \(Self.review.uuidString) | Weekly review | claims: 4"))
        let none = try await run("get_context", ["contextID": .string("unknown")])
        #expect(none.content.contains("- meeting \(Self.planning.uuidString) | Planning | claims: 7"))
        #expect(try await run("get_context", ["contextID": .string(UUID().uuidString)]).isError)
        #expect(try await run("get_context", ["contextID": .string("nope")]).isError)
        #expect(try await run("list_contexts", ["extra": .number(1)]).isError)
    }

    @Test func everyToolHasAClosedValidSchemaAcceptedByAgentToolRegistry() throws {
        let tools = ChatKnowledgeTools.make(source: Self.source(), meetings: [Self.review], provider: .openAI)
        #expect(tools.map(\.spec.name) == ChatKnowledgeTools.names)
        let registry = try AgentToolRegistry(tools)
        for tool in tools {
            guard case .object(let schema) = tool.spec.inputSchema else { Issue.record("schema"); continue }
            #expect(schema["additionalProperties"] == .bool(false))
        }
        try registry.validate(
            .object([
                "entityID": .string(Self.project.uuidString),
                "from": .string("2026-10-10"),
                "to": .string("2026-11-15")
            ]),
            for: "compare_state"
        )
    }
}
