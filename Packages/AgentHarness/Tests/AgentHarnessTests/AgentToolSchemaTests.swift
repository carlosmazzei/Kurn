import Foundation
import Testing
@testable import AgentHarness

@Suite struct AgentToolSchemaTests {
    private let schema = #"""
    {"type":"object","properties":{
      "id":{"type":"string","format":"uuid"},"text":{"type":"string","minLength":2,"maxLength":3},
      "n":{"type":"integer","minimum":0,"maximum":2},
      "values":{"type":"array","items":{"type":"number","enum":[1,2]},"minItems":1,"maxItems":2},
      "flag":{"type":"boolean"},"empty":{"type":"null"}},"required":["text"],"additionalProperties":false}
    """#

    @Test(arguments: [#"{"text":"é🙂","id":"73A516A8-43F8-4CBE-9DB1-8209B0D23F12","n":2,"values":[1,2],"flag":true,"empty":null}"#, #"{"text":"ab"}"#])
    func validArguments(raw: String) throws { try AgentToolSchema(JSONValue.parse(schema)).validate(JSONValue.parse(raw)) }

    @Test(arguments: ["null", "[]", "{}", #"{"text":"a"}"#, #"{"text":"abcd"}"#, #"{"text":"ab","unknown":1}"#,
        #"{"text":"ab","id":"invalid"}"#, #"{"text":"ab","n":1.5}"#, #"{"text":"ab","n":-1}"#, #"{"text":"ab","n":3}"#,
        #"{"text":"ab","n":"1"}"#, #"{"text":"ab","values":[]}"#, #"{"text":"ab","values":[1,1,1]}"#,
        #"{"text":"ab","values":[3]}"#, #"{"text":"ab","flag":1}"#, #"{"text":"ab","empty":false}"#])
    func invalidArguments(raw: String) throws {
        let checked = try AgentToolSchema(JSONValue.parse(schema))
        #expect(throws: AgentToolSchemaError.invalidArguments) { try checked.validate(JSONValue.parse(raw)) }
    }

    @Test(arguments: ["{}", #"{"type":"object"}"#, #"{"type":"string"}"#,
        #"{"type":"object","properties":{},"additionalProperties":false,"$ref":"x"}"#,
        #"{"type":"object","properties":{},"additionalProperties":false,"required":["missing"]}"#,
        #"{"type":"object","properties":{"x":{"type":"string","pattern":".*"}},"additionalProperties":false}"#,
        #"{"type":"object","properties":{"x":{"type":"string","format":"date"}},"additionalProperties":false}"#,
        #"{"type":"object","properties":{"x":{"type":"array"}},"additionalProperties":false}"#,
        #"{"type":"object","properties":{"x":{"type":"integer","minimum":3,"maximum":2}},"additionalProperties":false}"#,
        #"{"type":"object","properties":{"x":{"type":"string","minLength":-1}},"additionalProperties":false}"#,
        #"{"type":"object","properties":{"x":{"type":"boolean","enum":[true,true]}},"additionalProperties":false}"#,
        #"{"type":"object","properties":{"x":{"type":"boolean","enum":[1]}},"additionalProperties":false}"#])
    func unsupportedSchemasFailAtRegistration(raw: String) throws {
        #expect(throws: AgentToolSchemaError.invalidSchema) { try AgentToolSchema(JSONValue.parse(raw)) }
    }

    @Test func duplicateAndInvalidNamesFailBeforeModelRequest() async throws {
        #expect(throws: AgentToolSchemaError.duplicateName) { try AgentToolRegistry([agentTool(), agentTool()]) }
        let bad = AgentTool(spec: AgentToolSpec(name: "bad-name", description: "", inputSchema: agentTool().spec.inputSchema)) { _ in
            AgentToolOutput(content: "", summary: "")
        }
        #expect(throws: AgentToolSchemaError.invalidName) { try AgentToolRegistry([bad]) }
        let model = ScriptedAgentModel([])
        do { _ = try await agentEvents(NativeHarness(model: model), tools: [agentTool(), agentTool()]); Issue.record("Expected registration failure") }
        catch { #expect(error as? AgentToolSchemaError == .duplicateName) }
        #expect(await model.requests.isEmpty)
    }
}
