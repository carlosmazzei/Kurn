import Foundation

/// The tree of a session's append log, read as values (NH09). A session keeps every branch: an
/// entry is never rewritten or removed, a new branch is new entries under an older one, and the
/// selected leaf picks which path is the conversation. Runs (`AgentRunBranch`) hang off the
/// question they answer and never move the leaf; detached metadata (labels, context edits) has
/// no parent and is not on any path.
///
/// Navigation, fork and clone are built here and committed by the host: navigation changes only
/// the leaf, while fork and clone copy entries into a new session, so the source keeps its tree.
public struct AgentSessionTree: Sendable {
    /// A label on an entry, appended as detached metadata; a nil label removes it.
    public struct Label: Codable, Sendable, Equatable {
        public static let entryType = "agent.label.v1"
        public let targetID: String
        public let label: String?
        public init(targetID: String, label: String?) { self.targetID = targetID; self.label = label }
    }

    public let sessionID: String
    public let entries: [AgentSessionEntry]
    public let leafID: String?
    private let byID: [String: AgentSessionEntry]
    private let children: [String: [AgentSessionEntry]]

    public init(_ snapshot: AgentSessionSnapshot) throws {
        let graph = try AgentEntryGraph(sessionID: snapshot.sessionID, entries: snapshot.entries, leafID: snapshot.leafID)
        sessionID = snapshot.sessionID
        entries = graph.entries
        leafID = snapshot.leafID
        byID = Dictionary(uniqueKeysWithValues: graph.entries.map { ($0.id, $0) })
        children = Dictionary(grouping: graph.entries.filter { $0.parentID != nil }, by: { $0.parentID ?? "" })
    }

    /// The selected path, root first.
    public var activePath: [AgentSessionEntry] { path(to: leafID) }

    /// The path from the root to `entryID`, root first; empty for nil.
    public func path(to entryID: String?) -> [AgentSessionEntry] {
        var path: [AgentSessionEntry] = []
        var cursor = entryID
        while let id = cursor, let entry = byID[id] {
            path.append(entry)
            cursor = entry.parentID
        }
        return path.reversed()
    }

    public func entry(_ id: String) -> AgentSessionEntry? { byID[id] }

    /// Whether `entry` belongs to a run's branch rather than to the conversation's own tree.
    public static func isRunEntry(_ entry: AgentSessionEntry) -> Bool { entry.runID != nil }

    /// The conversation's message entries that stand in `entryID`'s place: every message entry,
    /// outside runs, whose nearest message ancestor is the same as `entryID`'s and whose role is
    /// the same, `entryID` included, oldest first. One element when there is no alternative.
    public func alternatives(of entryID: String) -> [String] {
        guard let entry = byID[entryID], !Self.isRunEntry(entry), case .message(let message) = entry.payload else { return [] }
        let anchor = messageAncestor(of: entry)
        return entries.filter { candidate in
            guard !Self.isRunEntry(candidate), case .message(let other) = candidate.payload else { return false }
            return Self.role(other) == Self.role(message) && messageAncestor(of: candidate) == anchor
        }.map(\.id)
    }

    /// The leaf a navigation to `entryID` selects: the newest conversation entry (outside runs)
    /// in its subtree that has no conversation child, so the branch opens where it was left.
    public func latestLeaf(under entryID: String) -> String? {
        guard let start = byID[entryID] else { return nil }
        var newest = start
        var stack = [start]
        while let entry = stack.popLast() {
            let next = (children[entry.id] ?? []).filter { !Self.isRunEntry($0) }
            if next.isEmpty, entry.ordinal > newest.ordinal || newest.id == entryID { newest = entry }
            stack += next
        }
        return newest.id
    }

    /// The commit that selects `leafID` and changes nothing else, checked against `revision`.
    public func navigation(to leafID: String, expectedRevision: Int) throws -> AgentSessionCommit {
        guard let entry = byID[leafID], !Self.isRunEntry(entry) else { throw AgentSessionStoreError.invalidGraph }
        return AgentSessionCommit(sessionID: sessionID, expectedRevision: expectedRevision, entries: [], leafID: leafID)
    }

    /// The entries of a new session holding the path to `throughID`: that path, every run that
    /// answered a question on it, labels on the copied entries and every context edit. Entry IDs,
    /// times, payloads and metadata are kept; ordinals are renumbered in the original order. A fork
    /// passes the entry before the user message it starts from; a clone passes the selected leaf.
    ///
    /// A run records its system prompt and tools relative to the run before it in the whole log,
    /// which may be on a branch the copy leaves out, so each copied run start records them again
    /// relative to the copied run before it: the first in full, the rest as patches.
    public func copy(through throughID: String?, into newSessionID: String) throws -> [AgentSessionEntry] {
        let copiedPath = Set(path(to: throughID).map(\.id))
        let runs = Set(entries.compactMap { entry -> String? in
            guard entry.kind == AgentRunBranch.startType, let parent = entry.parentID, copiedPath.contains(parent) else { return nil }
            return entry.runID
        })
        var kept = Set<String>()
        var copied: [AgentSessionEntry] = []
        for entry in entries {
            let keep: Bool
            if copiedPath.contains(entry.id) {
                keep = true
            } else if let runID = entry.runID {
                keep = runs.contains(runID) && entry.parentID.map(kept.contains) ?? false
            } else if entry.parentID == nil, entry.kind == Label.entryType {
                keep = Self.decode(Label.self, entry).map { kept.contains($0.targetID) } ?? false
            } else {
                keep = entry.parentID == nil && entry.kind == AgentContextEdit.entryType
            }
            guard keep else { continue }
            kept.insert(entry.id)
            copied.append(try AgentSessionEntry(sessionID: newSessionID, id: entry.id, parentID: entry.parentID,
                ordinal: copied.count + 1, createdAt: entry.createdAt, payload: entry.payload, metadata: entry.metadata))
        }
        return try rebasingRunStarts(copied)
    }

