import Foundation
import Testing
@testable import AgentHarness

struct AgentSessionEntryTests {
    private func entry(_ id: String, ordinal: Int, parent: String? = nil, session: String = "session") throws -> AgentSessionEntry {
        try AgentSessionEntry(sessionID: session, id: id, parentID: parent, ordinal: ordinal,
            createdAt: "2023-11-14T22:13:20.125Z", payload: .message(.content(AgentContentMessage(id: id,
                timestampMilliseconds: nil, role: .user, blocks: [AgentContentBlock(id: "text", content: .text("Question"))]))))
    }

    @Test func graphKeepsSiblingsAndSelectsAnOlderLeafIndependentlyOfAppendOrder() throws {
        let root = try entry("root", ordinal: 1)
        let first = try entry("first", ordinal: 2, parent: "root")
        let sibling = try entry("sibling", ordinal: 3, parent: "root")
        let graph = try AgentEntryGraph(sessionID: "session", entries: [sibling, root, first], leafID: "first")
        #expect(graph.entries == [root, first, sibling] && graph.activePath == [root, first])
        #expect(try AgentEntryGraph(sessionID: "session", entries: graph.entries, leafID: "sibling").activePath == [root, sibling])
        #expect(try JSONDecoder().decode(AgentSessionEntry.self, from: JSONEncoder().encode(first)) == first)
        guard case .message(.content(let value)) = first.payload else { Issue.record("Native message missing"); return }
        #expect(value.timestampMilliseconds == nil && first.createdAt == "2023-11-14T22:13:20.125Z")
    }

    @Test func graphRejectsGapsDuplicatesForeignParentsCyclesAndMissingLeaves() throws {
        let root = try entry("root", ordinal: 1)
        let invalid: [[AgentSessionEntry]] = try [
            [root, entry("gap", ordinal: 3)], [root, root],
            [root, entry("foreign", ordinal: 2, parent: "root", session: "other")],
            [entry("forward", ordinal: 1, parent: "later"), entry("later", ordinal: 2, parent: "forward")]
        ]
        for entries in invalid {
            #expect(throws: AgentSessionStoreError.invalidGraph) { try AgentEntryGraph(sessionID: "session", entries: entries, leafID: "root") }
        }
        #expect(throws: AgentSessionStoreError.invalidGraph) { try AgentEntryGraph(sessionID: "session", entries: [root], leafID: "missing") }
    }

    @Test func codecsRejectUnknownVersionsInvalidIDsTimeAndLegacyMessagePayloads() throws {
        for id in ["", String(repeating: "é", count: 65)] {
            #expect(throws: AgentSessionStoreError.invalidEntry) {
                try AgentSessionEntry(sessionID: "session", id: id, parentID: nil, ordinal: 1,
                    createdAt: AgentSessionEntry.time(), payload: .custom(type: "host", data: .null))
            }
        }
        for time in ["2023-11-14", "2023-11-14T22:13:20.125+00:00", "invalidZ"] {
            #expect(throws: AgentSessionStoreError.invalidEntry) {
                try AgentSessionEntry(sessionID: "session", id: "entry", parentID: nil, ordinal: 1, createdAt: time, payload: .custom(type: "host", data: .null))
            }
        }
        #expect(throws: AgentSessionStoreError.invalidEntry) {
            try AgentSessionEntry(sessionID: "session", id: "entry", parentID: nil, ordinal: 1,
                createdAt: AgentSessionEntry.time(), payload: .message(.user("Legacy must be explicitly converted")))
        }
        let value = try entry("root", ordinal: 1)
        let source = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            .replacingOccurrences(of: "\"contractVersion\":1", with: "\"contractVersion\":2")
        #expect(throws: AgentSessionStoreError.unsupportedVersion) { try JSONDecoder().decode(AgentSessionEntry.self, from: Data(source.utf8)) }
    }

    @Test(arguments: [AgentRecoveryRecord.Kind.run, .queue, .draft, .effect])
    func recoveryContainersPreserveOpaqueMetadataWithoutExecutingIt(kind: AgentRecoveryRecord.Kind) throws {
        let value = try AgentRecoveryRecord(id: "record", kind: kind, data: .object(["unknown": .array([.bool(true), .string("opaque")])]))
        #expect(try JSONDecoder().decode(AgentRecoveryRecord.self, from: JSONEncoder().encode(value)) == value)
        #expect(throws: AgentSessionStoreError.invalidEntry) { try AgentRecoveryRecord(id: "", kind: kind, data: .null) }
        let source = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            .replacingOccurrences(of: "\"contractVersion\":1", with: "\"contractVersion\":2")
        #expect(throws: AgentSessionStoreError.unsupportedVersion) { try JSONDecoder().decode(AgentRecoveryRecord.self, from: Data(source.utf8)) }
    }
}
