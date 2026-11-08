import AgentHarness
import Foundation
import Testing
import KurnCore
@testable import Kurn

private struct DocumentReply {
    let id: UUID
    let title: String
    let version: Int
    let markdown: String?
    let total: Int?
    let nextOffset: Int?
}

@Suite struct ChatDocumentToolsTests {
    private func run(_ name: String, _ arguments: JSONValue, workspace: ChatDocumentWorkspace) async throws -> AgentToolOutput {
        let tool = try #require(ChatDocumentTools.make(workspace: workspace).first { $0.spec.name == name })
        return try await tool.execute(arguments)
    }

    /// Parses "<action> document <id> | title: <t> | version: <n>", then for reads the Markdown page
    /// and a final "page: characters a–b of total; next offset: n" line.
    private func reply(_ output: AgentToolOutput) throws -> DocumentReply {
        #expect(!output.isError)
        let content = output.content
        let headerEnd = content.firstIndex(of: "\n") ?? content.endIndex
        let fields = content[..<headerEnd].components(separatedBy: " | ")
        try #require(fields.count == 3)
        let id = try #require(UUID(uuidString: fields[0].components(separatedBy: " ").last ?? ""))
        let title = String(fields[1].dropFirst("title: ".count))
        let version = try #require(Int(fields[2].dropFirst("version: ".count)))
        guard headerEnd < content.endIndex else {
            return DocumentReply(id: id, title: title, version: version, markdown: nil, total: nil, nextOffset: nil)
        }
        let body = content[content.index(after: headerEnd)...]
        let pageBreak = try #require(body.range(of: "\n", options: .backwards))
        let page = String(body[pageBreak.upperBound...])
        #expect(page.hasPrefix("page: "))
        let total = page.components(separatedBy: " of ").last?.components(separatedBy: ";").first.flatMap { Int($0) }
        let next = page.components(separatedBy: "next offset: ").dropFirst().first.flatMap { Int($0) }
        return DocumentReply(id: id, title: title, version: version, markdown: String(body[..<pageBreak.lowerBound]),
                             total: total, nextOffset: next)
    }

    @Test func createReplaceAppendReadAndReopen() async throws {
        let workspace = ChatDocumentWorkspace()
        #expect(await workspace.snapshot().isEmpty)
        let created = try await run("create_document", .object(["title": .string("Ata"), "markdown": .string("# Minutes")]),
                                    workspace: workspace)
        let first = try reply(created)
        #expect(first.title == "Ata")
        #expect(first.version == 1)
        #expect(first.markdown == nil)
        #expect(!created.content.contains("# Minutes"))
        #expect(created.summary == "Created “Ata” (v1)")
        let id = JSONValue.string(first.id.uuidString)
        let updated = try reply(await run("update_document", .object(["document_id": id, "title": .string("Report"),
            "markdown": .string("Replacement")]), workspace: workspace))
        #expect(updated.version == 2)
        #expect(updated.title == "Report")
        let appended = try reply(await run("append_to_document", .object(["document_id": id, "markdown": .string("## Decision")]),
                                          workspace: workspace))
        #expect(appended.version == 3)
        let read = try reply(await run("read_document", .object(["document_id": id]), workspace: workspace))
        #expect(read.markdown == "Replacement\n\n## Decision")
        #expect(read.version == 3)
        #expect(read.nextOffset == nil)
        let snapshot = await workspace.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode([ChatDocumentArtifact].self, from: data)
        #expect(decoded == snapshot)
        let reopened = try ChatDocumentWorkspace(artifacts: decoded)
        let revised = try reply(await run("update_document", .object(["document_id": id, "markdown": .string("Revised")]),
                                         workspace: reopened))
        #expect(revised.title == "Report")
        #expect(revised.version == 4)
        #expect(await workspace.snapshot() == snapshot)
        #expect(await reopened.snapshot().first?.markdown == "Revised")
    }

