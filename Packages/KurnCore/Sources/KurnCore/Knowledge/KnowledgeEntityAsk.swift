import Foundation

/// Ask about an entity from its Knowledge page (K5.3): a library question over the meetings its facts come from.
public enum KnowledgeEntityAsk {
    public static func sourceMeetingIDs(_ page: KnowledgeWikiPage) -> Set<UUID> {
        Set(page.sections.flatMap(\.entries).map(\.fact.source.meetingID))
    }

    /// nil when the page has no facts, so there is nothing to ask over.
    public static func scope(_ page: KnowledgeWikiPage) -> ChatSourceScope? {
        let meetings = sourceMeetingIDs(page)
        return meetings.isEmpty ? nil : ChatSourceScope(kind: .meetings, selectedIDs: meetings)
    }
}
