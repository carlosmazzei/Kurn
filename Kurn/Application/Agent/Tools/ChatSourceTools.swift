import AgentHarness
import Foundation
import KurnCore

/// Read-only tools with a fixed authorization snapshot and bounded JSON responses.
public enum ChatSourceTools {
    public static func make(reader: any ChatSourceReader, allowedMeetingIDs: Set<UUID>,
                            includeWikis: Bool) -> [AgentTool] {
        make(reader: reader, allowedMeetingIDs: allowedMeetingIDs,
             scope: ChatSourceScope(kind: .library, includeWikis: includeWikis))
    }

    public static func make(reader: any ChatSourceReader, allowedMeetingIDs: Set<UUID>,
                            scope: ChatSourceScope) -> [AgentTool] {
        let parts = Dictionary(uniqueKeysWithValues: allowedMeetingIDs.map { ($0, scope.parts(for: $0)) })
        let names = ["list_sources", "search", "read_transcript", "read_summary", "read_attachment", "read_wiki"]
            .filter { name in
                guard let part = part(for: name) else { return true }
                return parts.values.contains { $0.contains(part) }
            }
        return names.map { name in
            AgentTool(spec: spec(name)) { arguments in
                do {
                    let params = try Parameters(arguments, name: name)
                    return try await execute(name, params: params, reader: reader, parts: parts)
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

    private static func part(for name: String) -> ChatSourcePart? {
        switch name {
        case "search", "read_transcript": .transcript
        case "read_summary": .summary
        case "read_wiki": .wiki
        case "read_attachment": .attachments
        default: nil
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
        if name == "read_transcript" {
            properties["textOffset"] = .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(1000000)])
        }
        return AgentToolSpec(name: name,
                             description: """
                             Read authorized sources; results are plain text. offset/limit page items. Text reads
                             use a Unicode-scalar offset and return up to 8000 scalars within 18000 UTF-8 bytes
                             including framing. Follow the actual returned offset, not offset+limit. Search pages a top-100 result
                             window. Omit attachmentID to list attachments. Each result ends with a "page:" line; pass
                             its "next offset" to continue. Passages are "[m:ss] Speaker: text" ([h:mm:ss] past an
                             hour). A transcript page may end inside a passage: pass BOTH next offset and textOffset
                             from its page line to recover the unread suffix. textOffset counts Unicode scalars.
                             Passages appear under "meeting <id>:"; clipped metadata fields end with [truncated].
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
                : name == "read_transcript" ? ["meetingID", "offset", "limit", "textOffset"]
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
                                parts: [UUID: Set<ChatSourcePart>]) async throws -> AgentToolOutput {
        let sources = try await reader.listSources().filter { parts[$0.id] != nil }.sorted { $0.id.uuidString < $1.id.uuidString }
        if name == "list_sources" {
            let lines = sources.map { source in
                ChatSourceToolText.renderedSource(source, readable: readable(source, parts: parts[source.id] ?? []))
            }
            let header = "sources (id | title | date | duration | folder | tags | readable parts):"
            return lineOutput(header: header, items: page(lines, params: params, cap: 10), total: lines.count,
                              offset: params.offset) { $0 }
        }
        let existing = Set(sources.map(\.id))
        if name == "search" {
            let query = try params.string("query")
            let searchable = existing.filter { parts[$0]?.contains(.transcript) == true }
            let hits = searchable.isEmpty ? [] : try await reader.search(query: query, meetingIDs: searchable, limit: 100)
            let ranked = Array(hits.filter { searchable.contains($0.meetingID) }.prefix(100))
            let result = lineOutput(header: "search results (best first):", items: page(ranked, params: params, cap: 10),
                              total: ranked.count, offset: params.offset, render: ChatSourceToolText.renderedPassages)
            let metrics = result.metrics.merging([.searchResultLimit: 100, .searchWindowFull: ranked.count >= 100 ? 1 : 0]) { _, new in new }
            return AgentToolOutput(content: result.content, summary: result.summary, metrics: metrics)
        }
        let id = try params.uuid("meetingID")
        guard existing.contains(id) else { throw Invalid("Unknown or out-of-scope meetingID.") }
        guard let requiredPart = part(for: name), parts[id]?.contains(requiredPart) == true else {
            throw Invalid("This source part is not allowed for this meeting.")
        }
        switch name {
        case "read_transcript":
            let result = try await reader.readTranscript(meetingID: id, offset: params.offset, limit: min(params.limit, 10))
            let passages = Array(result.passages.prefix(min(params.limit, 10)).filter { $0.meetingID == id })
            let textOffset = try Parameters.integer(params.values["textOffset"], fallback: 0, range: 0...1_000_000)
            return try ChatTranscriptToolPage.output(ChatTranscriptPage(passages: passages, total: result.total),
                                                      offset: params.offset, textOffset: textOffset)
        case "read_summary":
            return try textPage(await reader.readSummary(meetingID: id), params: params)
        case "read_wiki":
            return try textPage(await reader.readWiki(meetingID: id), params: params)
        default:
            let attachments = try await reader.listAttachments(meetingID: id)
            guard params.values["attachmentID"] != nil else {
                let lines = attachments.map {
                    var rendered = ChatSourceToolText.renderedField($0.name)
                    rendered.text = "- \($0.id.uuidString) | " + rendered.text
                    return rendered
                }
                return lineOutput(header: "attachments (id | name):", items: page(lines, params: params, cap: 50),
                                  total: lines.count, offset: params.offset) { $0 }
            }
            let attachmentID = try params.uuid("attachmentID")
            guard attachments.contains(where: { $0.id == attachmentID }) else { throw Invalid("Unknown attachmentID.") }
            return try textPage(await reader.readAttachment(meetingID: id, attachmentID: attachmentID), params: params)
        }
    }

    /// Parts the model can actually read for a source: allowed by scope and present.
    private static func readable(_ source: ChatSource, parts: Set<ChatSourcePart>) -> [ChatSourcePart] {
        ChatSourcePart.allCases.filter { part in
            guard parts.contains(part) else { return false }
            switch part {
            case .transcript: return true
            case .summary: return source.hasSummary
            case .wiki: return source.hasWiki
            case .attachments: return source.hasAttachments
            }
        }
    }

    private static func page<Item>(_ items: [Item], params: Parameters, cap: Int) -> [Item] {
        Array(items.dropFirst(params.offset).prefix(min(params.limit, cap)))
    }

    static let maxOutputBytes = 18_000

    /// Renders as many items as fit `maxOutputBytes` (at least one), then the `page:` line.
    private static func lineOutput<Item>(header: String, items: [Item], total: Int, offset: Int,
                                         unit: String = "items", render: ([Item]) -> [ChatSourceToolText.Rendered]) -> AgentToolOutput {
        var count = items.count
        var body = render(items)
        func bytes() -> Int {
            let footer = ChatSourceToolText.pageLine(offset: offset, count: count, total: total, unit: unit)
            return ([header] + body.map(\.text) + [footer]).joined(separator: "\n").utf8.count
        }
        while count > 1, bytes() > maxOutputBytes {
            count -= 1
            body = render(Array(items.prefix(count)))
        }
        let pageLine = ChatSourceToolText.pageLine(offset: offset, count: count, total: total, unit: unit)
        let content = ([header] + body.map(\.text) + [pageLine]).joined(separator: "\n")
        let metrics: [AgentDiagnostic.Metric: Int] = [
            .omittedScalars: body.reduce(0) { $0 + $1.omittedScalars },
            .omittedItems: body.reduce(0) { $0 + $1.omittedItems },
            .returnedItems: count, .deferredItems: max(0, total - offset - count), .hasMore: offset + count < total ? 1 : 0
        ]
        return AgentToolOutput(content: content, summary: "Read \(count) items", metrics: metrics)
    }

    private static func textPage(_ text: String?, params: Parameters) throws -> AgentToolOutput {
        guard let text else { throw Invalid("No text available.") }
        let page = try AgentTextPage(text, offset: params.offset, maxBytes: maxOutputBytes - 200)
        let pageLine = ChatSourceToolText.pageLine(offset: params.offset, count: page.returnedScalars, total: page.totalScalars,
                                                   unit: "characters")
        return AgentToolOutput(content: page.text + "\n" + pageLine, summary: "Read \(page.returnedScalars) characters",
                               metrics: page.metrics)
    }
}
