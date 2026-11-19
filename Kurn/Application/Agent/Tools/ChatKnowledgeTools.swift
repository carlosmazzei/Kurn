import AgentHarness
import Foundation
import KurnCore

/// Where the chat reads canonical knowledge from (K5.1, CLAUDE.md "Knowledge Engine decisions",
/// ADR-007): the same authorized, evidence-checked read the Knowledge reader shows, never a second
/// store. Production reads through `KnowledgeCompilationCoordinator`.
struct ChatKnowledgeSource: Sendable {
    /// A fresh read of exactly these meetings, with one cited passage when asked for.
    let read: @Sendable (Set<UUID>, KnowledgeEvidenceSelection?) async throws -> KnowledgeBrowserRead
    /// The host's live authorization: feature flag, source controls, policies, classifications.
    let authorization: @MainActor @Sendable (Set<UUID>) -> KnowledgeSourceAuthorization
    /// Whether the person agreed to send knowledge to a remote provider to answer. No consent
    /// screen exists until the K5 cloud review, so production answers no and the tools are never
    /// offered to a cloud model; a policy alone never stands in for consent.
    let remoteConsent: @MainActor @Sendable () -> Bool

    @MainActor
    init(coordinator: KnowledgeCompilationCoordinator) {
        read = { meetings, selection in try await coordinator.readKnowledgeBrowser(meetingIDs: meetings, selection: selection) }
        authorization = { coordinator.browserReadAuthorization(meetingIDs: $0) }
        remoteConsent = { false }
    }

    init(read: @escaping @Sendable (Set<UUID>, KnowledgeEvidenceSelection?) async throws -> KnowledgeBrowserRead,
         authorization: @escaping @MainActor @Sendable (Set<UUID>) -> KnowledgeSourceAuthorization,
         remoteConsent: @escaping @MainActor @Sendable () -> Bool) {
        self.read = read
        self.authorization = authorization
        self.remoteConsent = remoteConsent
    }
}

/// Whether a chat run may read knowledge at all. Sending knowledge to the model that answers is
/// `answerSynthesis`: the same default-deny policy evaluation as every other knowledge operation
/// (ADR-008), checked before the tools are offered and again on every call after a fresh read.
enum ChatKnowledgeGate {
    /// The reader's own bound on one scoped read.
    static let meetingLimit = 16

    /// The meetings the run may read knowledge from, or nil when it may not read any: the feature
    /// is off, no meeting is allowed by the controls, more than `meetingLimit` are selected, or the
    /// policy and the person's consent do not authorize answering with this provider.
    @MainActor
    static func meetings(_ ids: Set<UUID>, source: ChatKnowledgeSource, provider: AIProvider,
                         classifications: [KnowledgeClassification] = []) -> Set<UUID>? {
        let auth = source.authorization(ids)
        let allowed = auth.meetingIDs.intersection(ids)
        guard auth.featureEnabled, !allowed.isEmpty, allowed.count <= meetingLimit,
              decision(auth, provider: provider, consent: source.remoteConsent(), classifications: classifications).isAllowed else {
            return nil
        }
        return allowed
    }

    static func decision(_ auth: KnowledgeSourceAuthorization, provider: AIProvider, consent: Bool,
                         classifications: [KnowledgeClassification]) -> KnowledgePolicyDecision {
        let destination: KnowledgeDestination = provider.kind == .appleOnDevice ? .onDevice : .remote(providerID: provider.id)
        let request = KnowledgeProcessingRequest(operation: .answerSynthesis, destination: destination,
            sourceClassifications: auth.sourceClassifications + classifications, userConsentedToRemote: consent)
        return KnowledgePolicyEvaluator.evaluate(request, under: auth.policies, featureEnabled: auth.featureEnabled)
    }
}

/// Read-only knowledge tools (K5.1): search, an entity's page, a timeline and one cited passage.
/// Each call re-authorizes, reads afresh and re-checks the policy against the read's own source
/// classifications before anything reaches the model. Results are compact text
/// (`ChatKnowledgeToolText`) ending with a `page:` line and a `revision:` line.
enum ChatKnowledgeTools {
    static let names = ["search_knowledge", "get_entity", "get_timeline", "get_evidence"]

    static func make(source: ChatKnowledgeSource, meetings: Set<UUID>, provider: AIProvider) -> [AgentTool] {
        names.map { name in
            AgentTool(spec: spec(name), scheduling: .parallelRead) { arguments in
                do {
                    let params = try Parameters(arguments, name: name)
                    let read = try await authorizedRead(source: source, meetings: meetings, provider: provider,
                                                        selection: params.selection)
                    return try execute(name, params: params, read: read)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    let message = (error as? Invalid)?.errorDescription ?? "Knowledge is unavailable for these sources."
                    return AgentToolOutput(content: "Knowledge tool error: \(message)",
                                           summary: "Knowledge unavailable or invalid arguments", isError: true)
                }
            }
        }
    }

    /// Authorization before the read and again with the read's own classifications after it, so a
    /// context reclassified since the run started is never sent.
    private static func authorizedRead(source: ChatKnowledgeSource, meetings: Set<UUID>, provider: AIProvider,
                                       selection: KnowledgeEvidenceSelection?) async throws -> KnowledgeBrowserRead {
        guard await ChatKnowledgeGate.meetings(meetings, source: source, provider: provider) == meetings else {
            throw Invalid("Knowledge is not authorized for these sources.")
        }
        let read = try await source.read(meetings, selection)
        try Task.checkCancellation()
        guard read.meetingIDs == meetings,
              await ChatKnowledgeGate.meetings(meetings, source: source, provider: provider,
                                               classifications: read.sourceClassifications) == meetings else {
            throw Invalid("Knowledge is not authorized for these sources.")
        }
        return read
    }

