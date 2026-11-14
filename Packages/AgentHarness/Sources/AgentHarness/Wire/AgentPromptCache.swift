import Foundation

extension AgentWireFormat {
    static let ephemeralCache: JSONValue = .object(["type": .string("ephemeral")])

    /// Anthropic caches the prefix up to each `cache_control` breakpoint (tools, then system, then
    /// messages). Two of its four are used: the end of the system prompt, which also covers the
    /// tools and changes only when the prompt does, and the end of the conversation, so the next
    /// request in the loop reads everything before its new messages from the cache.
    static func markAnthropicCacheBreakpoints(_ body: inout [String: JSONValue]) {
        if let system = body["system"]?.string, !system.isEmpty {
            body["system"] = .array([.object(["type": .string("text"), "text": .string(system),
                                              "cache_control": ephemeralCache])])
        }
        guard case .array(var messages)? = body["messages"], let last = messages.indices.last,
              case .object(var message) = messages[last], case .array(var blocks)? = message["content"],
              let index = blocks.lastIndex(where: cacheable) else { return }
        guard case .object(var block) = blocks[index] else { return }
        block["cache_control"] = ephemeralCache
        blocks[index] = .object(block)
        message["content"] = .array(blocks)
        messages[last] = .object(message)
        body["messages"] = .array(messages)
    }

    /// Thinking blocks and empty text cannot carry a breakpoint.
    private static func cacheable(_ block: JSONValue) -> Bool {
        switch block["type"].string {
        case "text": return !(block["text"].string ?? "").isEmpty
        case "tool_result", "tool_use", "image", "document": return true
        default: return false
        }
    }
}
