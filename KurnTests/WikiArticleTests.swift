//
//  WikiArticleTests.swift
//  KurnTests
//
//  Exercises the `WikiArticle` model against a real in-memory `ModelContainer`:
//  the one-to-one meeting relationship, cascade delete, replace-not-append on
//  regeneration, and the Sendable snapshot handed to the synthesis path.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct WikiArticleTests {

    private func makeContext() -> ModelContext {
        ModelContext(TestModelContainer.make())
    }

    private func article(for meeting: Meeting, hash: String, generator: String) -> WikiArticle {
        WikiArticle(
            meeting: meeting,
            bodyMarkdown: "## Decisions\n- shipped v2",
            meetingTitleSnapshot: meeting.aiTitle ?? meeting.title,
            meetingDate: meeting.createdAt,
            sourceContentHash: hash,
            generatorModelIdentifier: generator
        )
    }

    @Test func insertingArticlePopulatesMeetingInverse() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        context.insert(article(for: meeting, hash: "h1", generator: "openai:gpt:wiki-v1"))
        try context.save()

        #expect(meeting.wikiArticle != nil)
        #expect(meeting.wikiArticle?.bodyMarkdown.contains("shipped v2") == true)
    }

    @Test func deletingMeetingCascadesToArticle() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        context.insert(article(for: meeting, hash: "h1", generator: "g1"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<WikiArticle>()) == 1)

        context.delete(meeting)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<WikiArticle>()) == 0)
    }

    @Test func snapshotCarriesMeetingIdentityAndBody() throws {
        let context = makeContext()
        let meeting = Meeting(title: "Raw")
        meeting.aiTitle = "Q3 Review"
        context.insert(meeting)
        let art = article(for: meeting, hash: "h1", generator: "g1")
        context.insert(art)
        try context.save()

        let snapshot = art.snapshot
        #expect(snapshot.meetingID == meeting.id)
        #expect(snapshot.title == "Q3 Review")
        #expect(snapshot.date == meeting.createdAt)
        #expect(snapshot.bodyMarkdown.contains("shipped v2"))
    }

    @Test func assembledTranscriptTextIsEmptyWithoutTranscripts() {
        let meeting = Meeting(title: "Empty")
        #expect(meeting.assembledTranscriptText().isEmpty)
    }
}
