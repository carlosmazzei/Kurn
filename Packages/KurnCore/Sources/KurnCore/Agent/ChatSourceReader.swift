import Foundation

public struct ChatSourceScope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case meetings, tags, folders, library }
    public var kind: Kind
    public var selectedIDs: Set<UUID>
    public var includeWikis: Bool

    public init(kind: Kind, selectedIDs: Set<UUID> = [], includeWikis: Bool = false) {
        self.kind = kind
        self.selectedIDs = selectedIDs
        self.includeWikis = includeWikis
    }
}

public struct ChatSourceAvailability: Codable, Sendable, Equatable {
    public let summary: Bool
    public let wiki: Bool
    public let attachments: Bool

    public init(summary: Bool = false, wiki: Bool = false, attachments: Bool = false) {
        self.summary = summary
        self.wiki = wiki
        self.attachments = attachments
    }
}

public struct ChatSource: Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let date: Date
    public let duration: Double
    public let tags: [String]
    public let folder: String?
    public let hasSummary: Bool
    public let hasWiki: Bool
    public let hasAttachments: Bool

    public init(id: UUID, title: String, date: Date, duration: Double, tags: [String] = [],
                folder: String? = nil, availability: ChatSourceAvailability = ChatSourceAvailability()) {
        self.id = id
        self.title = title
        self.date = date
        self.duration = duration
        self.tags = tags
        self.folder = folder
        self.hasSummary = availability.summary
        self.hasWiki = availability.wiki
        self.hasAttachments = availability.attachments
    }
}

public struct ChatSourcePassage: Codable, Sendable, Equatable {
    public let meetingID: UUID
    public let timestamp: Double
    public let speaker: String
    public let text: String

    public init(meetingID: UUID, timestamp: Double, speaker: String, text: String) {
        self.meetingID = meetingID
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
    }
}

public struct ChatTranscriptPage: Sendable {
    public let passages: [ChatSourcePassage]
    public let total: Int

    public init(passages: [ChatSourcePassage], total: Int) {
        self.passages = passages
        self.total = total
    }
}

public struct ChatSourceAttachment: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

public protocol ChatSourceReader: Sendable {
    func listSources() async throws -> [ChatSource]
    func search(query: String, meetingIDs: Set<UUID>, limit: Int) async throws -> [ChatSourcePassage]
    func readTranscript(meetingID: UUID, offset: Int, limit: Int) async throws -> ChatTranscriptPage
    func readSummary(meetingID: UUID) async throws -> String?
    func readWiki(meetingID: UUID) async throws -> String?
    func listAttachments(meetingID: UUID) async throws -> [ChatSourceAttachment]
    func readAttachment(meetingID: UUID, attachmentID: UUID) async throws -> String?
}
