import Foundation
import Testing
@testable import AgentHarness

struct AgentNativeCodecTests {
    @Test func nativeMessagesMatchIndependentGolden() throws {
        let url = try #require(Bundle.module.url(forResource: "nh02-native-v1", withExtension: "json", subdirectory: "Fixtures"))
        let source = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
        let data = try JSONEncoder().encode(source["messages"])
        let messages = try JSONDecoder().decode([AgentMessage].self, from: data)
        #expect(messages.count == 4)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(messages)) == source["messages"])
        guard case .content(let user) = messages[0], case .content(let assistant) = messages[1],
              case .tool(let result) = messages[2], case .content(let failure) = messages[3] else {
            Issue.record("Wrong native variants"); return
        }
        #expect(user.timestampMilliseconds == nil && user.text == "Decisão 🧭")
        #expect(assistant.timestampMilliseconds == 1_700_000_000_125 && assistant.toolCalls[0].rawArguments == "{invalid")
        #expect(assistant.toolCalls[0].argumentError == .invalidJSON && assistant.hasIncompleteCalls)
        #expect(result.invocation.id == assistant.toolCalls[0].invocationID && result.invocation.namespace == "bundled")
        #expect(result.timestampMilliseconds == 1_700_000_000_126 && result.syntheticReason == .outputLimit)
        #expect(result.details?["opaque"]["preserve"] == .array([.bool(true), .string("value")]))
        #expect(failure.stopReason == .aborted && failure.identity?.api == nil)
    }

    @Test(arguments: [Int64.min, -1, 1_700_000_000_125, Int64.max])
    func toolResultCodecPreservesMillisecondsAndCheckedDetails(milliseconds: Int64) throws {
        let invocation = try AgentToolInvocation(id: "logical", requestID: "request", callID: "wire", toolName: "lookup")
        let result = try AgentToolResultMessage(id: "result", timestampMilliseconds: milliseconds, invocation: invocation,
            blocks: [AgentContentBlock(id: "image", content: .image(mimeType: "image/png", base64: "AQ=="))], isError: false,
            details: .object(["opaque": .number(42)]))
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(AgentToolResultMessage.self, from: data) == result)
        var value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(var fields) = value else { Issue.record("Object expected"); return }
        fields["contractVersion"] = .number(2); value = .object(fields)
        #expect(throws: AgentContentError.unsupportedVersion) { try JSONDecoder().decode(AgentToolResultMessage.self, from: JSONEncoder().encode(value)) }
    }

    @Test func resultCodecRejectsInvalidLinkageBlocksAndSyntheticSuccess() throws {
        for id in ["", String(repeating: "é", count: 65)] {
            #expect(throws: AgentContentError.invalidMessage) { try AgentToolInvocation(id: id, requestID: "r", callID: "c", toolName: "lookup") }
            #expect(throws: AgentContentError.invalidMessage) { try AgentRequestIdentity(id: id) }
            #expect(throws: AgentContentError.invalidMessage) { try AgentRunContext(sessionID: id) }
        }
        let invocation = try AgentToolInvocation(id: "logical", requestID: "request", callID: "wire", toolName: "lookup")
        let invalidBlocks = [AgentContentBlock(id: "thinking", content: .thinking(text: "private", signature: nil, redacted: false)),
            AgentContentBlock(id: "call", content: .toolCall(agentCall(), complete: true)),
            AgentContentBlock(id: "image", content: .image(mimeType: "image/png", base64: "invalid!"))]
        for block in invalidBlocks {
            #expect(throws: AgentContentError.invalidMessage) {
                try AgentToolResultMessage(id: "result", timestampMilliseconds: nil, invocation: invocation, blocks: [block], isError: true)
            }
        }
        #expect(throws: AgentContentError.invalidMessage) {
            try AgentToolResultMessage(id: "result", timestampMilliseconds: nil, invocation: invocation, blocks: [], isError: false, syntheticReason: .toolCallLimit)
        }
        let call = AgentToolCall(id: "wire", name: "lookup", arguments: .object([:]), rawArguments: "{}", invocationID: "logical")
        let other = AgentToolCall(id: "other", name: "lookup", arguments: .object([:]), rawArguments: "{}", invocationID: "logical")
        #expect(throws: AgentContentError.invalidMessage) {
            try contentMessage([AgentContentBlock(id: "one", content: .toolCall(call, complete: true)),
                                AgentContentBlock(id: "two", content: .toolCall(other, complete: true))])
        }
    }
}
