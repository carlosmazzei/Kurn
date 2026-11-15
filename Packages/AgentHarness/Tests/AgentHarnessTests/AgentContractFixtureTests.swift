import Foundation
import Testing
@testable import AgentHarness

private struct LegacyRuntimeFixture: Decodable {
    let fixtureVersion: Int
    let baselineCommit: String
    let messages: [AgentMessage]
    let tools: [AgentToolSpec]
    let systemPrompt: String
    let model: String
    let maxOutputTokens: Int
    let expectedRequests: [String: JSONValue]
    let steps: [AgentRunStep]
    let invalidCall: AgentToolCall
    let usage: AgentUsage
    let modelStopReasons: [AgentModelStopReason]

    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "nh01-runtime-v1", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        #expect(fixture.fixtureVersion == 1)
        #expect(fixture.baselineCommit == "6ec656b93c6cf59cbc3dc32f9bd08e1abb1517ed")
        return fixture
    }
}

struct AgentContractFixtureTests {
    @Test func legacyMessagesPreserveOpaqueReplayDataAndInvalidRawArguments() throws {
        let fixture = try LegacyRuntimeFixture.load()
        let restored = try JSONDecoder().decode([AgentMessage].self, from: JSONEncoder().encode(fixture.messages))
        #expect(restored == fixture.messages)
        guard case .assistant(let text, let calls, let metadata) = restored[1] else {
            Issue.record("Missing fixture assistant"); return
        }
        #expect(text == "Looking up")
        #expect(calls.first?.id == "call-1")
        #expect(calls.first?.rawArguments == #"{"query":"decisão 🧭"}"#)
        #expect(calls.first?.providerMetadata?["thoughtSignature"].string == "opaque-gemini-signature==")
        #expect(metadata?["openAIResponses"]["reasoning"].array.first?["encrypted_content"].string == "opaque-reasoning==")
        #expect(metadata?["openAIResponses"]["reasoning"].array.first?["futureOpaqueField"]["preserve"] == .bool(true))
        let invalid = try JSONDecoder().decode(AgentToolCall.self, from: JSONEncoder().encode(fixture.invalidCall))
        #expect(invalid.rawArguments == #"{"query":"#)
        #expect(invalid.arguments == .null)
        #expect(fixture.modelStopReasons == [.endTurn, .toolUse, .maxTokens, .other("provider-specific")])
    }

    @Test(arguments: ["openAI", "openAIResponses", "anthropic", "gemini"])
    func providerRequestsMatchTheFrozenBaseline(name: String) throws {
        let fixture = try LegacyRuntimeFixture.load()
        let formats: [String: AgentWireFormat] = ["openAI": .openAI, "openAIResponses": .openAIResponses,
                                                "anthropic": .anthropic, "gemini": .gemini]
        #expect(formats.count == AgentWireFormat.allCases.count)
        let request = AgentTurnRequest(systemPrompt: fixture.systemPrompt, messages: fixture.messages,
                                       tools: fixture.tools, maxOutputTokens: fixture.maxOutputTokens)
        let actual = try #require(formats[name]).requestBody(request, model: fixture.model, reasoningEffort: "low")
        #expect(actual == fixture.expectedRequests[name])
    }

    @Test func savedTraceRetainsIdentityCapacityAndLegacyDateUnits() throws {
        let fixture = try LegacyRuntimeFixture.load()
        let restored = try JSONDecoder().decode([AgentRunStep].self, from: JSONEncoder().encode(fixture.steps))
        #expect(restored == fixture.steps)
        #expect(restored.map(\.kind) == [.context, .tool, .diagnostic, .stop])
        let resolution = try #require(restored[0].contextResolution)
        #expect(resolution.source == .fixedTable)
        #expect(resolution.contextWindowTokens == 1_050_000)
        #expect(resolution.maxOutputTokens == 128_000)
        // Legacy Codable Date is seconds since 2001; native v1's planned Unix-ms codec is separate.
        #expect(resolution.resolvedAt.timeIntervalSince1970 == 1_700_000_000.125)
        #expect(restored[2].diagnostic?.recordedAt == resolution.resolvedAt)
        #expect(restored[2].diagnostic?.metrics[.contextSafetyTokens] == 8_232)
        #expect(restored[3].stopReason == .completed)
        #expect(fixture.usage == AgentUsage(inputTokens: 123, outputTokens: 45, reasoningTokens: 12))
        let log = restored.compactMap(\.diagnostic).map(\.logLine).joined()
        #expect(!log.contains("opaque") && !log.contains("decisão"))
    }
}
