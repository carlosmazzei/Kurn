import Foundation
import Testing
@testable import AgentHarness

final class ContentEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AgentModelEvent] = []
    func append(_ event: AgentModelEvent) { lock.withLock { storage.append(event) } }
    var events: [AgentModelEvent] { lock.withLock { storage } }
    var terminals: [AgentContentEvent] { events.compactMap {
        guard case .content(let content) = $0 else { return nil }
        switch content { case .messageFinished, .failed: return content; default: return nil }
    } }
}

func contentMessage(_ blocks: [AgentContentBlock], api: String = "anthropic", model: String? = "model",
                    stop: AgentModelStopReason = .endTurn, usage: AgentUsage? = nil) throws -> AgentContentMessage {
    try AgentContentMessage(id: "message", timestampMilliseconds: 1_700_000_000_125, role: .assistant, blocks: blocks,
        identity: AgentResponseIdentity(api: api, model: model, responseID: "response", requestID: "request"), stopReason: stop, usage: usage)
}

struct AgentContentContractTests {
    @Test(arguments: [Int64.min, -1, 1_700_000_000_125, Int64.max])
    func nativeCodecKeepsExactMillisecondsAndOpaqueFields(milliseconds: Int64) throws {
        let opaque: JSONValue = .object(["future": .array([.bool(true), .string("opaque==")])])
        let blocks = [AgentContentBlock(id: "thought", content: .thinking(text: nil, signature: "opaque==", redacted: true, metadata: opaque)),
                      AgentContentBlock(id: "text", content: .text("Decisão 🧭\u{2028}fim", signature: "signed"))]
        let message = try AgentContentMessage(id: "message", timestampMilliseconds: milliseconds, role: .assistant,
            blocks: blocks, stopReason: .deferred, providerMetadata: opaque)
        let data = try JSONEncoder().encode(AgentMessage.content(message))
        #expect(try JSONDecoder().decode(AgentMessage.self, from: data) == .content(message))
        #expect(message.text == "Decisão 🧭\u{2028}fim")
        let encoded = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        #expect(encoded.contains(String(milliseconds)))
        #expect(throws: AgentContentError.unsupportedVersion) {
            try JSONDecoder().decode(AgentContentMessage.self, from: Data(encoded.replacingOccurrences(of: "\"contractVersion\":1", with: "\"contractVersion\":2").utf8))
        }
    }

    @Test func invalidNativeIdentitiesRolesAndUnknownBlocksFailExplicitly() throws {
        let text = AgentContentBlock(id: "text", content: .text("One"))
        for id in ["", String(repeating: "é", count: 65)] {
            #expect(throws: AgentContentError.invalidMessage) {
                try AgentContentMessage(id: id, timestampMilliseconds: 0, role: .assistant, blocks: [text])
            }
        }
        #expect(throws: AgentContentError.invalidMessage) { try contentMessage([text, text]) }
        #expect(throws: AgentContentError.invalidMessage) {
            try AgentContentMessage(id: "user", timestampMilliseconds: 0, role: .user,
                blocks: [AgentContentBlock(id: "call", content: .toolCall(agentCall(), complete: true))])
        }
        let data = try JSONEncoder().encode(contentMessage([text]))
        let unknown = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"text\":", with: "\"futureBlock\":")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AgentContentMessage.self, from: Data(unknown.utf8)) }
        #expect(agentCall(raw: "{bad").argumentError == .invalidJSON)
        #expect(agentCall(raw: "null").argumentError == .nonObject)
        #expect(agentCall(raw: "{}").argumentError == nil)
    }

    @Test func reducerOrdersInterleavedBlocksAndFinalReplacesDeltasAndUsage() throws {
        var reducer = AgentMessageReducer()
        try reducer.apply(.blockStarted(index: 2, block: AgentContentBlock(id: "text", content: .text("draft"))))
        try reducer.apply(.blockStarted(index: 0, block: AgentContentBlock(id: "thought", content: .thinking(text: "", signature: nil, redacted: false))))
        try reducer.apply(.blockDelta(id: "thought", delta: .thinking("private")))
        try reducer.apply(.blockDelta(id: "thought", delta: .signature("signature")))
        try reducer.apply(.blockDelta(id: "text", delta: .text(" suffix")))
        try reducer.apply(.blockStarted(index: 1, block: AgentContentBlock(id: "call", content: .toolCall(agentCall(raw: ""), complete: false))))
        try reducer.apply(.blockDelta(id: "call", delta: .toolCall(id: "actual", name: nil, arguments: "{bad")))
        #expect(reducer.blocks.map(\.id) == ["thought", "call", "text"])
        let final = try contentMessage([AgentContentBlock(id: "replacement", content: .text("Authoritative answer"))], usage: AgentUsage(inputTokens: 12, outputTokens: 3))
        try reducer.apply(.messageFinished(final))
        try reducer.apply(.blockDelta(id: "text", delta: .text("late")))
        try reducer.apply(.failed(.transport))
        #expect(reducer.finalMessage == final && reducer.blocks == final.blocks && reducer.failure == nil)
        #expect(reducer.finalMessage?.usage == AgentUsage(inputTokens: 12, outputTokens: 3))
    }

    @Test func reducerBoundsMemoryAndRejectsInvalidTransitionsWithoutChangingPriorState() throws {
        var reducer = AgentMessageReducer(maxBytes: 256)
        let initial = AgentContentBlock(id: "text", content: .text("Start"))
        try reducer.apply(.blockStarted(index: 0, block: initial))
        #expect(throws: AgentContentError.unknownBlock) { try reducer.apply(.blockDelta(id: "missing", delta: .text("x"))) }
        #expect(throws: AgentContentError.invalidTransition) { try reducer.apply(.blockStarted(index: 0, block: initial)) }
        #expect(throws: AgentContentError.invalidTransition) { try reducer.apply(.blockDelta(id: "text", delta: .signature("wrong type"))) }
        #expect(throws: AgentContentError.bufferLimit) { try reducer.apply(.blockDelta(id: "text", delta: .text(String(repeating: "🧭", count: 100)))) }
        #expect(reducer.blocks == [initial])
        try reducer.apply(.failed(.preparation))
        try reducer.apply(.messageFinished(contentMessage([])))
        #expect(reducer.failure == .preparation && reducer.finalMessage == nil)
    }

    @Test(arguments: ["preparation", "transport", "cancelled", "success"])
    func providerBoundaryAlwaysEmitsOneTerminal(kind: String) async throws {
        let capture = ContentEventCapture()
        do {
            let response = try await AgentModelBoundary.perform(onEvent: { capture.append($0) }, prepare: { () throws -> Int in
                if kind == "preparation" { throw AgentWireError.invalidResponse }
                return 1
            }, stream: { _ in
                if kind == "cancelled" { throw CancellationError() }
                if kind == "transport" { throw AgentWireError.incompleteStream }
                return AgentTurnResponse(text: "Final", usage: AgentUsage(inputTokens: 3, outputTokens: 1))
            })
            #expect(kind == "success" && response.message?.text == "Final")
        } catch { #expect(kind != "success") }
        #expect(capture.terminals.count == 1)
        if kind == "preparation" { #expect(capture.terminals == [.failed(.preparation)]) }
        if kind == "cancelled" { #expect(capture.terminals == [.failed(.cancelled)]) }
    }
}