    /// `copied` with each run start's system prompt and tool loadout recorded relative to the
    /// copied run before it, as the source log resolved them.
    private func rebasingRunStarts(_ copied: [AgentSessionEntry]) throws -> [AgentSessionEntry] {
        let sourceRuns = AgentRunBranch.all(in: entries)
        let prompts = Dictionary(uniqueKeysWithValues: zip(sourceRuns.map(\.runID), AgentRunBranch.systemPrompts(of: sourceRuns)))
        var previousPrompt: AgentSystemPrompt?
        var previousTools: [String]?
        return try copied.map { entry in
            guard entry.kind == AgentRunBranch.startType, let runID = entry.runID,
                  case .custom(let type, .object(var fields)) = entry.payload else { return entry }
            if let loadout = AgentRunBranch.decode(AgentToolLoadout.self, fields["tools"]) {
                fields["tools"] = try Self.json(AgentToolLoadout(names: loadout.names, previous: previousTools))
                previousTools = loadout.names
            }
            if let prompt = prompts[runID] ?? nil {
                fields["system"] = nil
                fields["systemPatch"] = nil
                // A patch cannot reorder sections, so a prompt it does not reproduce is recorded in full.
                if let previousPrompt, previousPrompt.applying(previousPrompt.patch(to: prompt)) == prompt {
                    fields["systemPatch"] = try Self.json(previousPrompt.patch(to: prompt))
                } else {
                    fields["system"] = try Self.json(prompt)
                }
                previousPrompt = prompt
            }
            return try AgentSessionEntry(sessionID: entry.sessionID, id: entry.id, parentID: entry.parentID, ordinal: entry.ordinal,
                createdAt: entry.createdAt, payload: .custom(type: type, data: .object(fields)), metadata: entry.metadata)
        }
    }

    private static func json<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// The newest label on each labelled entry; a removed label leaves no key.
    public var labels: [String: String] {
        var labels: [String: String] = [:]
        for entry in entries where entry.kind == Label.entryType {
            guard let label = Self.decode(Label.self, entry) else { continue }
            labels[label.targetID] = label.label
        }
        return labels
    }

    /// The detached entry that labels `targetID` (nil removes its label).
    public func labelEntry(_ label: String?, on targetID: String, id: String = UUID().uuidString,
                           createdAt: String = AgentSessionEntry.time()) throws -> AgentSessionEntry {
        guard byID[targetID] != nil else { throw AgentSessionStoreError.invalidGraph }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Label(targetID: targetID, label: trimmed?.isEmpty == false ? trimmed : nil)
        let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        return try AgentSessionEntry(sessionID: sessionID, id: id, parentID: nil, ordinal: entries.count + 1,
                                     createdAt: createdAt, payload: .custom(type: Label.entryType, data: data))
    }

    /// Usage recorded in the session: every branch's runs (`.session`), or only the runs that
    /// answered a question on the selected path (`.activePath`). Nil when nothing was recorded.
    public enum UsageScope: Sendable { case session, activePath }

    public func usage(_ scope: UsageScope) -> AgentUsage? {
        let onPath = Set(activePath.map(\.id))
        let runs = Set(entries.compactMap { entry -> String? in
            guard entry.kind == AgentRunBranch.startType, let runID = entry.runID else { return nil }
            if case .activePath = scope, !(entry.parentID.map(onPath.contains) ?? false) { return nil }
            return runID
        })
        var total: AgentUsage?
        var counted = Set<String>()
        for entry in entries where entry.kind == "agent.usage.v1" {
            guard let runID = entry.runID, runs.contains(runID),
                  case .custom(_, let data) = entry.payload, let usage = Self.usage(data),
                  AgentUsageEntry.isFirst(data, of: runID, among: &counted) else { continue }
            total = total.map { $0.adding(usage) } ?? usage
        }
        return total
    }

    // MARK: - Helpers

    private func messageAncestor(of entry: AgentSessionEntry) -> String? {
        var cursor = entry.parentID
        while let id = cursor, let parent = byID[id] {
            if case .message = parent.payload, !Self.isRunEntry(parent) { return id }
            cursor = parent.parentID
        }
        return nil
    }

    private static func role(_ message: AgentMessage) -> String {
        switch message {
        case .content(let value): value.role.rawValue
        case .tool: "tool"
        case .user: "user"
        case .assistant: "assistant"
        case .toolResult: "tool"
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ entry: AgentSessionEntry) -> Value? {
        guard case .custom(_, let data) = entry.payload else { return nil }
        return AgentRunBranch.decode(type, data)
    }

    private static func usage(_ data: JSONValue) -> AgentUsage? {
        guard case .object(let fields) = data,
              let input = count(fields["inputTokens"]), let output = count(fields["outputTokens"]) else { return nil }
        return AgentUsage(inputTokens: input, outputTokens: output, reasoningTokens: count(fields["reasoningTokens"]),
                          cacheReadTokens: count(fields["cacheReadTokens"]), cacheWriteTokens: count(fields["cacheWriteTokens"]))
    }

    private static func count(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite, number >= 0, number <= Double(Int32.max),
              number.rounded() == number else { return nil }
        return Int(number)
    }
}
