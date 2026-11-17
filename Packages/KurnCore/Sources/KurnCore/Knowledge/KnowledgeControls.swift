import Foundation

/// User-owned local preferences, separate from canonical data and organization
/// policy. A scope label never widens a source ACL or permits remote processing.
public struct KnowledgeControls: Codable, Equatable, Sendable {
    public var version = 1
    public var revision = 1
    public var generation = "initial"
    public var automaticCompilation = false
    public var isPaused = false
    public var providerID = "apple-on-device"
    /// nil = all meetings, empty = none; exclusions always win.
    public var includedMeetingIDs: Set<UUID>?
    public var excludedMeetingIDs: Set<UUID> = []

    public init() {}

    public func allows(_ meetingID: UUID) -> Bool {
        (includedMeetingIDs?.contains(meetingID) ?? true) && !excludedMeetingIDs.contains(meetingID)
    }

    public mutating func setAllMeetings(_ all: Bool) { includedMeetingIDs = all ? nil : [] }

    public mutating func toggleMeeting(_ id: UUID) {
        if allows(id) {
            if includedMeetingIDs == nil { excludedMeetingIDs.insert(id) }
            else { includedMeetingIDs?.remove(id) }
        } else {
            if includedMeetingIDs != nil { includedMeetingIDs?.insert(id) }
            excludedMeetingIDs.remove(id)
        }
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw KnowledgeControlsError.unsupportedVersion }
        guard revision > 0, revision < Int.max, !providerID.isEmpty, providerID.utf8.count <= 128,
              generation == "initial" || UUID(uuidString: generation) != nil,
              (includedMeetingIDs?.count ?? 0) <= 10_000, excludedMeetingIDs.count <= 10_000 else {
            throw KnowledgeControlsError.invalidControls
        }
        return self
    }

    public func encoded() throws -> Data {
        _ = try validated()
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw KnowledgeControlsError.invalidControls }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

public enum KnowledgeControlsError: String, Error, Sendable {
    case invalidControls, unsupportedVersion, staleControls
}
