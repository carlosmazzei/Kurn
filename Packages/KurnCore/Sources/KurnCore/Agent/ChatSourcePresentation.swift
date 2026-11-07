import Foundation

public enum ChatSourcePresentation {
    public static func canChat(enabled: Bool, usesHarness: Bool, hasIndex: @autoclosure () -> Bool) -> Bool {
        enabled && (usesHarness || hasIndex())
    }

    public static func effectiveScope(_ scope: ChatSourceScope, wikiEnabled: Bool) -> ChatSourceScope {
        guard !wikiEnabled else { return scope }
        var effective = scope
        effective.parts.remove(.wiki)
        effective.partOverrides = effective.partOverrides.mapValues { $0.subtracting([.wiki]) }
        return effective
    }

    public static func validation(_ scope: ChatSourceScope, resolvedMeetingIDs: Set<UUID>,
                                  wikiEnabled: Bool) -> ChatSourceScopeEditor.Validation? {
        ChatSourceScopeEditor(scope: effectiveScope(scope, wikiEnabled: wikiEnabled))
            .validation(resolvedMeetingIDs: resolvedMeetingIDs)
    }

    public static func validationKey(_ validation: ChatSourceScopeEditor.Validation) -> String {
        switch validation {
        case .noMeetings: "chat.sources.validation.meetings"
        case .noParts: "chat.sources.validation.parts"
        }
    }

    public static func partKey(_ part: ChatSourcePart) -> String { "chat.sources.part.\(part.rawValue)" }
    public static func modeKey(_ kind: ChatSourceScope.Kind) -> String { "chat.sources.mode.\(kind.rawValue)" }

    public static func matchesSearch(_ query: String, title: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    public static func summary(_ scope: ChatSourceScope, resolvedMeetingIDs: Set<UUID>, wikiEnabled: Bool,
                               localize: (String) -> String) -> String {
        let effective = effectiveScope(scope, wikiEnabled: wikiEnabled)
        let selected = scope.kind == .meetings ? resolvedMeetingIDs.intersection(scope.selectedIDs) : resolvedMeetingIDs
        let parts = selected.reduce(into: Set<ChatSourcePart>()) { $0.formUnion(effective.parts(for: $1)) }
        let labels = ChatSourcePart.allCases.filter { parts.contains($0) }.map { localize(partKey($0)) }
        let label = labels.isEmpty ? localize("chat.sources.parts.none") : labels.joined(separator: ", ")
        let summary = selected.count == 1
            ? String(format: localize("chat.sources.summary.one"), label)
            : String(format: localize("chat.sources.summary"), selected.count, label)
        return selected.contains { scope.partOverrides[$0] != nil }
            ? summary + " · " + localize("chat.sources.custom") : summary
    }
}
