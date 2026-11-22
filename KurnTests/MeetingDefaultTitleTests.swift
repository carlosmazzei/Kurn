//
//  MeetingDefaultTitleTests.swift
//  KurnTests
//
//  `Meeting.isDefaultTitle` must recognize the generated placeholder by
//  shape, not just by equality with a re-rendered `createdAt` — a meeting
//  recorded in another time zone ("Reunião – 2026-11-02 15:10 GMT-8") or
//  while the device spoke another language still carries a generated title.
//

import Foundation
import Testing
@testable import Kurn

struct MeetingDefaultTitleTests {

    @Test func generatedTitleInTheCurrentZoneIsDefault() {
        let createdAt = Date()
        let meeting = Meeting(
            title: Meeting.generatedTitle(for: createdAt),
            createdAt: createdAt
        )
        #expect(meeting.isDefaultTitle)
    }

    @Test func generatedTitleFromAnotherTimeZoneIsDefault() {
        // Rendered by a device in GMT-8 (and in Portuguese); the meeting is
        // now opened in a different zone and language, so an exact re-render
        // could never match.
        let meeting = Meeting(title: "Reunião – 2026-11-02 15:10 GMT-8")
        #expect(meeting.isDefaultTitle)
    }

    @Test func generatedTitleFromAnotherLanguageIsDefault() {
        // Every bundled "X – <stamp>" localization is recognized, not only
        // the one the device currently speaks.
        for title in [
            "Meeting – 2026-11-02 15:10 GMT+1",
            "Réunion – 2026-11-02 15:10 GMT+1",
            "会议 – 2026-11-02 15:10 GMT+1"
        ] {
            #expect(Meeting(title: title).isDefaultTitle, "\(title) should be a default title")
        }
    }

    @Test func typedTitleIsNotDefault() {
        #expect(!Meeting(title: "Weekly sync with the design team").isDefaultTitle)
        // A title that only shares the prefix must not match either.
        #expect(!Meeting(title: "Meeting – notes from the call").isDefaultTitle)
    }

    @Test func aiGeneratedTitleIsNotDefault() {
        // An AI title is prose, not a timestamp — it leads the card only via
        // `secondaryTitle`, never as the default placeholder.
        let meeting = Meeting(title: "Q3 roadmap priorities and next steps")
        meeting.aiTitle = "Q3 roadmap priorities"
        #expect(!meeting.isDefaultTitle)
    }
}
