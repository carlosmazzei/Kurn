import Foundation
import Testing
@testable import AgentHarness

/// The native session archive (NH10): a round trip keeps identity, the whole tree, opaque data and
/// usage; only LF separates records, whatever the chunks; anything it cannot trust is rejected.
@Suite struct AgentSessionArchiveTests {
    private func entry(_ id: String, parent: String?, ordinal: Int, _ payload: AgentSessionEntry.Payload,
                       session: String = "session", run: String? = nil) throws -> AgentSessionEntry {
        try AgentSessionEntry(sessionID: session, id: id, parentID: parent, ordinal: ordinal,
                              createdAt: "2026-11-13T10:00:0\(ordinal % 10).000Z", payload: payload,
                              metadata: run.map { .object(["runID": .string($0)]) })
    }

    private func message(_ id: String, _ role: AgentContentMessage.Role, _ text: String) throws -> AgentSessionEntry.Payload {
        .message(.content(try AgentContentMessage(id: id, timestampMilliseconds: 1_763_028_000_123, role: role,
                                                  blocks: [AgentContentBlock(id: "text", content: .text(text))])))
    }

    /// Two branches, a run with usage on one of them, a label, an entry type this version does
    /// not know, host records and an unknown header field.
    private func archive() throws -> AgentSessionArchive {
        let entries = [
            try entry("q1", parent: nil, ordinal: 1, message("q1", .user, "First question")),
            try entry("a1", parent: "q1", ordinal: 2, message("a1", .assistant, "Line\u{2028}separated\u{2029}paragraph")),
            try entry("run", parent: "a1", ordinal: 3, .custom(type: AgentRunBranch.startType, data: .object([:])), run: "r1"),
            try entry("usage", parent: "run", ordinal: 4, .custom(type: "agent.usage.v1", data: .object([
                "inputTokens": .number(1_200), "outputTokens": .number(80)])), run: "r1"),
            try entry("q2", parent: "a1", ordinal: 5, message("q2", .user, "Asked again")),
            try entry("future", parent: "q2", ordinal: 6, .custom(type: "vendor.future.v9", data: .object([
                "nested": .array([.object(["deep": .bool(true)]), .null])]))),
            try entry("label", parent: nil, ordinal: 7, .custom(type: AgentSessionTree.Label.entryType, data: .object([
                "targetID": .string("q1"), "label": .string("Kickoff")])))
        ]
        return try AgentSessionArchive(sessionID: "session", leafID: "future", entries: entries, records: [
            .init(type: "kurn.artifact-revision", data: .object(["id": .string("doc"), "version": .number(2)])),
            .init(type: "other.unknown-record", data: .string("kept as it was"))
        ], metadata: ["origin": .object(["cwd": .string("/Users/someone/project")])])
    }

    @Test func aRoundTripKeepsIdentityEveryBranchOpaqueDataAndUsage() throws {
        let original = try archive()
        let data = try original.jsonl()
        let restored = try AgentSessionArchive.decode(data)

        #expect(restored == original)
        #expect(try restored.jsonl() == data)
        #expect(restored.metadata["origin"] == .object(["cwd": .string("/Users/someone/project")]))
        let tree = try AgentSessionTree(AgentSessionSnapshot(sessionID: restored.sessionID, revision: 1,
                                                             leafID: restored.leafID, entries: restored.entries))
        #expect(tree.alternatives(of: "q2") == ["q2"])
        #expect(tree.usage(.session) == AgentUsage(inputTokens: 1_200, outputTokens: 80))
        #expect(tree.labels == ["q1": "Kickoff"])
    }

    @Test func onlyLFSeparatesRecordsWhateverTheChunks() throws {
        let original = try archive()
        let data = try original.jsonl()
        #expect(data.filter { $0 == 0x0A }.count == 1 + original.entries.count + original.records.count)

        for size in [1, 2, 3, 7, 64] {
            var reader = AgentJSONLLines()
            var lines: [Data] = []
            var offset = 0
            while offset < data.count {
                lines += try reader.append(data.subdata(in: offset..<min(offset + size, data.count)))
                offset += size
            }
            #expect(try reader.finish() == nil)
            var joined = Data()
            for line in lines { joined.append(line); joined.append(0x0A) }
            #expect(try AgentSessionArchive.decode(joined) == original)
        }
        // A final line without its LF is still a line.
        #expect(try AgentSessionArchive.decode(data.dropLast()) == original)
    }

