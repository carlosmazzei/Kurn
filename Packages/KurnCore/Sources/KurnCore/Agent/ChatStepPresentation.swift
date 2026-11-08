import AgentHarness
import Foundation

public struct ChatStepPresentation: Sendable, Equatable {
    public let key: String
    public let parameter: String?
    public let parameterKey: String?
    public let symbol: String

    public init(step: ChatAgentStep, meetingTitles: [UUID: String] = [:], documentTitles: [UUID: String] = [:]) {
        switch step.kind {
        case .turn:
            key = "chat.step.turn"
            parameter = String((step.turnIndex ?? 0) + 1)
            parameterKey = nil
            symbol = "sparkles"
        case .compaction:
            key = "chat.step.compaction"
            parameter = nil
            parameterKey = nil
            symbol = "arrow.down.right.and.arrow.up.left"
        case .stop:
            key = "chat.step.stop.\(step.stopReason?.rawValue ?? "unknown")"
            parameter = nil
            parameterKey = nil
            symbol = "checkmark.circle"
        case .context:
            key = "chat.step.context"
            parameter = nil
            parameterKey = nil
            symbol = "gauge.with.dots.needle.50percent"
        case .diagnostic:
            key = "chat.diagnostic.\(step.diagnostic?.kind.rawValue ?? "unknown")"
            parameter = nil
            parameterKey = nil
            symbol = step.diagnostic?.kind == .limitReached ? "exclamationmark.circle" : "list.bullet.rectangle"
        case .tool:
            let name = step.toolName ?? ""
            key = Self.toolKeys[name] ?? "chat.step.tool"
            symbol = Self.toolSymbols[name] ?? "wrench.and.screwdriver"
            let arguments: [String: JSONValue]
            if case .object(let object) = step.arguments { arguments = object } else { arguments = [:] }
            if name == "list_sources" {
                parameter = nil
                parameterKey = nil
            } else if name == "search" {
                parameter = Self.string(arguments["query"])
                parameterKey = "chat.step.query"
            } else if ["read_transcript", "read_summary", "read_wiki", "read_attachment"].contains(name) {
                parameter = Self.string(arguments["meetingID"]).flatMap(UUID.init(uuidString:)).flatMap { meetingTitles[$0] }
                parameterKey = "chat.step.meeting"
            } else if Self.documentTools.contains(name) {
                parameter = Self.string(arguments["title"])
                    ?? Self.string(arguments["document_id"]).flatMap(UUID.init(uuidString:)).flatMap { documentTitles[$0] }
                parameterKey = "chat.step.document"
            } else {
                parameter = name.isEmpty ? nil : name
                parameterKey = "chat.step.tool.unknown"
            }
        }
    }

    public func title(localize: (String) -> String) -> String {
        let title = localize(key)
        guard let parameter = parameter ?? parameterKey.map(localize) else { return title }
        return String(format: title, parameter)
    }

    public static func visibleSteps(_ steps: [ChatAgentStep]) -> [ChatAgentStep] {
        steps.filter { $0.kind != .turn && !($0.kind == .stop && $0.stopReason == .completed) }
    }

    public static func countLabel(_ count: Int, localize: (String) -> String) -> String {
        count == 1 ? localize("chat.steps.one") : String(format: localize("chat.steps.count"), count)
    }

    public static func preview(_ text: String, limit: Int = 2_000) -> String {
        let scalars = text.unicodeScalars
        let count = max(1, limit)
        return scalars.count > count ? String(String.UnicodeScalarView(scalars.prefix(count))) + "…" : text
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static let documentTools: Set<String> = ["create_document", "update_document", "append_to_document", "read_document"]
    private static let toolKeys = Dictionary(uniqueKeysWithValues: [
        "list_sources", "search", "read_transcript", "read_summary", "read_wiki", "read_attachment",
        "create_document", "update_document", "append_to_document", "read_document"
    ].map { ($0, "chat.step.\($0)") })
    private static let toolSymbols = [
        "list_sources": "list.bullet", "search": "magnifyingglass", "read_transcript": "text.quote",
        "read_summary": "text.alignleft", "read_wiki": "book", "read_attachment": "paperclip",
        "create_document": "doc.badge.plus", "update_document": "pencil", "append_to_document": "text.append",
        "read_document": "doc.text"
    ]
}
