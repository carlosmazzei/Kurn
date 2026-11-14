import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentPartialJSONTests {
    private func value(_ text: String) -> JSONValue? { AgentPartialJSON.parse(text) }

    @Test func aStringValueCutOffKeepsWhatArrived() {
        #expect(value(#"{"title":"Ata de reu"#) == .object(["title": .string("Ata de reu")]))
        #expect(value(#"{"title":"Ata","markdown":"# Min"#) == .object(["title": .string("Ata"), "markdown": .string("# Min")]))
        #expect(value(#""abc"#) == .string("abc"))
    }

    @Test func aKeyWithoutItsValueIsLeftOut() {
        #expect(value(#"{"title":"Ata","mark"#) == .object(["title": .string("Ata")]))
        #expect(value(#"{"title":"Ata","markdown""#) == .object(["title": .string("Ata")]))
        #expect(value(#"{"title":"Ata","markdown":"#) == .object(["title": .string("Ata")]))
        #expect(value(#"{"title":"Ata","#) == .object(["title": .string("Ata")]))
        #expect(value("{") == .object([:]))
    }

    @Test func numbersAndLiteralsCountOnceWhole() {
        #expect(value(#"{"limit":12"#) == .object(["limit": .number(12)]))
        #expect(value(#"{"limit":12,"#) == .object(["limit": .number(12)]))
        #expect(value(#"{"on":tr"#) == .object([:]))
        #expect(value(#"{"on":true"#) == .object(["on": .bool(true)]))
    }

    @Test func nestedContainersAreClosed() {
        #expect(value(#"{"a":[1,2,{"b":"c"#) == .object(["a": .array([.number(1), .number(2), .object(["b": .string("c")])])]))
        #expect(value(#"{"a":[1,"#) == .object(["a": .array([.number(1)])]))
        #expect(value(#"{"a":{"b":1}}"#) == .object(["a": .object(["b": .number(1)])]))
    }

    @Test func aHalfEscapeIsLeftOut() {
        #expect(value(#"{"q":"line\"#) == .object(["q": .string("line")]))
        #expect(value(#"{"q":"a\u00"#) == .object(["q": .string("a")]))
        #expect(value(#"{"q":"aéb"#) == .object(["q": .string("aéb")]))
        #expect(value(#"{"q":"say \"hi"#) == .object(["q": .string("say \"hi")]))
    }

    @Test func nothingWholeIsNil() {
        #expect(value("") == nil)
        #expect(value("   ") == nil)
        #expect(value("tr") == nil)
    }

    @Test func aSnapshotShowsACallWhileItsArgumentsStream() throws {
        var snapshot = AgentRunSnapshot()
        snapshot.apply(.runStarted)
        snapshot.apply(.turnStarted(index: 0))
        let call = AgentToolCall(id: "c1", name: "create_", arguments: .null, rawArguments: "")
        snapshot.apply(.modelContent(.blockStarted(index: 0, block: AgentContentBlock(id: "b1", content: .toolCall(call, complete: false)))))
        snapshot.apply(.modelContent(.blockDelta(id: "b1", delta: .toolCall(id: nil, name: "document", arguments: #"{"title":"Ata"#))))
        snapshot.apply(.modelContent(.blockDelta(id: "other", delta: .toolCall(id: nil, name: nil, arguments: "x"))))
        let streaming = try #require(snapshot.streamingToolCalls.first)
        #expect(snapshot.streamingToolCalls.count == 1)
        #expect(streaming.name == "create_document")
        #expect(streaming.arguments == .object(["title": .string("Ata")]))
        #expect(streaming.step.kind == .tool && streaming.step.status == .running && streaming.step.toolName == "create_document")
        snapshot.apply(.modelContent(.blockDelta(id: "b1", delta: .toolCall(id: nil, name: nil, arguments: #" de reunião","#))))
        #expect(snapshot.streamingToolCalls.first?.arguments == .object(["title": .string("Ata de reunião")]))
        // Its row keeps one identity while it grows.
        #expect(snapshot.streamingToolCalls.first?.step.id == streaming.step.id)
        // Text and reasoning blocks are not calls.
        snapshot.apply(.modelContent(.blockStarted(index: 1, block: AgentContentBlock(id: "t", content: .text("Hi", signature: nil)))))
        #expect(snapshot.streamingToolCalls.count == 1)
        // Once the harness starts the call, the streaming row gives way to the real one.
        snapshot.apply(.toolStarted(callID: "c1", name: "create_document", arguments: .object([:])))
        #expect(snapshot.streamingToolCalls.isEmpty)
    }

    @Test func onlyTheFirstScalarsOfLongArgumentsAreParsed() {
        var snapshot = AgentRunSnapshot()
        let call = AgentToolCall(id: "c1", name: "create_document", arguments: .null, rawArguments: #"{"title":"T","markdown":""#)
        snapshot.apply(.modelContent(.blockStarted(index: 0, block: AgentContentBlock(id: "b", content: .toolCall(call, complete: false)))))
        let body = String(repeating: "a", count: AgentRunSnapshot.StreamingToolCall.maxParsedScalars)
        snapshot.apply(.modelContent(.blockDelta(id: "b", delta: .toolCall(id: nil, name: nil, arguments: body))))
        snapshot.apply(.modelContent(.blockDelta(id: "b", delta: .toolCall(id: nil, name: nil, arguments: "more"))))
        guard case .object(let object)? = snapshot.streamingToolCalls.first?.arguments,
              case .string(let markdown)? = object["markdown"] else { Issue.record("No markdown"); return }
        #expect(object["title"] == .string("T"))
        #expect(markdown.count < AgentRunSnapshot.StreamingToolCall.maxParsedScalars)
        snapshot.apply(.modelContent(.failed(.cancelled)))
        #expect(snapshot.streamingToolCalls.isEmpty)
    }
}
