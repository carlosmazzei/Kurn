import Foundation

extension AgentWireState {
    mutating func captureProviderFacts(_ value: JSONValue) {
        let envelope: JSONValue
        let keys: [String]
        switch format {
        case .anthropic:
            envelope = value["type"].string == "message_start" ? value["message"] : value
            keys = ["diagnostics", "thinking"]
        case .openAI:
            envelope = value
            keys = ["diagnostics", "reasoning_effort", "system_fingerprint"]
        case .openAIResponses:
            envelope = value["response"]
            keys = ["diagnostics", "reasoning", "incomplete_details"]
        case .gemini:
            envelope = value
            keys = ["diagnostics", "promptFeedback", "modelVersion"]
        }
        for key in keys where envelope[key] != .null { providerFacts[key] = envelope[key] }
    }
}
