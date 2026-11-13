import Foundation
import Testing
@testable import AgentHarness

/// NH06 context edits change only what later requests send, and never leave a call without its result.
@Suite struct AgentContextEditTests {
    private func text(_ id: String, _ role: AgentContentMessage.Role, _ value: String) throws -> AgentMessage {
        .content(try AgentContentMessage(id: id, timestampMilliseconds: nil, role: role,
                                         blocks: [AgentContentBlock(id: "text", content: .text(value))]))
    }

    private func call(_ id: String, callID: String) throws -> AgentMessage {
        let call = AgentToolCall(id: callID, name: "lookup", arguments: .object([:]), rawArguments: "{}", invocationID: "inv-\(callID)")
        return .content(try AgentContentMessage(id: id, timestampMilliseconds: nil, role: .assistant,
                                                blocks: [AgentContentBlock(id: "call", content: .toolCall(call, complete: true))],
                                                stopReason: .toolUse))
    }

    private func result(_ id: String, callID: String, _ value: String) throws -> AgentMessage {
        .tool(try AgentToolResultMessage(id: id, timestampMilliseconds: nil,
            invocation: AgentToolInvocation(id: "inv-\(callID)", requestID: "req", callID: callID, toolName: "lookup"),
            blocks: [AgentContentBlock(id: "text", content: .text(value))], isError: false))
    }

    private func conversation() throws -> [AgentMessage] {
        [try text("q1", .user, "Q1"), try call("a1", callID: "c1"), try result("r1", callID: "c1", "Large read"),
         try text("a2", .assistant, "Answer"), .user("Legacy"), try text("q2", .user, "Q2")]
    }

    @Test func removingACallRemovesItsResultsWithIt() throws {
        let edited = AgentContextEdit(removedMessageIDs: ["a1"]).applied(to: try conversation())
        #expect(edited.map(\.canonicalID) == ["q1", "a2", nil, "q2"])
    }

    @Test func aRemovedResultIsStubbedSoItsCallKeepsAResult() throws {
        let original = try conversation()
        let edited = AgentContextEdit(removedMessageIDs: ["r1"]).applied(to: original)
        #expect(edited.count == 6)
        guard case .tool(let stub) = edited[2] else { Issue.record("Expected the stub result"); return }
        #expect(stub.id == "r1" && stub.invocation.callID == "c1")
        #expect(stub.blocks.map(\.content) == [.text(AgentContextEdit.removedResult)])
        // Everything else is as it was; a name that matches nothing changes nothing.
        #expect(edited.enumerated().filter { $0.offset != 2 }.map(\.element)
            == original.enumerated().filter { $0.offset != 2 }.map(\.element))
        #expect(AgentContextEdit(removedMessageIDs: ["missing"]).applied(to: original) == original)
    }

    @Test func editsAreReadFromTheLogInCommitOrder() throws {
        func entry(_ ordinal: Int, _ ids: [String]) throws -> AgentSessionEntry {
            try AgentSessionEntry(sessionID: "s", id: "e\(ordinal)", parentID: ordinal == 1 ? nil : "e\(ordinal - 1)",
                ordinal: ordinal, createdAt: AgentSessionEntry.time(),
                payload: .custom(type: AgentContextEdit.entryType, data: .object([
                    "removedMessageIDs": .array(ids.map(JSONValue.string))
                ])))
        }
        let other = try AgentSessionEntry(sessionID: "s", id: "e3", parentID: "e2", ordinal: 3, createdAt: AgentSessionEntry.time(),
                                          payload: .custom(type: "host.state", data: .object([:])))
        let edits = AgentContextEdit.all(in: [other, try entry(2, ["r1"]), try entry(1, ["a2"])])
        #expect(edits.map(\.removedMessageIDs) == [["a2"], ["r1"]])
        let edited = AgentContextEdit.applying(edits, to: try conversation())
        #expect(edited.map(\.canonicalID) == ["q1", "a1", "r1", nil, "q2"])
    }
}
