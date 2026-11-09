import Foundation

/// Fixed counts only. No reasoning, images, signatures or raw arguments enter diagnostic logs.
public struct AgentReplayAdjustment: Sendable, Equatable {
    public internal(set) var omittedMessages = 0
    public internal(set) var omittedThinkingBlocks = 0
    public internal(set) var omittedImages = 0
    public internal(set) var omittedNamespaces = 0
    public internal(set) var normalizedCallIDs = 0
    public internal(set) var sanitizedArguments = 0
    public internal(set) var strippedSignatures = 0
    public var hasChanges: Bool { diagnosticMetrics.values.contains { $0 > 0 } }
    var diagnosticMetrics: [AgentDiagnostic.Metric: Int] {
        [.omittedMessages: omittedMessages, .omittedThinkingBlocks: omittedThinkingBlocks, .omittedImages: omittedImages, .omittedNamespaces: omittedNamespaces,
         .normalizedCallIDs: normalizedCallIDs, .sanitizedArguments: sanitizedArguments, .strippedSignatures: strippedSignatures]
    }
}

public struct AgentWireRequestProjection: Sendable {
    public let body: JSONValue
    public let adjustment: AgentReplayAdjustment
}

extension AgentReplayProjection {
    mutating func recordOmissions(_ message: AgentContentMessage) {
        let compatible = compatible(message)
        for block in message.blocks {
            switch block.content {
            case .thinking(_, let signature, _, let metadata):
                let supported = compatible && ((format == .anthropic || format == .gemini) && signature != nil
                    || format == .openAIResponses && metadata?["type"].string == "reasoning")
                if !supported { adjustment.omittedThinkingBlocks += 1 }
            case .image:
                if message.role == .assistant && format != .gemini { adjustment.omittedImages += 1 }
            case .text(_, let signature):
                if signature != nil && (format != .gemini || !compatible) { adjustment.strippedSignatures += 1 }
            case .toolCall(let call, _):
                if !compatible && call.providerMetadata?["thoughtSignature"].string != nil { adjustment.strippedSignatures += 1 }
            }
        }
    }
}
