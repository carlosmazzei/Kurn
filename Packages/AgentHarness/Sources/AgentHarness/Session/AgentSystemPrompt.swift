import Foundation

/// A system prompt as ordered, named sections (NH06). The model receives `text`; the session
/// records each run's prompt as a patch on the previous run's (`AgentSystemPatch`), so a stable
/// section keeps a stable prefix and a section that changed — a document index after a mutation,
/// say — is the only thing a run records.
public struct AgentSystemPrompt: Codable, Sendable, Equatable {
    public struct Section: Codable, Sendable, Equatable {
        public let name: String
        public let text: String
        public init(name: String, text: String) { self.name = name; self.text = text }
    }

    public private(set) var sections: [Section]

    /// Section names must be valid IDs and unique.
    public init(sections: [Section]) throws {
        guard sections.allSatisfy({ AgentContentMessage.validID($0.name) }),
              Set(sections.map(\.name)).count == sections.count else { throw AgentSessionStoreError.invalidEntry }
        self.sections = sections
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sections: value.decode([Section].self, forKey: .sections))
    }

    /// The prompt the model receives: the sections in order, separated by a blank line.
    public var text: String { sections.map(\.text).joined(separator: "\n\n") }

    /// The patch that turns this prompt into `next`: each changed or added section with its text
    /// and each removed one with none, in `next`'s order then removals.
    public func patch(to next: AgentSystemPrompt) -> AgentSystemPatch {
        let current = Dictionary(uniqueKeysWithValues: sections.map { ($0.name, $0.text) })
        let names = Set(next.sections.map(\.name))
        var changes = next.sections.filter { current[$0.name] != $0.text }.map { AgentSystemPatch.Change(name: $0.name, text: $0.text) }
        changes += sections.filter { !names.contains($0.name) }.map { AgentSystemPatch.Change(name: $0.name, text: nil) }
        return AgentSystemPatch(changes: changes)
    }

    /// This prompt with `patch` applied: a changed section keeps its place, a new one is added
    /// at the end and one without text is removed. Every other section is left as it is.
    public func applying(_ patch: AgentSystemPatch) -> AgentSystemPrompt {
        var result = self
        for change in patch.changes {
            if let index = result.sections.firstIndex(where: { $0.name == change.name }) {
                if let text = change.text { result.sections[index] = Section(name: change.name, text: text) }
                else { result.sections.remove(at: index) }
            } else if let text = change.text {
                result.sections.append(Section(name: change.name, text: text))
            }
        }
        return result
    }
}

/// Section changes from one system prompt to the next. A change without text removes its section.
public struct AgentSystemPatch: Codable, Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public let name: String
        public let text: String?
        public init(name: String, text: String?) { self.name = name; self.text = text }

        public func encode(to encoder: any Encoder) throws {
            var value = encoder.container(keyedBy: CodingKeys.self)
            try value.encode(name, forKey: .name)
            // An explicit null, not an omitted key: null is what removes a section.
            try value.encode(text, forKey: .text)
        }
    }

    public let changes: [Change]
    public init(changes: [Change]) { self.changes = changes }
    public var isEmpty: Bool { changes.isEmpty }
}

/// The tools a run declared and how that differs from the previous run's (NH06), recorded in its
/// start entry so each run's declared loadout and its delta can be read back from the log.
public struct AgentToolLoadout: Codable, Sendable, Equatable {
    /// The declared tool names, in declaration order.
    public let names: [String]
    /// Names declared now that the previous run did not declare, and the reverse.
    public let added: [String]
    public let removed: [String]

    public init(names: [String], previous: [String]?) {
        self.names = names
        let before = Set(previous ?? [])
        added = names.filter { !before.contains($0) }
        let now = Set(names)
        removed = (previous ?? []).filter { !now.contains($0) }
    }
}

extension AgentRunBranch {
    /// The system prompt the run recorded: its full prompt, or its patch applied to `previous`.
    /// Nil when the run recorded neither, or only a patch with nothing to apply it to.
    public func systemPrompt(after previous: AgentSystemPrompt?) -> AgentSystemPrompt? {
        if let full = Self.decode(AgentSystemPrompt.self, startFields["system"]) { return full }
        guard let patch = Self.decode(AgentSystemPatch.self, startFields["systemPatch"]), let previous else { return nil }
        return previous.applying(patch)
    }

    /// The tool loadout the run recorded, if any.
    public var toolLoadout: AgentToolLoadout? { Self.decode(AgentToolLoadout.self, startFields["tools"]) }

    /// The model capability snapshot the run started with (NH07), if it recorded one.
    public var capabilities: AgentModelCapabilities? { Self.decode(AgentModelCapabilities.self, startFields["capabilities"]) }

    /// Each run's system prompt in order, folding every recorded patch onto the one before.
    public static func systemPrompts(of runs: [AgentRunBranch]) -> [AgentSystemPrompt?] {
        var previous: AgentSystemPrompt?
        return runs.map { run in
            let prompt = run.systemPrompt(after: previous)
            if let prompt { previous = prompt }
            return prompt
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ value: JSONValue?) -> Value? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
