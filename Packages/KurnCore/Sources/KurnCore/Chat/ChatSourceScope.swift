import Foundation

public enum ChatSourcePart: String, Codable, Sendable, CaseIterable {
    case transcript, summary, wiki, attachments
    /// The meeting's compiled knowledge, read through the Ask knowledge tools (K5.3).
    case knowledge
}

public struct ChatSourceScope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case meetings, tags, folders, library }
    public static let defaultParts: Set<ChatSourcePart> = [.transcript, .summary, .attachments, .knowledge]

    public var kind: Kind
    public var selectedIDs: Set<UUID>
    public var parts: Set<ChatSourcePart>
    public var partOverrides: [UUID: Set<ChatSourcePart>]

    public init(kind: Kind, selectedIDs: Set<UUID> = [], parts: Set<ChatSourcePart> = Self.defaultParts,
                partOverrides: [UUID: Set<ChatSourcePart>] = [:]) {
        self.kind = kind
        self.selectedIDs = selectedIDs
        self.parts = parts
        self.partOverrides = partOverrides
    }

    public init(kind: Kind, selectedIDs: Set<UUID> = [], includeWikis: Bool) {
        self.init(kind: kind, selectedIDs: selectedIDs,
                  parts: includeWikis ? Self.defaultParts.union([.wiki]) : Self.defaultParts)
    }

    /// Legacy access to the global wiki selection; meeting overrides are unchanged.
    public var includeWikis: Bool {
        get { parts.contains(.wiki) }
        set {
            if newValue { parts.insert(.wiki) } else { parts.remove(.wiki) }
        }
    }

    public func parts(for meetingID: UUID) -> Set<ChatSourcePart> {
        partOverrides[meetingID] ?? parts
    }

    private enum CodingKeys: String, CodingKey {
        case kind, selectedIDs, parts, partOverrides, includeWikis, knowledgeSelectable
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        selectedIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .selectedIDs) ?? []
        if let selection = try values.decodeIfPresent(Set<ChatSourcePart>.self, forKey: .parts) {
            parts = selection
        } else {
            let wiki = try values.decodeIfPresent(Bool.self, forKey: .includeWikis) ?? false
            parts = wiki ? Self.defaultParts.union([.wiki]) : Self.defaultParts
        }
        partOverrides = try values.decodeIfPresent([UUID: Set<ChatSourcePart>].self, forKey: .partOverrides) ?? [:]
        // Scopes saved before knowledge was a part offered knowledge wherever it was authorized;
        // an empty selection (an excluded meeting, or no parts) stays empty.
        if try values.decodeIfPresent(Bool.self, forKey: .knowledgeSelectable) != true {
            if !parts.isEmpty { parts.insert(.knowledge) }
            partOverrides = partOverrides.mapValues { $0.isEmpty ? $0 : $0.union([.knowledge]) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(selectedIDs, forKey: .selectedIDs)
        try values.encode(parts, forKey: .parts)
        try values.encode(partOverrides, forKey: .partOverrides)
        try values.encode(true, forKey: .knowledgeSelectable)
    }
}
