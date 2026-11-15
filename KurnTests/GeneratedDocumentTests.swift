//
//  GeneratedDocumentTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct GeneratedDocumentTests {

    private func transcribedMeeting(
        title: String,
        context: ModelContext,
        folder: Folder? = nil,
        tags: [Kurn.Tag] = []
    ) -> Meeting {
        let meeting = Meeting(title: title, folder: folder)
        meeting.tags = tags
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "\(UUID()).m4a", duration: 10)
        context.insert(recording)
        context.insert(
            Transcript(
                recording: recording,
                segments: [
                    TranscriptSegment(
                        speakerLabel: "Speaker 1",
                        startTime: 0,
                        endTime: 1,
                        text: title
                    )
                ]
            )
        )
        return meeting
    }

    @Test func modelPersistsSourceSnapshots() throws {
        let context = ModelContext(TestModelContainer.make())
        let meetingID = UUID()
        let document = GeneratedDocument(
            title: "Project Status",
            bodyMarkdown: "# Project Status\n\nOn track.",
            userPrompt: "Create a status report",
            sourceKind: .tags,
            sourceNames: ["Project Alpha", "Customer"],
            sourceMeetingIDs: [meetingID],
            generatorModelIdentifier: "openai:gpt"
        )
        context.insert(document)
        try context.save()

        let stored = try #require(context.fetch(FetchDescriptor<GeneratedDocument>()).first)
        #expect(stored.sourceKind == .tags)
        #expect(stored.sourceNames == ["Project Alpha", "Customer"])
        #expect(stored.sourceMeetingIDs == [meetingID])
        #expect(stored.bodyMarkdown.contains("On track"))
    }

    @Test func resolverIncludesTaggedMeetingsOnlyOnce() throws {
        let context = ModelContext(TestModelContainer.make())
        let customer = Tag(name: "Customer")
        let urgent = Tag(name: "Urgent")
        context.insert(customer)
        context.insert(urgent)
        let bothTags = transcribedMeeting(
            title: "Both",
            context: context,
            tags: [customer, urgent]
        )
        let urgentOnly = transcribedMeeting(title: "Urgent only", context: context, tags: [urgent])
        let withoutTranscript = Meeting(title: "No transcript")
        withoutTranscript.tags = [customer]
        context.insert(withoutTranscript)
        try context.save()

        let result = DocumentSourceResolver.resolve(
            kind: .tags,
            selectedIDs: [customer.id, urgent.id],
            meetings: [bothTags, urgentOnly, withoutTranscript],
            tags: [customer, urgent],
            folders: []
        )

        #expect(Set(result.meetings.map { $0.title }) == Set(["Both", "Urgent only"]))
        #expect(result.meetings.count == 2)
        #expect(result.sourceNames == ["Customer", "Urgent"])
    }

    @Test func resolverExpandsSelectedFolderIntoSubfolders() throws {
        let context = ModelContext(TestModelContainer.make())
        let root = Folder(name: "Root")
        context.insert(root)
        let child = Folder(name: "Child", parent: root)
        context.insert(child)
        let rootMeeting = transcribedMeeting(title: "Root meeting", context: context, folder: root)
        let childMeeting = transcribedMeeting(title: "Child meeting", context: context, folder: child)
        let elsewhere = transcribedMeeting(title: "Elsewhere", context: context)
        try context.save()

        let result = DocumentSourceResolver.resolve(
            kind: .folders,
            selectedIDs: [root.id],
            meetings: [rootMeeting, childMeeting, elsewhere],
            tags: [],
            folders: [root, child]
        )

        #expect(Set(result.meetings.map { $0.title }) == Set(["Root meeting", "Child meeting"]))
        #expect(result.sourceNames == ["Root"])
        #expect(
            DocumentSourceResolver.transcriptCount(
                in: root,
                meetings: [rootMeeting, childMeeting, elsewhere],
                folders: [root, child]
            ) == 2
        )
    }
}
