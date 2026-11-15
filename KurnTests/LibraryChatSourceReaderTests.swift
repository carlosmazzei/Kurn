import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct LibraryChatSourceReaderTests {
    private func meeting(_ context: ModelContext, title: String = "Meeting") -> Meeting {
        let meeting = Meeting(title: title)
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "source.m4a", duration: 10)
        context.insert(recording)
        context.insert(Transcript(recording: recording, segments: [
            TranscriptSegment(speakerLabel: "Pat", startTime: 2, endTime: 5, text: "Decision")
        ]))
        return meeting
    }

    @Test func scopeResolutionAndDocumentCompatibility() throws {
        let context = ModelContext(TestModelContainer.make())
        let parent = Folder(name: "Parent")
        context.insert(parent)
        let child = Folder(name: "Child", parent: parent)
        context.insert(child)
        let tag = Kurn.Tag(name: "Project")
        context.insert(tag)
        let selected = meeting(context)
        selected.folder = child
        selected.tags = [tag]
        let other = meeting(context, title: "Other")
        let blank = Meeting(title: "Blank", folder: child)
        context.insert(blank)
        try context.save()
        let meetings = [selected, other, blank]
        for (kind, ids) in [(ChatSourceScope.Kind.meetings, Set([selected.id])),
                            (.tags, Set([tag.id])), (.folders, Set([parent.id]))] {
            let result = SourceScopeResolver.resolve(ChatSourceScope(kind: kind, selectedIDs: ids),
                                                     meetings: meetings, tags: [tag], folders: [parent, child])
            #expect(result.meetings.map(\.id) == [selected.id])
        }
        let library = SourceScopeResolver.resolve(ChatSourceScope(kind: .library), meetings: meetings, tags: [], folders: [])
        #expect(Set(library.meetings.map(\.id)) == [selected.id, other.id])
        let empty = SourceScopeResolver.resolve(ChatSourceScope(kind: .meetings), meetings: meetings, tags: [], folders: [])
        #expect(empty.meetings.isEmpty)
        let documents = DocumentSourceResolver.resolve(kind: .folders, selectedIDs: [parent.id], meetings: meetings,
                                                       tags: [tag], folders: [parent, child])
        #expect(documents.meetings.map(\.id) == [selected.id])
        #expect(documents.sourceNames == ["Parent"])
    }

    @Test func readsStoredContentAndRejectsUnscopedIDs() async throws {
        let context = ModelContext(TestModelContainer.make())
        let selected = meeting(context)
        let other = meeting(context, title: "Other")
        context.insert(Summary(meeting: selected, sections: [SummarySection(title: "Facts", body: "Body", items: ["Item"])],
                               provider: .openAI))
        context.insert(WikiArticle(meeting: selected, bodyMarkdown: "Wiki", meetingTitleSnapshot: "Meeting",
                                   meetingDate: .now, sourceContentHash: "hash", generatorModelIdentifier: "test"))
        let attachment = MeetingAttachment(meeting: selected, fileName: "unused.pdf", displayName: "Reference",
                                           extractedText: "Attachment text")
        context.insert(attachment)
        try context.save()
        let reader = LibraryChatSourceReader(context: context, scope: ChatSourceScope(kind: .meetings,
                                             selectedIDs: [selected.id], parts: Set(ChatSourcePart.allCases)), search: { _, _, _ in [] })
        let sources = try await reader.listSources()
        #expect(sources.count == 1)
        #expect(sources.first?.hasSummary == true)
        #expect(sources.first?.hasWiki == true)
        #expect(sources.first?.hasAttachments == true)
        let page = try await reader.readTranscript(meetingID: selected.id, offset: 0, limit: 1)
        #expect(page.total == 1)
        #expect(page.passages.first?.timestamp == 2)
        #expect(page.passages.first?.text == "Decision")
        let summary = try await reader.readSummary(meetingID: selected.id)
        #expect(summary?.contains("Body") == true)
        let wiki = try await reader.readWiki(meetingID: selected.id)
        #expect(wiki == "Wiki")
        let attachments = try await reader.listAttachments(meetingID: selected.id)
        #expect(attachments.first?.id == attachment.id)
        let text = try await reader.readAttachment(meetingID: selected.id, attachmentID: attachment.id)
        #expect(text == "Attachment text")
        for id in [other.id, UUID()] {
            let transcript = try await reader.readTranscript(meetingID: id, offset: 0, limit: 10)
            let summary = try await reader.readSummary(meetingID: id)
            let wiki = try await reader.readWiki(meetingID: id)
            let attachments = try await reader.listAttachments(meetingID: id)
            let text = try await reader.readAttachment(meetingID: id, attachmentID: attachment.id)
            #expect(transcript.total == 0)
            #expect(summary == nil)
            #expect(wiki == nil)
            #expect(attachments.isEmpty)
            #expect(text == nil)
        }
        let disabled = LibraryChatSourceReader(context: context, scope: ChatSourceScope(kind: .library))
        let disabledWiki = try await disabled.readWiki(meetingID: selected.id)
        #expect(disabledWiki == nil)
        let missingSummary = try await disabled.readSummary(meetingID: other.id)
        #expect(missingSummary == nil)
        let emptySearch = try await reader.search(query: "Decision", meetingIDs: [selected.id], limit: 10)
        #expect(emptySearch.isEmpty)
        let beyondEnd = try await reader.readTranscript(meetingID: selected.id, offset: 1, limit: 10)
        #expect(beyondEnd.passages.isEmpty)
        #expect(beyondEnd.total == 1)
        let unknownAttachment = try await reader.readAttachment(meetingID: selected.id, attachmentID: UUID())
        #expect(unknownAttachment == nil)
    }

    @Test func hybridRetrievalReceivesOnlyScopedSnapshotsAndPropagatesErrors() async throws {
        let context = ModelContext(TestModelContainer.make())
        let selected = meeting(context)
        let other = meeting(context)
        for meeting in [selected, other] {
            context.insert(SemanticChunk(meeting: meeting, recordingID: UUID(), text: "Decision", startTime: 2,
                                         endTime: 3, speakerLabel: "Pat", vector: [1], modelIdentifier: "test"))
        }
        try context.save()
        let selectedID = selected.id
        let otherID = other.id
        let scope = ChatSourceScope(kind: .meetings, selectedIDs: [selectedID])
        let reader = LibraryChatSourceReader(context: context, scope: scope, search: { query, candidates, limit in
            #expect(query == "Decision")
            #expect(candidates.map(\.meetingID) == [selectedID])
            #expect(limit == 100)
            return [selectedID, otherID].map {
                SemanticSearchService.Hit(chunkID: UUID(), meetingID: $0, recordingID: UUID(), text: "Decision",
                                          start: 2, end: 3, speakerLabel: "Pat", score: 1)
            }
        })
        let hits = try await reader.search(query: "Decision", meetingIDs: [selectedID, otherID], limit: 500)
        #expect(hits.map(\.meetingID) == [selectedID])
        struct Failure: Error {}
        let failing = LibraryChatSourceReader(context: context, scope: scope, search: { _, _, _ in throw Failure() })
        await #expect(throws: Failure.self) {
            try await failing.search(query: "Decision", meetingIDs: [selectedID], limit: 1)
        }
    }

    @Test func partOverridesGateStoredReadsAndRetrieval() async throws {
        let context = ModelContext(TestModelContainer.make())
        let denied = meeting(context)
        let allowed = meeting(context)
        for source in [denied, allowed] {
            context.insert(Summary(meeting: source, sections: [], provider: .openAI))
            context.insert(WikiArticle(meeting: source, bodyMarkdown: "Wiki", meetingTitleSnapshot: "Meeting",
                                       meetingDate: .now, sourceContentHash: "hash", generatorModelIdentifier: "test"))
            context.insert(MeetingAttachment(meeting: source, fileName: "unused.pdf", displayName: "Reference", extractedText: "Text"))
            context.insert(SemanticChunk(meeting: source, recordingID: UUID(), text: "Decision", startTime: 2,
                                         endTime: 3, speakerLabel: "Pat", vector: [1], modelIdentifier: "test"))
        }
        try context.save()
        let allowedID = allowed.id
        let scope = ChatSourceScope(kind: .library, parts: [], partOverrides: [allowedID: Set(ChatSourcePart.allCases)])
        let reader = LibraryChatSourceReader(context: context, scope: scope, search: { _, candidates, _ in
            #expect(candidates.map(\.meetingID) == [allowedID])
            return []
        })
        let sources = try await reader.listSources()
        #expect(sources.first { $0.id == denied.id }?.hasSummary == false)
        #expect(sources.first { $0.id == denied.id }?.hasWiki == false)
        #expect(sources.first { $0.id == denied.id }?.hasAttachments == false)
        #expect(sources.first { $0.id == allowedID }?.hasWiki == true)
        let transcript = try await reader.readTranscript(meetingID: denied.id, offset: 0, limit: 10)
        #expect(transcript.total == 0)
        let summary = try await reader.readSummary(meetingID: denied.id)
        #expect(summary == nil)
        let wiki = try await reader.readWiki(meetingID: denied.id)
        #expect(wiki == nil)
        let attachments = try await reader.listAttachments(meetingID: denied.id)
        #expect(attachments.isEmpty)
        let text = try await reader.readAttachment(meetingID: denied.id, attachmentID: UUID())
        #expect(text == nil)
        let search = try await reader.search(query: "Decision", meetingIDs: [denied.id, allowedID], limit: 10)
        #expect(search.isEmpty)
        let deniedSearch = try await reader.search(query: "Decision", meetingIDs: [denied.id], limit: 10)
        #expect(deniedSearch.isEmpty)
    }
}
