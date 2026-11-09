import Foundation
import Testing
@testable import AgentHarness

struct AgentNativeWireTests {
    @Test(arguments: AgentWireFormat.allCases)
    func namespaceAndPrivateProtocolFactsSurviveWireReduction(format: AgentWireFormat) throws {
        let payloads: [String]
        switch format {
        case .anthropic:
            payloads = [
                #"{"type":"message_start","message":{"id":"response","model":"test","diagnostics":{"private":"kept"},"thinking":{"budget_tokens":1024}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"lookup","namespace":"bundled","input":{}}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
                #"{"type":"message_stop"}"#
            ]
        case .openAI:
            payloads = [#"""
                {
                  "model": "test",
                  "id": "response",
                  "diagnostics": {
                    "private": "kept"
                  },
                  "reasoning_effort": "high",
                  "choices": [
                    {
                      "delta": {
                        "tool_calls": [
                          {
                            "index": 0,
                            "id": "call",
                            "function": {
                              "name": "lookup",
                              "namespace": "bundled",
                              "arguments": "{}"
                            }
                          }
                        ]
                      },
                      "finish_reason": "tool_calls"
                    }
                  ]
                }
                """#]
        case .openAIResponses:
            payloads = [#"""
                {
                  "type": "response.completed",
                  "response": {
                    "id": "response",
                    "model": "test",
                    "reasoning": {
                      "effort": "high"
                    },
                    "diagnostics": {
                      "private": "kept"
                    },
                    "output": [
                      {
                        "type": "function_call",
                        "call_id": "call",
                        "name": "lookup",
                        "namespace": "bundled",
                        "arguments": "{}"
                      }
                    ]
                  }
                }
                """#]
        case .gemini:
            payloads = [#"""
                {
                  "modelVersion": "test",
                  "responseId": "response",
                  "diagnostics": {
                    "private": "kept"
                  },
                  "candidates": [
                    {
                      "content": {
                        "parts": [
                          {
                            "functionCall": {
                              "id": "call",
                              "name": "lookup",
                              "namespace": "bundled",
                              "args": {}
                            }
                          }
                        ]
                      },
                      "finishReason": "STOP"
                    }
                  ]
                }
                """#]
        }
        let accumulator = AgentWireAccumulator(format: format, requestID: "owned-request")
        for payload in payloads { _ = try accumulator.consume(payload) }
        let message = try #require(accumulator.response().message)
        #expect(message.identity?.requestID == "owned-request")
        #expect(message.toolCalls.first?.namespace == "bundled")
        #expect(message.providerMetadata?["diagnostics"]["private"] == .string("kept"))
        #expect(try JSONDecoder().decode(AgentContentMessage.self, from: JSONEncoder().encode(message)) == message)
        let projection = format.requestProjection(AgentTurnRequest(systemPrompt: "", messages: [.content(message)], tools: [], maxOutputTokens: 32), model: "test")
        #expect(projection.adjustment.omittedNamespaces == 1)
        #expect(!String(describing: projection.body).contains("kept"))
    }

    @Test func conflictingProviderFinalBecomesOneFailedAudit() throws {
        let output = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let trace = AgentTraceEmitter(events: output.continuation, resolutionID: nil, sink: { _ in })
        let request = AgentRequestIdentity()
        let stream = AgentTurnStream(events: output.continuation, trace: trace, request: request, descriptor: nil)
        stream.consume(.content(.messageFinished(try contentMessage([AgentContentBlock(id: "text", content: .text("First"))]))))
        #expect(throws: AgentWireError.invalidResponse) { try stream.complete(AgentTurnResponse(text: "Conflicting")) }
        stream.fail(AgentWireError.invalidResponse)
        #expect(stream.failureMessage?.stopReason == .error && stream.failureMessage?.identity?.requestID == request.id)
        #expect(stream.failureCode == AgentStreamFailure.invalidStream.diagnosticCode)
        stream.consume(.textDelta("late"))
        #expect(!stream.hasVisibleText)
        output.continuation.finish()
    }

    @Test func cancellationAfterPublishedFinalDoesNotPublishSecondTerminal() async throws {
        let output = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let trace = AgentTraceEmitter(events: output.continuation, resolutionID: nil, sink: { _ in })
        let stream = AgentTurnStream(events: output.continuation, trace: trace, request: AgentRequestIdentity(), descriptor: nil)
        let accepted = try stream.complete(AgentTurnResponse(text: "Accepted", toolCalls: [agentCall()]))
        stream.fail(CancellationError())
        output.continuation.finish()
        var events: [AgentEvent] = []
        for try await event in output.stream { events.append(event) }
        #expect(stream.failureMessage == accepted.message)
        #expect(events.filter { if case .modelContent(.messageFinished) = $0 { return true }; return false }.count == 1)
        #expect(!events.contains { if case .modelContent(.failed) = $0 { return true }; return false })
    }

    @Test func correlationLogEscapesControlCharacters() {
        let value = AgentDiagnostic(runID: UUID(), sequence: 1, kind: .requestStarted,
            correlation: AgentDiagnosticCorrelation(sessionID: "opaque\nagent.fake", requestID: "request=other", invocationID: "id space"))
        #expect(!value.logLine.contains("\n"))
        #expect(value.logLine.contains("request=request%3Dother") && value.logLine.contains("invocation=id%20space"))
    }
}