    @Test func readsUseBoundedUnicodeScalarPagination() async throws {
        let markdown = String(repeating: "e\u{301}🙂", count: 4000)
        let artifact = ChatDocumentArtifact(title: "Unicode", markdown: markdown)
        let workspace = try ChatDocumentWorkspace(artifacts: [artifact])
        let id = JSONValue.string(artifact.id.uuidString)
        let first = try reply(await run("read_document", .object(["document_id": id]), workspace: workspace))
        #expect(first.markdown?.unicodeScalars.count == 8000)
        #expect(first.total == 12000)
        #expect(first.nextOffset == 8000)
        let second = try reply(await run("read_document", .object(["document_id": id, "offset": .number(8000)]), workspace: workspace))
        #expect((first.markdown ?? "") + (second.markdown ?? "") == markdown)
        #expect(second.nextOffset == nil)
        let small = try reply(await run("read_document", .object(["document_id": id, "limit": .number(2)]), workspace: workspace))
        #expect(small.markdown == "e\u{301}")
        #expect(small.nextOffset == 2)
        let empty = try reply(await run("read_document", .object(["document_id": id, "offset": .number(12001)]), workspace: workspace))
        #expect(empty.markdown == "")
        #expect(empty.nextOffset == nil)
        #expect(await workspace.snapshot() == [artifact])
    }

    @Test(arguments: ["create_document", "update_document", "append_to_document", "read_document"])
    func schemasAndMalformedArguments(name: String) async throws {
        let workspace = ChatDocumentWorkspace()
        let tool = try #require(ChatDocumentTools.make(workspace: workspace).first { $0.spec.name == name })
        #expect(!tool.requiresConfirmation)
        #expect(tool.spec.description.contains("do not paste the document"))
        #expect(tool.spec.description.contains("document, report or minutes"))
        guard case .object(let schema) = tool.spec.inputSchema else { Issue.record("Missing schema"); return }
        #expect(schema["additionalProperties"] == .bool(false))
        for args in [JSONValue.null, .array([]), .object([:]), .object(["unknown": .string("x")])] {
            #expect(try await run(name, args, workspace: workspace).isError)
        }
        #expect(await workspace.snapshot().isEmpty)
    }

    @Test(arguments: ["update_document", "append_to_document", "read_document"])
    func unknownAndInvalidIDs(name: String) async throws {
        let workspace = ChatDocumentWorkspace()
        for id in [JSONValue.string(UUID().uuidString), .string("bad"), .number(1), .null] {
            var args: [String: JSONValue] = ["document_id": id]
            if name != "read_document" { args["markdown"] = .string("Body") }
            #expect(try await run(name, .object(args), workspace: workspace).isError)
        }
        #expect(await workspace.snapshot().isEmpty)
    }

