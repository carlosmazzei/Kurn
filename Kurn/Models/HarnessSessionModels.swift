import Foundation
import SwiftData

/// Indexed row fields are checked against the checksummed value envelope on every read.
@Model
final class HarnessSessionEntry {
    #Index<HarnessSessionEntry>([\.sessionID, \.ordinal], [\.sessionID, \.kindRaw, \.ordinal])
    @Attribute(.unique) var id: String
    var sessionID: UUID
    var entryID: String
    var parentEntryID: String?
    var kindRaw: String
    var createdAtUTC: String
    var ordinal: Int
    var payloadData: Data
    var session: ChatSession?

    init(session: ChatSession, entryID: String, parentEntryID: String?, ordinal: Int, kindRaw: String, createdAtUTC: String, payloadData: Data) {
        id = session.id.uuidString + ":" + entryID
        sessionID = session.id; self.session = nil; self.entryID = entryID
        self.parentEntryID = parentEntryID; self.ordinal = ordinal; self.kindRaw = kindRaw
        self.createdAtUTC = createdAtUTC; self.payloadData = payloadData
    }
}

@Model
final class HarnessArtifactRevision {
    #Index<HarnessArtifactRevision>([\.sessionID, \.artifactID, \.version])
    @Attribute(.unique) var id: String
    var sessionID: UUID
    var artifactID: UUID
    var version: Int
    var payloadData: Data
    var session: ChatSession?

    init(session: ChatSession, artifactID: UUID, version: Int, payloadData: Data) {
        id = session.id.uuidString + ":" + artifactID.uuidString + ":" + String(version)
        sessionID = session.id; self.session = nil; self.artifactID = artifactID
        self.version = version; self.payloadData = payloadData
    }
}

@Model
final class HarnessSessionRecord {
    #Index<HarnessSessionRecord>([\.sessionID, \.kindRaw])
    @Attribute(.unique) var id: String
    var sessionID: UUID
    var recordID: String
    var kindRaw: String
    var payloadData: Data
    var session: ChatSession?

    init(session: ChatSession, recordID: String, kindRaw: String, payloadData: Data) {
        id = session.id.uuidString + ":" + kindRaw + ":" + recordID
        sessionID = session.id; self.session = nil; self.recordID = recordID
        self.kindRaw = kindRaw; self.payloadData = payloadData
    }
}
