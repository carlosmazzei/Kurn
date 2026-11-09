import Foundation

extension AgentMessage {
    /// A disposable legacy projection for old codecs and summary text, never a canonical writer.
    var legacyProjection: AgentMessage {
        guard case .content(let message) = self else { return self }
        switch message.role {
        case .user: return .user(message.text)
        case .assistant: return .assistant(text: message.text, toolCalls: message.toolCalls, providerMetadata: message.providerMetadata)
        }
    }
}