    private static func execute(_ name: String, params: Parameters, read: KnowledgeBrowserRead) throws -> AgentToolOutput {
        switch name {
        case "search_knowledge":
            let query = try params.string("query", limit: KnowledgeSearchIndex.queryLimit)
            let hits = try KnowledgeSearchIndex(pages: read.pages, meetingIDs: read.meetingIDs).search(query: query)
            return ChatKnowledgeToolText.output(header: "knowledge search results (best first):",
                                                lines: hits.map { ChatKnowledgeToolText.hit($0, query: query) },
                                                offset: params.offset, limit: params.limit, read: read)
        case "get_entity":
            let id = try params.uuid("entityID")
            guard let page = read.pages.first(where: { $0.entity.id == id }) else { throw Invalid("Unknown entityID.") }
            let entries = page.sections.flatMap(\.entries)
            return ChatKnowledgeToolText.output(header: ChatKnowledgeToolText.entityHeader(page),
                                                lines: entries.map { ChatKnowledgeToolText.claim($0) },
                                                offset: params.offset, limit: params.limit, read: read)
        case "get_timeline":
            let entity = try params.optionalUUID("entityID")
            if let entity, !read.pages.contains(where: { $0.entity.id == entity }) { throw Invalid("Unknown entityID.") }
            let timeline = KnowledgeTimeline.build(pages: read.pages)
            let entries = (timeline.periods.flatMap(\.entries) + timeline.undated).filter { entry in
                entity.map { entry.item.subject.id == $0 || entry.item.object?.id == $0 } ?? true
            }
            return ChatKnowledgeToolText.output(header: "timeline (by stated time; undated last):",
                                                lines: entries.map { ChatKnowledgeToolText.timeline($0) },
                                                offset: params.offset, limit: params.limit, read: read)
        default:
            guard let evidence = read.selectedEvidence else { throw Invalid("Unknown assertionID or evidenceID.") }
            return ChatKnowledgeToolText.output(header: "evidence:", lines: [ChatKnowledgeToolText.evidence(evidence)],
                                                offset: 0, limit: 1, read: read)
        }
    }

    private static func spec(_ name: String) -> AgentToolSpec {
        var properties: [String: JSONValue] = [
            "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
            "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20)])
        ]
        var required: [JSONValue] = []
        let uuid: JSONValue = .object(["type": .string("string"), "format": .string("uuid")])
        let description: String
        switch name {
        case "search_knowledge":
            properties["query"] = .object(["type": .string("string"), "minLength": .number(1),
                                           "maxLength": .number(Double(KnowledgeSearchIndex.queryLimit))])
            required = [.string("query")]
            description = "Search the canonical knowledge (entities, aliases, evidence-backed claims) of the selected meetings."
        case "get_entity":
            properties["entityID"] = uuid
            required = [.string("entityID")]
            description = "Read one entity's page: its attributed claims with modality, polarity, stated dates and evidence IDs."
        case "get_timeline":
            properties["entityID"] = uuid
            description = "Read claims ordered by their stated (valid) time, optionally only those about one entity."
        default:
            properties = ["assertionID": uuid, "evidenceID": uuid]
            required = [.string("assertionID"), .string("evidenceID")]
            description = "Read the transcript passage one claim cites: meeting, speaker, time and verbatim quote."
        }
        return AgentToolSpec(name: name, description: description + """
             Results are plain text and end with a "page:" line (pass its next offset to continue) and a \
            "revision:" line. Claims are what was said, by whom and how (reported, proposed, negated); \
            never present a proposed or negated claim as a fact. Cite the meeting and [m:ss] of the evidence.
            """,
            inputSchema: .object(["type": .string("object"), "properties": .object(properties),
                                  "required": .array(required), "additionalProperties": .bool(false)]))
    }

    struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Parameters {
        let values: [String: JSONValue]
        let offset: Int
        let limit: Int
        let selection: KnowledgeEvidenceSelection?

        init(_ arguments: JSONValue, name: String) throws {
            guard case .object(let values) = arguments else { throw Invalid("Expected an object.") }
            let permitted: Set<String> = switch name {
            case "search_knowledge": ["query", "offset", "limit"]
            case "get_entity", "get_timeline": ["entityID", "offset", "limit"]
            default: ["assertionID", "evidenceID"]
            }
            guard Set(values.keys).isSubset(of: permitted) else { throw Invalid("Unknown argument.") }
            self.values = values
            offset = try Self.integer(values["offset"], fallback: 0, range: 0...100_000)
            limit = try Self.integer(values["limit"], fallback: 10, range: 1...20)
            if name == "get_evidence" {
                let assertion = try Self.uuid(values["assertionID"], key: "assertionID")
                let evidence = try Self.uuid(values["evidenceID"], key: "evidenceID")
                selection = KnowledgeEvidenceSelection(assertionID: assertion, evidenceID: evidence)
            } else {
                selection = nil
            }
        }

        func string(_ key: String, limit: Int) throws -> String {
            guard case .string(let value) = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= limit else { throw Invalid("Invalid \(key).") }
            return value
        }

        func uuid(_ key: String) throws -> UUID { try Self.uuid(values[key], key: key) }

        func optionalUUID(_ key: String) throws -> UUID? {
            values[key] == nil ? nil : try uuid(key)
        }

        static func uuid(_ value: JSONValue?, key: String) throws -> UUID {
            guard case .string(let text) = value, let id = UUID(uuidString: text) else { throw Invalid("Invalid \(key).") }
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
}
