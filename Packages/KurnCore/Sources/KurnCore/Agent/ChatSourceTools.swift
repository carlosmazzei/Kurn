import Foundation

/// Read-only tools with a fixed authorization snapshot and bounded JSON responses.
public enum ChatSourceTools {
    public static func make(reader: any ChatSourceReader, allowedMeetingIDs: Set<UUID>,
                            includeWikis: Bool) -> [AgentTool] {
        let names = ["list_sources", "search", "read_transcript", "read_summary", "read_attachment"]
            + (includeWikis ? ["read_wiki"] : [])
        return names.map { name in
            AgentTool(spec: spec(name)) { arguments in
                do {
                    let params = try Parameters(arguments, name: name)
                    return try await execute(name, params: params, reader: reader, allowed: allowedMeetingIDs,
                                             includeWikis: includeWikis)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    let message = (error as? Invalid)?.errorDescription ?? "Source reader failed."
                    return AgentToolOutput(content: "Source tool error: \(message)",
                                           summary: "Source unavailable or invalid arguments", isError: true)
                }
            }
        }
    }

    private static func spec(_ name: String) -> AgentToolSpec {
        var properties: [String: JSONValue] = [
            "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(50)])
        ]
        var required: [JSONValue] = []
        if name == "search" {
            properties["query"] = .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(1000)])
            required = [.string("query")]
        } else if name != "list_sources" {
            properties["meetingID"] = .object(["type": .string("string"), "format": .string("uuid")])
            required = [.string("meetingID")]
        }
        if name == "read_attachment" {
            properties["attachmentID"] = .object(["type": .string("string"), "format": .string("uuid")])
        }
        return AgentToolSpec(name: name,
                             description: """
                             Read authorized sources. offset/limit page items. Text reads use Unicode-scalar offset
                             and return up to 8000 scalars. Search pages a top-100 result window. Omit attachmentID
                             to list attachments. nextOffset continues a page; truncated text fields are marked.
                             """,
                             inputSchema: .object(["type": .string("object"), "properties": .object(properties),
                                                   "required": .array(required), "additionalProperties": .bool(false)]))
    }

    private struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct Parameters {
        let values: [String: JSONValue]
        let offset: Int
        let limit: Int

        init(_ arguments: JSONValue, name: String) throws {
            guard case .object(let values) = arguments else { throw Invalid("Expected an object.") }
            let permitted: Set<String> = name == "list_sources" ? ["offset", "limit"]
                : name == "search" ? ["query", "offset", "limit"]
                : name == "read_attachment" ? ["meetingID", "attachmentID", "offset", "limit"]
                : ["meetingID", "offset", "limit"]
            guard Set(values.keys).isSubset(of: permitted) else { throw Invalid("Unknown argument.") }
            self.values = values
            offset = try Self.integer(values["offset"], fallback: 0, range: 0...1_000_000)
            limit = try Self.integer(values["limit"], fallback: 20, range: 1...50)
        }

        func string(_ key: String) throws -> String {
            guard case .string(let value) = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 1000 else { throw Invalid("Invalid \(key).") }
            return value
        }

        func uuid(_ key: String) throws -> UUID {
            guard let id = UUID(uuidString: try string(key)) else { throw Invalid("Invalid \(key).") }
            return id
        }

        static func integer(_ value: JSONValue?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value else { return fallback }
            guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                  number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
                throw Invalid("Invalid offset or limit.")
            }
            return Int(number)
        }
    }

    private static func execute(_ name: String, params: Parameters, reader: any ChatSourceReader,
                                allowed: Set<UUID>, includeWikis: Bool) async throws -> AgentToolOutput {
        let sources = try await reader.listSources().filter { allowed.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
        if name == "list_sources" {
            let values = sources.map { source in
                JSONValue.object([
                    "id": .string(source.id.uuidString), "title": clipped(source.title),
                    "date": .string(ISO8601DateFormatter().string(from: source.date)), "duration": .number(source.duration),
                    "tags": .array(source.tags.prefix(10).map { clipped($0, limit: 100) }),
                    "tagsTruncated": .bool(source.tags.count > 10),
                    "folder": source.folder.map { clipped($0) } ?? .null,
                    "hasSummary": .bool(source.hasSummary), "hasWiki": .bool(includeWikis && source.hasWiki),
                    "hasAttachments": .bool(source.hasAttachments)
                ])
            }
            return try page(values, offset: params.offset, limit: min(params.limit, 10))
        }
        let existing = Set(sources.map(\.id))
        if name == "search" {
            let hits = try await reader.search(query: params.string("query"), meetingIDs: existing, limit: 100)
            return try page(hits.filter { existing.contains($0.meetingID) }.prefix(100).map(passage),
                            offset: params.offset, limit: min(params.limit, 10))
        }
        let id = try params.uuid("meetingID")
        guard existing.contains(id) else { throw Invalid("Unknown or out-of-scope meetingID.") }
        switch name {
        case "read_transcript":
            let result = try await reader.readTranscript(meetingID: id, offset: params.offset, limit: min(params.limit, 10))
            let values = result.passages.prefix(min(params.limit, 10)).filter { $0.meetingID == id }.map(passage)
            return try output(items: values, total: result.total, offset: params.offset)
        case "read_summary":
            return try textPage(await reader.readSummary(meetingID: id), params: params)
        case "read_wiki":
            return try textPage(await reader.readWiki(meetingID: id), params: params)
        default:
            let attachments = try await reader.listAttachments(meetingID: id)
            guard params.values["attachmentID"] != nil else {
                return try page(attachments.map { .object(["id": .string($0.id.uuidString), "name": clipped($0.name)]) },
                                offset: params.offset, limit: params.limit)
            }
            let attachmentID = try params.uuid("attachmentID")
            guard attachments.contains(where: { $0.id == attachmentID }) else { throw Invalid("Unknown attachmentID.") }
            return try textPage(await reader.readAttachment(meetingID: id, attachmentID: attachmentID), params: params)
        }
    }

    private static func clipped(_ text: String, limit: Int = 500) -> JSONValue {
        .string(String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
            + (text.unicodeScalars.count > limit ? " [truncated]" : ""))
    }

    private static func passage(_ value: ChatSourcePassage) -> JSONValue {
        .object(["meetingID": .string(value.meetingID.uuidString), "timestamp": .number(value.timestamp),
                 "speaker": clipped(value.speaker), "text": clipped(value.text)])
    }

    private static func page(_ values: [JSONValue], offset: Int, limit: Int) throws -> AgentToolOutput {
        try output(items: Array(values.dropFirst(offset).prefix(limit)), total: values.count, offset: offset)
    }

    private static func output(items: [JSONValue], total: Int, offset: Int) throws -> AgentToolOutput {
        if items.count > 1, try JSONValue.array(items).encodedString().utf8.count > 18000 {
            return try output(items: Array(items.dropLast()), total: total, offset: offset)
        }
        let next = offset + items.count
        let json = JSONValue.object(["items": .array(items), "total": .number(Double(total)),
                                     "nextOffset": next < total && !items.isEmpty ? .number(Double(next)) : .null])
        return AgentToolOutput(content: try json.encodedString(), summary: "Read \(items.count) items")
    }

    private static func textPage(_ text: String?, params: Parameters) throws -> AgentToolOutput {
        guard let text else { throw Invalid("No text available.") }
        let scalars = text.unicodeScalars
        let chunk = String(String.UnicodeScalarView(scalars.dropFirst(params.offset).prefix(8000)))
        let next = params.offset + chunk.unicodeScalars.count
        let json = JSONValue.object(["text": .string(chunk), "total": .number(Double(scalars.count)),
                                     "nextOffset": next < scalars.count ? .number(Double(next)) : .null])
        return AgentToolOutput(content: try json.encodedString(), summary: "Read \(chunk.unicodeScalars.count) characters")
    }
}
