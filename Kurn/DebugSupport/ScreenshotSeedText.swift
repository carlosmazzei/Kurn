//
//  ScreenshotSeedText.swift
//  Kurn
//
//  The words `ScreenshotSeedData` writes into its mock meetings, one table per
//  App Store screenshot language. fastlane `snapshot` launches the app with
//  `-AppleLanguages (<language>)` for each language in `fastlane/Snapfile`, so
//  the seeded titles, transcripts and summaries follow the same language as
//  the UI around them — a German store page should not show a German app
//  full of English meetings. The structure is identical in every language
//  (same speakers, same number of lines, same timings in `ScreenshotSeedData`);
//  only the text differs. Compiled out of Release builds.
//

#if DEBUG
import Foundation
import KurnCore

struct ScreenshotSeedSection {
    let title: String
    let items: [String]
}

struct ScreenshotSeedText {
    let language: MeetingLanguage
    let transcriptLanguage: String
    let templateName: String

    let productFolder: String
    let roadmapTags: [String]
    let roadmapTitle: String
    /// Eight lines: Alex, Priya, Sam, Alex, Priya, Sam, Alex, Priya.
    let roadmapLines: [String]
    /// Two lines: Alex, Sam.
    let roadmapFollowUp: [String]
    let roadmapSections: [ScreenshotSeedSection]
    let roadmapAttachmentName: String
    let roadmapAttachmentText: String

    let designFolder: String
    let designTag: String
    let designTitle: String
    /// Four lines: Jordan, Sam, Jordan, Sam.
    let designLines: [String]
    let designSections: [ScreenshotSeedSection]

    let clientsFolder: String
    let onboardingTags: [String]
    let onboardingTitle: String
    /// Two lines, both Speaker 1.
    let onboardingLines: [String]
    /// Two lines: Speaker 1, Speaker 2.
    let onboardingCheckIn: [String]
    let onboardingSections: [ScreenshotSeedSection]

    let interviewTitle: String
    /// Two lines, both Speaker 1.
    let interviewLines: [String]
    let interviewSummaryTitle: String
    let interviewSummary: String

    let standupTitle: String
    let standupLine: String

    /// The table for the first preferred language that has one, English
    /// otherwise. Matched on the language code alone, so `pt-PT` gets the
    /// Brazilian table and `zh-Hans-CN` the Simplified Chinese one.
    static func current(preferredLanguages: [String] = Locale.preferredLanguages) -> ScreenshotSeedText {
        for identifier in preferredLanguages {
            let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased()
            if let code, let table = byLanguageCode[code] {
                return table
            }
        }
        return .english
    }

    static let byLanguageCode: [String: ScreenshotSeedText] = [
        "en": .english,
        "pt": .portuguese,
        "es": .spanish,
        "fr": .french,
        "it": .italian,
        "de": .german,
        "zh": .chinese
    ]

    static let english = ScreenshotSeedText(
        language: .english,
        transcriptLanguage: "en-US",
        templateName: "General",
        productFolder: "Product",
        roadmapTags: ["Roadmap", "Q3"],
        roadmapTitle: "Product Roadmap Sync",
        roadmapLines: [
            "Let's start with the Q3 roadmap. I want to lock the top three priorities today.",
            "Agreed. From the customer calls, offline sync and the export flow keep coming up.",
            "I can take the export flow — I already have a design draft from last sprint.",
            "Great. Priya, can you scope the offline sync work by Friday?",
            "Yes, I'll pair with the mobile team and have a rough estimate by then.",
            "One open question: do we still support the legacy import format, or can we drop it?",
            "Let's drop it — usage is under one percent and it's slowing down the export rewrite.",
            "Sounds good. I'll write that up as a decision in the notes."
        ],
        roadmapFollowUp: [
            "Quick follow-up — Sam, can you share the export flow mockups before Thursday's review?",
            "Yes, I'll drop them in the shared folder tonight."
        ],
        roadmapSections: [
            ScreenshotSeedSection(title: "Key Decisions", items: [
                "Ship offline sync and the export flow as the top two Q3 priorities.",
                "Drop support for the legacy import format."
            ]),
            ScreenshotSeedSection(title: "Action Items", items: [
                "Sam — finalize the export flow design and share mockups before Thursday.",
                "Priya — scope offline sync with the mobile team by Friday."
            ]),
            ScreenshotSeedSection(title: "Open Questions", items: [
                "Should the legacy import format be removed in this release or the next?"
            ])
        ],
        roadmapAttachmentName: "Q3 Roadmap.pdf",
        roadmapAttachmentText: "Q3 roadmap: onboarding redesign, offline sync, pricing page.",
        designFolder: "Design",
        designTag: "UI",
        designTitle: "Design Review",
        designLines: [
            "Walk me through the new export flow — I want to check the empty state first.",
            "Sure. When there's nothing to export yet, we show a short explainer and a single call to action.",
            "That works. Can we make the button match the accent color everywhere else in the app?",
            "Good catch — I'll update it before the review on Thursday."
        ],
        designSections: [
            ScreenshotSeedSection(title: "Feedback", items: [
                "Empty state for the export flow is approved as designed.",
                "Use the app's accent color for the primary button, not a one-off color."
            ]),
            ScreenshotSeedSection(title: "Action Items", items: [
                "Jordan — update the button color before Thursday's review."
            ])
        ],
        clientsFolder: "Clients",
        onboardingTags: ["Onboarding", "Priority"],
        onboardingTitle: "Client Onboarding Call",
        onboardingLines: [
            "Welcome aboard — let's walk through how your team will use Kurn day to day.",
            "Every meeting stays on-device unless you explicitly turn on cloud transcription."
        ],
        onboardingCheckIn: [
            "Quick check-in — any questions after trying it out this week?",
            "Just one — can we invite two more people from our team?"
        ],
        onboardingSections: [
            ScreenshotSeedSection(title: "Summary", items: [
                "Walked the client through on-device recording, transcription, and summaries.",
                "Client asked about adding two more teammates."
            ]),
            ScreenshotSeedSection(title: "Action Items", items: [
                "Send the client an invite link for two additional seats."
            ])
        ],
        interviewTitle: "Customer Interview",
        interviewLines: [
            "Tell me about the last time you had to dig up notes from an old meeting.",
            "It took me twenty minutes to find who owned a decision we made two months ago."
        ],
        interviewSummaryTitle: "Summary",
        interviewSummary: "Customer struggles to find decisions and owners from past meetings; search and clear action-item tracking are the biggest asks.",
        standupTitle: "Weekly Standup",
        standupLine: "Quick round: what shipped last week, what's blocked?"
    )
}
#endif
