import AgentHarness
import Foundation

public enum ChatDocumentTools {
    public static func make(workspace: ChatDocumentWorkspace) -> [AgentTool] {
        ["create_document", "update_document", "append_to_document", "read_document"].map { name in
            AgentTool(spec: spec(name)) { arguments in
                do {
                    try Task.checkCancellation()
                    let params = try Parameters(arguments, name: name)
                    return try await execute(name, params: params, workspace: workspace)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return AgentToolOutput(content: "Document tool error: \((error as? ChatDocumentError)?.errorDescription ?? "Invalid document.")",
                                           summary: "Document unavailable or invalid arguments", isError: true)
                }
            }
        }
    }

    private static func spec(_ name: String) -> AgentToolSpec {
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        if name != "create_document" {
            properties["document_id"] = .object(["type": .string("string"), "format": .string("uuid")])
            required.append(.string("document_id"))
        }
        if name == "create_document" || name == "update_document" {
            properties["title"] = .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(500)])
            if name == "create_document" { required.append(.string("title")) }
        }
        if name == "read_document" {
            properties["offset"] = .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(200000)])
            properties["limit"] = .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(8000)])
        } else {
            properties["markdown"] = .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(200000)])
            required.append(.string("markdown"))
        }
        return AgentToolSpec(name: name, description: """
            Use document tools whenever the user asks for a document, report or minutes; do not paste the document
            in the chat reply. create_document creates an explicit artifact; update_document fully replaces its body
            and optionally title; append_to_document adds sections separated by two newlines. Each mutation increments
            version. Documents are limited to 200000 Unicode scalars. read_document uses Unicode-scalar offset/limit
            pagination (default limit 8000); its last "page:" line gives the next offset. Mutation output returns
            ID/version, not the body.
            """, inputSchema: .object(["type": .string("object"), "properties": .object(properties),
                                       "required": .array(required), "additionalProperties": .bool(false)]))
    }

    private struct Parameters {
        let values: [String: JSONValue]

        init(_ arguments: JSONValue, name: String) throws {
            guard case .object(let values) = arguments else { throw ChatDocumentError("Expected an object.") }
            let permitted: Set<String>
            switch name {
            case "create_document": permitted = ["title", "markdown"]
            case "update_document": permitted = ["document_id", "markdown", "title"]
            case "append_to_document": permitted = ["document_id", "markdown"]
            default: permitted = ["document_id", "offset", "limit"]
            }
            guard Set(values.keys).isSubset(of: permitted) else { throw ChatDocumentError("Unknown argument.") }
            self.values = values
        }

        func string(_ key: String) throws -> String {
            guard case .string(let value) = values[key] else { throw ChatDocumentError("Invalid \(key).") }
            return value
        }

        func id() throws -> UUID {
            guard let id = UUID(uuidString: try string("document_id")) else { throw ChatDocumentError("Invalid document_id.") }
            return id
        }

        func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = values[key] else { return fallback }
            guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                  number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
                throw ChatDocumentError("Invalid \(key).")
            }
            return Int(number)
        }
    }

    private static func execute(_ name: String, params: Parameters, workspace: ChatDocumentWorkspace) async throws -> AgentToolOutput {
        let artifact: ChatDocumentArtifact
        let action: String
        switch name {
        case "create_document":
            artifact = try await workspace.create(title: params.string("title"), markdown: params.string("markdown"))
            action = "Created"
        case "update_document":
            let title = try params.values["title"] == nil ? nil : params.string("title")
            artifact = try await workspace.update(params.id(), markdown: params.string("markdown"), title: title)
            action = "Updated"
        case "append_to_document":
            artifact = try await workspace.append(params.id(), markdown: params.string("markdown"))
            action = "Appended to"
        default:
            artifact = try await workspace.read(params.id())
            action = "Read"
        }
        let header = "\(action) document \(artifact.id.uuidString) | title: \(ChatSourceToolText.field(artifact.title))"
            + " | version: \(artifact.version)"
        var content = header
        if name == "read_document" {
            let offset = try params.integer("offset", fallback: 0, range: 0...ChatDocumentWorkspace.maximumScalars)
            let limit = try params.integer("limit", fallback: 8000, range: 1...8000)
            let scalars = artifact.markdown.unicodeScalars
            let chunk = String(String.UnicodeScalarView(scalars.dropFirst(offset).prefix(limit)))
            let page = ChatSourceToolText.pageLine(offset: offset, count: chunk.unicodeScalars.count,
                                                   total: scalars.count, unit: "characters")
            content += "\n" + chunk + "\n" + page
        }
        return AgentToolOutput(content: content,
                               summary: "\(action) “\(artifact.title)” (v\(artifact.version))")
    }
}
