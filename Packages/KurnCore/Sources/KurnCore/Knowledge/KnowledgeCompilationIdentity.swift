import Foundation

public enum KnowledgeCompilationIdentityError: String, Error, Sendable {
    case invalidIdentity = "invalid_compilation_identity"
}

/// The extraction schema version is independent of the SwiftData schema.
/// The key is reversible so the writer can isolate historical jobs by scope
/// without adding a persisted field or parsing ambiguous separators.
public struct KnowledgeCompilationIdentity: Hashable, Sendable {
    public let scope: String
    public let meetingID: UUID
    public let transcriptFingerprint: String
    public let extractorVersion: String
    public let schemaVersion: Int
    private static let prefix = "knowledge.compile.v1:"

    public init(scope: String, meetingID: UUID, transcriptFingerprint: String, extractorVersion: String, schemaVersion: Int = 1) throws {
        guard !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !extractorVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              transcriptFingerprint.utf8.count == 64,
              transcriptFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              schemaVersion > 0 else { throw KnowledgeCompilationIdentityError.invalidIdentity }
        self.scope = scope
        self.meetingID = meetingID
        self.transcriptFingerprint = transcriptFingerprint
        self.extractorVersion = extractorVersion
        self.schemaVersion = schemaVersion
    }

    public func idempotencyKey() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let fields = [scope, meetingID.uuidString.lowercased(), transcriptFingerprint, extractorVersion, String(schemaVersion)]
        return Self.prefix + (try encoder.encode(fields)).base64EncodedString()
    }

    public init?(idempotencyKey: String) {
        guard idempotencyKey.hasPrefix(Self.prefix),
              let data = Data(base64Encoded: String(idempotencyKey.dropFirst(Self.prefix.count))),
              let fields = try? JSONDecoder().decode([String].self, from: data), fields.count == 5,
              let meetingID = UUID(uuidString: fields[1]), let version = Int(fields[4]),
              let identity = try? Self(scope: fields[0], meetingID: meetingID, transcriptFingerprint: fields[2],
                  extractorVersion: fields[3], schemaVersion: version) else { return nil }
        self = identity
    }
}