    @Test(arguments: [JSONValue.string(""), .string(" \n\t"), .number(1), .null])
    func emptyAndWrongTypedTextIsRejected(value: JSONValue) async throws {
        let artifact = ChatDocumentArtifact(title: "Title", markdown: "Body")
        let workspace = try ChatDocumentWorkspace(artifacts: [artifact])
        for key in ["title", "markdown"] {
            var args: [String: JSONValue] = ["title": .string("Title"), "markdown": .string("Body")]
            args[key] = value
            #expect(try await run("create_document", .object(args), workspace: workspace).isError)
            args["document_id"] = .string(artifact.id.uuidString)
            #expect(try await run("update_document", .object(args), workspace: workspace).isError)
        }
        #expect(try await run("append_to_document", .object(["document_id": .string(artifact.id.uuidString), "markdown": value]),
                              workspace: workspace).isError)
        #expect(await workspace.snapshot() == [artifact])
    }

    @Test func totalSizeCapIsAtomicAcrossAppendAndUpdate() async throws {
        let workspace = ChatDocumentWorkspace()
        let maximum = String(repeating: "🙂", count: ChatDocumentWorkspace.maximumScalars)
        let created = try reply(await run("create_document", .object(["title": .string(String(repeating: "t", count: 500)),
            "markdown": .string(maximum)]), workspace: workspace))
        let snapshot = await workspace.snapshot()
        let id = JSONValue.string(created.id.uuidString)
        #expect(try await run("append_to_document", .object(["document_id": id, "markdown": .string("x")]),
                              workspace: workspace).isError)
        for name in ["create_document", "update_document"] {
            var args: [String: JSONValue] = ["title": .string("Title"), "markdown": .string(maximum + "x")]
            if name == "update_document" { args["document_id"] = id }
            #expect(try await run(name, .object(args), workspace: workspace).isError)
            args["title"] = .string(String(repeating: "t", count: 501))
            args["markdown"] = .string("Body")
            #expect(try await run(name, .object(args), workspace: workspace).isError)
        }
        #expect(await workspace.snapshot() == snapshot)
    }

    @Test(arguments: [JSONValue.number(-1), .number(0.5), .number(200001), .number(.infinity), .number(.nan), .string("1"), .null])
    func invalidReadPagination(value: JSONValue) async throws {
        let artifact = ChatDocumentArtifact(title: "Title", markdown: "Body")
        let workspace = try ChatDocumentWorkspace(artifacts: [artifact])
        for key in ["offset", "limit"] {
            #expect(try await run("read_document", .object(["document_id": .string(artifact.id.uuidString), key: value]),
                                  workspace: workspace).isError)
        }
        #expect(try await run("read_document", .object(["document_id": .string(artifact.id.uuidString), "limit": .number(0)]),
                              workspace: workspace).isError)
    }

    @Test func restorationRejectsInvalidStateAndVersionOverflowIsRecoverable() async throws {
        let artifact = ChatDocumentArtifact(title: "Title", markdown: "Body")
        #expect(throws: (any Error).self) { try ChatDocumentWorkspace(artifacts: [artifact, artifact]) }
        #expect(throws: (any Error).self) { try ChatDocumentWorkspace(artifacts: [.init(title: "", markdown: "Body")]) }
        #expect(throws: (any Error).self) { try ChatDocumentWorkspace(artifacts: [.init(title: "Title", markdown: "Body", version: 0)]) }
        let maximumVersion = ChatDocumentArtifact(title: "Title", markdown: "Body", version: Int.max)
        let workspace = try ChatDocumentWorkspace(artifacts: [maximumVersion])
        #expect(try await run("update_document", .object(["document_id": .string(maximumVersion.id.uuidString),
            "markdown": .string("New")]), workspace: workspace).isError)
        #expect(await workspace.snapshot() == [maximumVersion])
    }

    @Test func concurrentAppendsAreSerialized() async throws {
        let artifact = ChatDocumentArtifact(title: "Title", markdown: "Body")
        let workspace = try ChatDocumentWorkspace(artifacts: [artifact])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let output = try await run("append_to_document", .object(["document_id": .string(artifact.id.uuidString),
                        "markdown": .string("Section")]), workspace: workspace)
                    #expect(!output.isError)
                }
            }
            try await group.waitForAll()
        }
        #expect(await workspace.snapshot().first?.version == 11)
        #expect(await workspace.snapshot().first?.markdown == "Body" + String(repeating: "\n\nSection", count: 10))
    }

    @Test func cancellationDoesNotCreateAnArtifact() async throws {
        let workspace = ChatDocumentWorkspace()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await run("create_document", .object(["title": .string("Title"), "markdown": .string("Body")]),
                                 workspace: workspace)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await workspace.snapshot().isEmpty)
    }

    @Test func harnessProducesExplicitArtifactsAndRecoversFromErrors() async throws {
        let artifact = ChatDocumentArtifact(title: "Existing", markdown: "Old", version: 4)
        let workspace = try ChatDocumentWorkspace(artifacts: [artifact])
        let id = artifact.id.uuidString
        let calls = [agentCall("0", name: "read_document", raw: "{\"document_id\":\"\(UUID())\"}"),
                     agentCall("1", name: "create_document", raw: "{\"title\":\"Ata\",\"markdown\":\"# Minutes\"}"),
                     agentCall("2", name: "update_document", raw: "{\"document_id\":\"\(id)\",\"markdown\":\"New\"}"),
                     agentCall("3", name: "append_to_document", raw: "{\"document_id\":\"\(id)\",\"markdown\":\"Section\"}"),
                     agentCall("4", name: "read_document", raw: "{\"document_id\":\"\(id)\"}")]
        let model = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: calls), AgentTurnResponse(text: "Documents are ready.")])
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model), tools: ChatDocumentTools.make(workspace: workspace)))
        #expect(outcome.stopReason == .completed)
        #expect(outcome.finalText == "Documents are ready.")
        let snapshot = await workspace.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.first { $0.id == artifact.id }?.version == 6)
        #expect(snapshot.first { $0.id == artifact.id }?.markdown == "New\n\nSection")
        #expect(snapshot.first { $0.title == "Ata" }?.markdown == "# Minutes")
        #expect(outcome.messages.contains { if case .toolResult(_, _, _, true) = $0 { return true }; return false })
    }
}
