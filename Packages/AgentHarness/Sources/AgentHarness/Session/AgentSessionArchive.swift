import Foundation

/// A session's native, versioned archive (NH10): its whole append log — every branch, the selected
/// leaf, runs, usage, checkpoints, labels and edits — plus the host's own records, as JSON Lines.
///
/// The first line is the header; each entry is one line; every other line is a host record kept as
/// it was read, so a record type this version does not know survives an import and an export. Only
/// LF separates records: U+2028 and U+2029 are ordinary characters inside a JSON string, and a line
/// may arrive in any number of chunks (`AgentJSONLLines`). An archive never carries credentials or a
/// live operation; it is data, and nothing in it runs when it is read.
public struct AgentSessionArchive: Sendable, Equatable {
    public static let format = "kurn.agent-session"
    public static let version = 1

    /// A host record: its namespaced type (`kurn.artifact-revision`, …) and data, opaque here.
    public struct Record: Sendable, Equatable {
        public let type: String
        public let data: JSONValue
        public init(type: String, data: JSONValue) { self.type = type; self.data = data }
    }

    /// Bounds a reader enforces before it trusts a line.
    public struct Limits: Sendable {
        public var maximumLineBytes = 17 * 1_024 * 1_024
        public var maximumTotalBytes = 512 * 1_024 * 1_024
        public var maximumEntries = 200_000
        public var maximumDepth = 64
        public init() {}
    }

    public let sessionID: String
    public let leafID: String?
    public let entries: [AgentSessionEntry]
    public let records: [Record]
    /// Header fields this version does not interpret, kept for the next export.
    public let metadata: [String: JSONValue]

    /// Validates the log as one session's graph: IDs, ordinals, parents before children and a leaf
    /// that exists.
    public init(sessionID: String, leafID: String?, entries: [AgentSessionEntry], records: [Record] = [],
                metadata: [String: JSONValue] = [:]) throws {
        guard AgentContentMessage.validID(sessionID), entries.isEmpty == (leafID == nil) else { throw AgentSessionArchiveError.invalidGraph }
        do { _ = try AgentEntryGraph(sessionID: sessionID, entries: entries, leafID: leafID) } catch {
            throw AgentSessionArchiveError.invalidGraph
        }
        guard records.allSatisfy({ Self.isRecordType($0.type) }) else { throw AgentSessionArchiveError.invalidRecord }
        self.sessionID = sessionID
        self.leafID = leafID
        self.entries = entries.sorted { $0.ordinal < $1.ordinal }
        self.records = records
        self.metadata = metadata.filter { !Self.headerKeys.contains($0.key) }
    }