    @Test func anImportedCopyMovesTheGraphToItsOwnIdentity() throws {
        let original = try archive()
        let copy = try original.copy(into: "imported")

        #expect(copy.sessionID == "imported" && copy.entries.allSatisfy { $0.sessionID == "imported" })
        #expect(copy.entries.map(\.id) == original.entries.map(\.id))
        #expect(copy.entries.map(\.parentID) == original.entries.map(\.parentID))
        #expect(copy.leafID == original.leafID && copy.records == original.records)
    }

    @Test func whatCannotBeTrustedIsRejected() throws {
        let header = #"{"type":"session","format":"kurn.agent-session","version":1,"sessionID":"session","leafID":null}"#
        func decode(_ lines: [String], limits: AgentSessionArchive.Limits = .init()) throws -> AgentSessionArchive {
            try AgentSessionArchive.decode(Data(lines.joined(separator: "\n").utf8), limits: limits)
        }
        #expect(try decode([header]).entries.isEmpty)
        #expect(throws: AgentSessionArchiveError.notAnArchive) {
            try decode([#"{"type":"session","format":"other","version":1,"sessionID":"s"}"#])
        }
        #expect(throws: AgentSessionArchiveError.unsupportedVersion) {
            try decode([#"{"type":"session","format":"kurn.agent-session","version":2,"sessionID":"s"}"#])
        }
        #expect(throws: AgentSessionArchiveError.invalidLine(2)) { try decode([header, header]) }
        #expect(throws: AgentSessionArchiveError.invalidLine(2)) { try decode([header, "not json"]) }
        #expect(throws: AgentSessionArchiveError.invalidLine(2)) { try decode([header, #"{"type":"plain"}"#]) }
        #expect(throws: AgentSessionArchiveError.invalidLine(1)) { try decode([#"{"type":"kurn.record","data":1}"#, header]) }
        #expect(throws: AgentSessionArchiveError.notAnArchive) { try decode([]) }

        // A graph that does not hold: another session's entry, a missing parent, a missing leaf.
        struct Line: Encodable {
            let type = "entry"
            let entry: AgentSessionEntry
        }
        func line(_ entry: AgentSessionEntry) throws -> String {
            String(decoding: try JSONEncoder().encode(Line(entry: entry)), as: UTF8.self)
        }
        let first = try entry("q1", parent: nil, ordinal: 1, message("q1", .user, "Q"))
        let leafed = #"{"type":"session","format":"kurn.agent-session","version":1,"sessionID":"session","leafID":"q1"}"#
        #expect(try decode([leafed, line(first)]).entries.count == 1)
        #expect(throws: AgentSessionArchiveError.invalidGraph) {
            try decode([leafed, line(entry("q1", parent: nil, ordinal: 1, message("q1", .user, "Q"), session: "other"))])
        }
        #expect(throws: AgentSessionArchiveError.invalidGraph) {
            try decode([leafed, line(first), line(entry("a1", parent: "missing", ordinal: 2, message("a1", .assistant, "A")))])
        }
        #expect(throws: AgentSessionArchiveError.invalidGraph) { try decode([header, line(first)]) }

        // Payloads past the limits.
        var limits = AgentSessionArchive.Limits()
        limits.maximumDepth = 4
        let deep = #"{"type":"kurn.record","data":{"a":{"b":{"c":{"d":1}}}}}"#
        #expect(throws: AgentSessionArchiveError.tooDeep) { try decode([header, deep], limits: limits) }
        limits = AgentSessionArchive.Limits()
        limits.maximumLineBytes = 64
        #expect(throws: AgentSessionArchiveError.tooLarge) { try decode([header], limits: limits) }
        limits = AgentSessionArchive.Limits()
        limits.maximumTotalBytes = 10
        #expect(throws: AgentSessionArchiveError.tooLarge) { try decode([header], limits: limits) }
        #expect(throws: AgentSessionArchiveError.invalidRecord) {
            try AgentSessionArchive(sessionID: "s", leafID: nil, entries: [], records: [.init(type: "entry", data: .null)])
        }
    }
}
