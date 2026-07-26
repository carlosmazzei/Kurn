//
//  GeneratedDocumentTests.swift
//  KurnTests
//

import Foundation
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

    @Test func extractsMarkdownHeadingAsTitle() {
        let title = DocumentGenerationService.extractTitle(
            from: "# Quarterly Project Review\n\nDetails",
            fallbackPrompt: "Fallback"
        )
        #expect(title == "Quarterly Project Review")
    }

    @Test func fallsBackToFirstPromptLineForLongFirstLine() {
        let longLine = String(repeating: "a", count: 121)
        let title = DocumentGenerationService.extractTitle(
            from: longLine,
            fallbackPrompt: "Create an executive brief\nwith details"
        )
        #expect(title == "Create an executive brief")
    }

    @Test func rendersEverySourceWithMeetingBoundaries() {
        let firstID = UUID()
        let secondID = UUID()
        let sources = [
            DocumentTranscriptSource(
                meetingID: firstID,
                title: "Planning",
                date: Date(timeIntervalSince1970: 0),
                transcript: "[00:01] Ana: First"
            ),
            DocumentTranscriptSource(
                meetingID: secondID,
                title: "Review",
                date: Date(timeIntervalSince1970: 1),
                transcript: "[00:02] Ben: Second"
            )
        ]

        let rendered = DocumentGenerationService.render(sources)
        #expect(rendered.contains(firstID.uuidString))
        #expect(rendered.contains(secondID.uuidString))
        #expect(rendered.contains("Ana: First"))
        #expect(rendered.contains("Ben: Second"))
        #expect(rendered.components(separatedBy: "<meeting ").count == 3)
    }

    @Test func longSourceBlocksRepeatMeetingMetadata() {
        let meetingID = UUID()
        let transcript = (0..<30)
            .map { "[00:\(String(format: "%02d", $0))] Ana: detail \($0)" }
            .joined(separator: "\n")
        let source = DocumentTranscriptSource(
            meetingID: meetingID,
            title: "Long planning",
            date: Date(timeIntervalSince1970: 0),
            transcript: transcript
        )

        let blocks = DocumentGenerationService.renderBlocks([source], maxChars: 280)

        #expect(blocks.count > 1)
        for block in blocks {
            #expect(block.contains(meetingID.uuidString))
            #expect(block.contains("Title: Long planning"))
            #expect(block.components(separatedBy: "<meeting ").count == 2)
            #expect(block.components(separatedBy: "</meeting>").count == 2)
        }
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