    /// The archive as JSON Lines, every line ending in LF.
    public func jsonl() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var header = metadata
        header["type"] = .string("session")
        header["format"] = .string(Self.format)
        header["version"] = .number(Double(Self.version))
        header["sessionID"] = .string(sessionID)
        header["leafID"] = leafID.map(JSONValue.string) ?? .null
        var lines = [try encoder.encode(JSONValue.object(header))]
        // Entries are encoded directly, never through `JSONValue`, so their integers (millisecond
        // timestamps, ordinals) keep their exact form.
        for entry in entries { lines.append(try encoder.encode(EntryLine(type: "entry", entry: entry))) }
        for record in records {
            lines.append(try encoder.encode(JSONValue.object(["type": .string(record.type), "data": record.data])))
        }
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        return data
    }

    /// Reads an archive, rejecting anything it cannot trust rather than repairing it: a missing or
    /// repeated header, another format or version, a line that is not an object with a type, a
    /// payload past the limits, an entry of another session or a broken graph.
    public static func decode(_ data: Data, limits: Limits = Limits()) throws -> AgentSessionArchive {
        guard data.count <= limits.maximumTotalBytes else { throw AgentSessionArchiveError.tooLarge }
        var reader = AgentJSONLLines(maximumLineBytes: limits.maximumLineBytes)
        var lines = try reader.append(data)
        if let last = try reader.finish() { lines.append(last) }
        var header: [String: JSONValue]?
        var entries: [AgentSessionEntry] = []
        var records: [Record] = []
        for (index, line) in lines.enumerated() {
            guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { continue }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
                  case .object(let fields) = value, case .string(let type)? = fields["type"] else {
                throw AgentSessionArchiveError.invalidLine(index + 1)
            }
            guard value.depth <= limits.maximumDepth else { throw AgentSessionArchiveError.tooDeep }
            switch type {
            case "session":
                guard header == nil, index == lines.firstIndex(where: { !$0.isEmpty }) else { throw AgentSessionArchiveError.invalidLine(index + 1) }
                header = fields
            case "entry":
                guard header != nil, let decoded = try? JSONDecoder().decode(EntryLine.self, from: line) else {
                    throw AgentSessionArchiveError.invalidLine(index + 1)
                }
                entries.append(decoded.entry)
                guard entries.count <= limits.maximumEntries else { throw AgentSessionArchiveError.tooLarge }
            default:
                guard header != nil, isRecordType(type) else { throw AgentSessionArchiveError.invalidLine(index + 1) }
                records.append(Record(type: type, data: fields["data"] ?? .null))
            }
        }
        guard let header, header["format"] == .string(format) else { throw AgentSessionArchiveError.notAnArchive }
        guard case .number(let version)? = header["version"] else { throw AgentSessionArchiveError.notAnArchive }
        guard version == Double(Self.version) else { throw AgentSessionArchiveError.unsupportedVersion }
        guard case .string(let sessionID)? = header["sessionID"] else { throw AgentSessionArchiveError.notAnArchive }
        let leafID: String?
        switch header["leafID"] {
        case .string(let id)?: leafID = id
        case .null?, nil: leafID = nil
        default: throw AgentSessionArchiveError.invalidGraph
        }
        return try AgentSessionArchive(sessionID: sessionID, leafID: leafID, entries: entries, records: records, metadata: header)
    }

    /// The same log under another session's identity, for an import that must not take over an
    /// existing session: every entry moves to `newSessionID`; IDs, parents, the leaf and the
    /// payloads are kept, so the graph is the same graph. Host records are the host's to rebase.
    public func copy(into newSessionID: String) throws -> AgentSessionArchive {
        let moved = try entries.map {
            try AgentSessionEntry(sessionID: newSessionID, id: $0.id, parentID: $0.parentID, ordinal: $0.ordinal,
                                  createdAt: $0.createdAt, payload: $0.payload, metadata: $0.metadata)
        }
        return try AgentSessionArchive(sessionID: newSessionID, leafID: leafID, entries: moved, records: records, metadata: metadata)
    }

    private struct EntryLine: Codable {
        let type: String
        let entry: AgentSessionEntry
    }

    private static let headerKeys: Set<String> = ["type", "format", "version", "sessionID", "leafID"]

    /// A host record's type is namespaced (`vendor.kind`), so it can never be read as an entry or a
    /// header.
    static func isRecordType(_ type: String) -> Bool {
        type.contains(".") && AgentContentMessage.validID(type) && !["session", "entry"].contains(type)
    }
}

public enum AgentSessionArchiveError: Error, Sendable, Equatable {
    case notAnArchive, unsupportedVersion, invalidLine(Int), invalidGraph, invalidRecord, tooLarge, tooDeep
}

/// Splits JSON Lines arriving in chunks (NH10). Only LF ends a record: U+2028 and U+2029 are
/// ordinary characters, and a chunk may end in the middle of a line or of a UTF-8 sequence.
public struct AgentJSONLLines: Sendable {
    public let maximumLineBytes: Int
    private var pending = Data()

    public init(maximumLineBytes: Int = 17 * 1_024 * 1_024) { self.maximumLineBytes = maximumLineBytes }

    /// The lines `chunk` completes, without their LF.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        var start = pending.startIndex
        while let end = pending[start...].firstIndex(of: 0x0A) {
            lines.append(Data(pending[start..<end]))
            start = pending.index(after: end)
        }
        pending = Data(pending[start...])
        guard pending.count <= maximumLineBytes, lines.allSatisfy({ $0.count <= maximumLineBytes }) else {
            throw AgentSessionArchiveError.tooLarge
        }
        return lines
    }

    /// What is left after the last LF, if anything: a final line without its LF.
    public mutating func finish() throws -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

extension JSONValue {
    /// How deeply arrays and objects nest; a scalar is 1.
    public var depth: Int {
        switch self {
        case .array(let values): 1 + (values.map(\.depth).max() ?? 0)
        case .object(let fields): 1 + (fields.values.map(\.depth).max() ?? 0)
        default: 1
        }
    }
}
