import Foundation
import Testing
@testable import KurnCore

struct ChatSourcePresentationTests {
    @Test func harnessReadinessDoesNotReadTheIndexWhileLegacyStillRequiresIt() {
        var reads = 0
        func index(_ value: Bool) -> Bool { reads += 1; return value }
        #expect(ChatSourcePresentation.canChat(enabled: true, usesHarness: true, hasIndex: index(false)))
        #expect(!ChatSourcePresentation.canChat(enabled: false, usesHarness: true, hasIndex: index(true)))
        #expect(!ChatSourcePresentation.canChat(enabled: false, usesHarness: false, hasIndex: index(true)))
        #expect(reads == 0)
        #expect(!ChatSourcePresentation.canChat(enabled: true, usesHarness: false, hasIndex: index(false)))
        #expect(ChatSourcePresentation.canChat(enabled: true, usesHarness: false, hasIndex: index(true)))
        #expect(reads == 2)
    }

    private func localize(_ key: String) -> String {
        ["chat.sources.summary": "%d meetings · %@", "chat.sources.summary.one": "1 meeting · %@",
         "chat.sources.part.transcript": "Transcript", "chat.sources.part.summary": "Summary",
         "chat.sources.part.wiki": "Wiki", "chat.sources.part.attachments": "Attachments",
         "chat.sources.parts.none": "No parts", "chat.sources.custom": "Custom parts"][key] ?? key
    }

    @Test func wikiPolicyGatesOverridesAndMatchesValidationWithoutChangingStoredScope() {
        let id = UUID()
        let scope = ChatSourceScope(kind: .meetings, selectedIDs: [id], parts: [.wiki, .summary], partOverrides: [id: [.wiki]])
        let effective = ChatSourcePresentation.effectiveScope(scope, wikiEnabled: false)
        #expect(effective.parts == [.summary])
        #expect(effective.parts(for: id).isEmpty)
        #expect(scope.parts(for: id) == [.wiki])
        #expect(ChatSourcePresentation.effectiveScope(scope, wikiEnabled: true) == scope)
        #expect(ChatSourcePresentation.validation(scope, resolvedMeetingIDs: [id], wikiEnabled: false) == .noParts)
        #expect(ChatSourcePresentation.validation(scope, resolvedMeetingIDs: [id], wikiEnabled: true) == nil)
        #expect(ChatSourcePresentation.validation(scope, resolvedMeetingIDs: [], wikiEnabled: true) == .noMeetings)
        #expect(ChatSourcePresentation.validationKey(.noMeetings) == "chat.sources.validation.meetings")
        #expect(ChatSourcePresentation.validationKey(.noParts) == "chat.sources.validation.parts")
    }

    @Test func summariesUseResolvedIDsEffectivePartsAndOverrideIndicators() {
        let first = UUID(), second = UUID(), other = UUID()
        let single = ChatSourceScope(kind: .meetings, selectedIDs: [first], parts: [.summary, .wiki])
        #expect(ChatSourcePresentation.summary(single, resolvedMeetingIDs: [first, other], wikiEnabled: false,
                                                localize: localize) == "1 meeting · Summary")
        let library = ChatSourceScope(kind: .library, parts: [.transcript], partOverrides: [second: [.summary], other: [.wiki]])
        #expect(ChatSourcePresentation.summary(library, resolvedMeetingIDs: [first, second], wikiEnabled: false,
                                                localize: localize) == "2 meetings · Transcript, Summary · Custom parts")
        #expect(ChatSourcePresentation.summary(single, resolvedMeetingIDs: [], wikiEnabled: false,
                                                localize: localize) == "0 meetings · No parts")
        let all = ChatSourceScope(kind: .library, parts: Set(ChatSourcePart.allCases))
        #expect(ChatSourcePresentation.summary(all, resolvedMeetingIDs: [first], wikiEnabled: true,
                                                localize: localize) == "1 meeting · Transcript, Summary, Wiki, Attachments")
    }

    @Test func partModeKeysAndMeetingSearch() {
        for part in ChatSourcePart.allCases { #expect(ChatSourcePresentation.partKey(part) == "chat.sources.part.\(part.rawValue)") }
        for kind in [ChatSourceScope.Kind.meetings, .tags, .folders, .library] {
            #expect(ChatSourcePresentation.modeKey(kind) == "chat.sources.mode.\(kind.rawValue)")
        }
        #expect(ChatSourcePresentation.matchesSearch(" \n ", title: "Planning"))
        #expect(ChatSourcePresentation.matchesSearch(" PLAN ", title: "Quarterly planning"))
        #expect(ChatSourcePresentation.matchesSearch("会议", title: "团队会议"))
        #expect(!ChatSourcePresentation.matchesSearch("Budget", title: "Planning"))
        #expect(!ChatSourcePresentation.matchesSearch("Plan", title: ""))
    }
}
