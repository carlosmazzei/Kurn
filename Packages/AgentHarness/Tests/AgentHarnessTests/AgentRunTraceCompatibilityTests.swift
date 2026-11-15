import Foundation
import Testing
@testable import AgentHarness

struct AgentRunTraceCompatibilityTests {
    @Test func savedKurnStepsDecodeWithoutAnApplicationModule() throws {
        // The persisted ChatAgentStep JSON shape predates the move to AgentHarness.
        let json = #"""
        [
          {"id":"00000000-0000-0000-0000-000000000001","kind":"tool","status":"finished",
           "callID":"read-1","toolName":"read_transcript","arguments":{"offset":0},"outputSummary":"Read"},
          {"id":"00000000-0000-0000-0000-000000000002","kind":"compaction","status":"finished",
           "beforeTokens":33000,"afterTokens":20000},
          {"id":"00000000-0000-0000-0000-000000000003","kind":"context","status":"finished",
           "contextResolution":{"id":"00000000-0000-0000-0000-000000000004","modelID":"gpt-6.1-terra",
             "contextWindowTokens":1050000,"limitKind":"combined","source":"fixed_table","isCached":false,
             "resolvedAt":800000000,"catalogVersion":"2026-11-08","reason":"catalogMatch"}},
          {"id":"00000000-0000-0000-0000-000000000005","kind":"stop","status":"finished","stopReason":"toolCallLimit"}
        ]
        """#
        let steps = try JSONDecoder().decode([AgentRunStep].self, from: Data(json.utf8))
        #expect(steps.map(\.kind) == [.tool, .compaction, .context, .stop])
        #expect(steps[0].arguments == .object(["offset": .number(0)]))
        #expect(steps[1].beforeTokens == 33_000)
        #expect(steps[2].contextResolution?.source == .fixedTable)
        #expect(steps[2].contextResolution?.contextWindowTokens == 1_050_000)
        #expect(steps[3].stopReason == .toolCallLimit)
        let encoded = try JSONEncoder().encode(steps)
        let before = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSArray
        let after = try JSONSerialization.jsonObject(with: encoded) as? NSArray
        #expect(before == after)
    }
}
