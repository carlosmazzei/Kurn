//
//  ScreenshotSeedData.swift
//  Kurn
//
//  Mock data for App Store screenshot automation (fastlane `snapshot` +
//  KurnUITests). Seeds a handful of realistic meetings — never real user
//  recordings or transcripts — into the in-memory container KurnApp builds
//  when launched with the "UI-Testing-Screenshots" argument. The whole file
//  is compiled out of Release builds.
//
//  `MeetingsListView` sorts by `createdAt` descending, and
//  `ScreenshotUITests` always opens "the first meeting" for screens
//  02MeetingRecordings/03Transcript/04Summary — so whichever meeting has the
//  newest `createdAt` here is the one those three screenshots actually show.
//  Keep the richest meeting (multiple speakers, multiple recordings, a
//  structured summary) newest for that reason.
//

#if DEBUG
import AVFoundation
import Foundation
import KurnCore
import SwiftData

@MainActor
enum ScreenshotSeedData {
    static func seed(into context: ModelContext) {
        seedRoadmapMeeting(into: context)
        seedDesignReviewMeeting(into: context)
        seedOnboardingMeeting(into: context)
        seedCustomerInterviewMeeting(into: context)
        seedArchivedStandup(into: context)
        try? context.save()
    }

    // MARK: - "Product Roadmap Sync" — hero meeting: newest, multi-speaker,
    // multiple recordings, favorited, folder + tags, full bulleted summary.

    private static func seedRoadmapMeeting(into context: ModelContext) {
        let folder = Folder(name: "Product", iconName: "lightbulb", colorHex: "#5E5CE6")
        context.insert(folder)

        let tagRoadmap = Tag(name: "Roadmap")
        let tagQ3 = Tag(name: "Q3")
        context.insert(tagRoadmap)
        context.insert(tagQ3)

        let meeting = Meeting(
            title: "Product Roadmap Sync",
            createdAt: Date().addingTimeInterval(-3600 * 1),
            language: .english,
            isFavorite: true,
            folder: folder
        )
        meeting.tags = [tagRoadmap, tagQ3]
        context.insert(meeting)

        let alex = Speaker(meeting: meeting, label: "Speaker 1", name: "Alex", color: "#5E5CE6")
        let priya = Speaker(meeting: meeting, label: "Speaker 2", name: "Priya", color: "#34C759")
        let sam = Speaker(meeting: meeting, label: "Speaker 3", name: "Sam", color: "#FF9500")
        context.insert(alex)
        context.insert(priya)
        context.insert(sam)

        let recording = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 642,
            transcriptionStatus: .done
        )
        context.insert(recording)
        writeSilentAudioFile(fileName: recording.fileName)

        let segments: [TranscriptSegment] = [
            .init(speakerLabel: "Speaker 1", startTime: 0, endTime: 18,
                  text: "Let's start with the Q3 roadmap. I want to lock the top three priorities today."),
            .init(speakerLabel: "Speaker 2", startTime: 18, endTime: 40,
                  text: "Agreed. From the customer calls, offline sync and the export flow keep coming up."),
            .init(speakerLabel: "Speaker 3", startTime: 40, endTime: 61,
                  text: "I can take the export flow — I already have a design draft from last sprint."),
            .init(speakerLabel: "Speaker 1", startTime: 61, endTime: 90,
                  text: "Great. Priya, can you scope the offline sync work by Friday?"),
            .init(speakerLabel: "Speaker 2", startTime: 90, endTime: 112,
                  text: "Yes, I'll pair with the mobile team and have a rough estimate by then."),
            .init(speakerLabel: "Speaker 3", startTime: 112, endTime: 138,
                  text: "One open question: do we still support the legacy import format, or can we drop it?"),
            .init(speakerLabel: "Speaker 1", startTime: 138, endTime: 160,
                  text: "Let's drop it — usage is under one percent and it's slowing down the export rewrite."),
            .init(speakerLabel: "Speaker 2", startTime: 160, endTime: 182,
                  text: "Sounds good. I'll write that up as a decision in the notes.")
        ]
        let transcript = Transcript(recording: recording, segments: segments, language: "en-US")
        context.insert(transcript)

        // A second, shorter recording on the same meeting — demonstrates
        // that a meeting can hold more than one take (e.g. a follow-up
        // huddle recorded later the same day).
        let followUp = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 96,
            transcriptionStatus: .done
        )
        context.insert(followUp)
        writeSilentAudioFile(fileName: followUp.fileName)

        let followUpSegments: [TranscriptSegment] = [
            .init(speakerLabel: "Speaker 1", startTime: 0, endTime: 22,
                  text: "Quick follow-up — Sam, can you share the export flow mockups before Thursday's review?"),
            .init(speakerLabel: "Speaker 3", startTime: 22, endTime: 41,
                  text: "Yes, I'll drop them in the shared folder tonight.")
        ]
        let followUpTranscript = Transcript(recording: followUp, segments: followUpSegments, language: "en-US")
        context.insert(followUpTranscript)

        let summary = Summary(
            meeting: meeting,
            sections: [
                SummarySection(
                    title: "Key Decisions",
                    items: [
                        "Ship offline sync and the export flow as the top two Q3 priorities.",
                        "Drop support for the legacy import format."
                    ]
                ),
                SummarySection(
                    title: "Action Items",
                    items: [
                        "Sam — finalize the export flow design and share mockups before Thursday.",
                        "Priya — scope offline sync with the mobile team by Friday."
                    ]
                ),
                SummarySection(
                    title: "Open Questions",
                    items: [
                        "Should the legacy import format be removed in this release or the next?"
                    ]
                )
            ],
            templateName: "General",
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)
    }

    // MARK: - "Design Review" — second-newest, two speakers, one recording,
    // its own folder + tag, bulleted summary.

    private static func seedDesignReviewMeeting(into context: ModelContext) {
        let folder = Folder(name: "Design", iconName: "paintpalette", colorHex: "#FF9500")
        context.insert(folder)

        let tagUI = Tag(name: "UI")
        context.insert(tagUI)

        let meeting = Meeting(
            title: "Design Review",
            createdAt: Date().addingTimeInterval(-3600 * 3),
            language: .english,
            folder: folder
        )
        meeting.tags = [tagUI]
        context.insert(meeting)

        let jordan = Speaker(meeting: meeting, label: "Speaker 1", name: "Jordan", color: "#FF375F")
        let sam = Speaker(meeting: meeting, label: "Speaker 2", name: "Sam", color: "#FF9500")
        context.insert(jordan)
        context.insert(sam)

        let recording = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 418,
            transcriptionStatus: .done
        )
        context.insert(recording)
        writeSilentAudioFile(fileName: recording.fileName)

        let segments: [TranscriptSegment] = [
            .init(speakerLabel: "Speaker 1", startTime: 0, endTime: 26,
                  text: "Walk me through the new export flow — I want to check the empty state first."),
            .init(speakerLabel: "Speaker 2", startTime: 26, endTime: 58,
                  text: "Sure. When there's nothing to export yet, we show a short explainer and a single call to action."),
            .init(speakerLabel: "Speaker 1", startTime: 58, endTime: 84,
                  text: "That works. Can we make the button match the accent color everywhere else in the app?"),
            .init(speakerLabel: "Speaker 2", startTime: 84, endTime: 110,
                  text: "Good catch — I'll update it before the review on Thursday.")
        ]
        let transcript = Transcript(recording: recording, segments: segments, language: "en-US")
        context.insert(transcript)

        let summary = Summary(
            meeting: meeting,
            sections: [
                SummarySection(
                    title: "Feedback",
                    items: [
                        "Empty state for the export flow is approved as designed.",
                        "Use the app's accent color for the primary button, not a one-off color."
                    ]
                ),
                SummarySection(
                    title: "Action Items",
                    items: [
                        "Jordan — update the button color before Thursday's review."
                    ]
                )
            ],
            templateName: "General",
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)
    }

    // MARK: - "Client Onboarding Call" — folder + tags, two recordings,
    // bulleted summary.

    private static func seedOnboardingMeeting(into context: ModelContext) {
        let folder = Folder(name: "Clients", iconName: "person.2", colorHex: "#34C759")
        context.insert(folder)

        let tagOnboarding = Tag(name: "Onboarding")
        let tagPriority = Tag(name: "Priority")
        context.insert(tagOnboarding)
        context.insert(tagPriority)

        let meeting = Meeting(
            title: "Client Onboarding Call",
            createdAt: Date().addingTimeInterval(-3600 * 6),
            language: .english,
            folder: folder
        )
        meeting.tags = [tagOnboarding, tagPriority]
        context.insert(meeting)

        let recording = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 305,
            transcriptionStatus: .done
        )
        context.insert(recording)
        writeSilentAudioFile(fileName: recording.fileName)

        let segments: [TranscriptSegment] = [
            .init(speakerLabel: "Speaker 1", startTime: 0, endTime: 24,
                  text: "Welcome aboard — let's walk through how your team will use Kurn day to day."),
            .init(speakerLabel: "Speaker 1", startTime: 24, endTime: 52,
                  text: "Every meeting stays on-device unless you explicitly turn on cloud transcription.")
        ]
        let transcript = Transcript(recording: recording, segments: segments, language: "en-US")
        context.insert(transcript)

        // A short second recording — a follow-up check-in a little later,
        // showing a meeting doesn't have to be a single take.
        let checkIn = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 87,
            transcriptionStatus: .done
        )
        context.insert(checkIn)
        writeSilentAudioFile(fileName: checkIn.fileName)

        let checkInSegments: [TranscriptSegment] = [
            .init(speakerLabel: "Speaker 1", startTime: 0, endTime: 19,
                  text: "Quick check-in — any questions after trying it out this week?"),
            .init(speakerLabel: "Speaker 2", startTime: 19, endTime: 44,
                  text: "Just one — can we invite two more people from our team?")
        ]
        let checkInTranscript = Transcript(recording: checkIn, segments: checkInSegments, language: "en-US")
        context.insert(checkInTranscript)

        let summary = Summary(
            meeting: meeting,
            sections: [
                SummarySection(
                    title: "Summary",
                    items: [
                        "Walked the client through on-device recording, transcription, and summaries.",
                        "Client asked about adding two more teammates."
                    ]
                ),
                SummarySection(
                    title: "Action Items",
                    items: [
                        "Send the client an invite link for two additional seats."
                    ]
                )
            ],
            templateName: "General",
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)
    }

    // MARK: - "Customer Interview" — older, single speaker, prose summary,
    // no folder/tags.

    private static func seedCustomerInterviewMeeting(into context: ModelContext) {
        let meeting = Meeting(
            title: "Customer Interview",
            createdAt: Date().addingTimeInterval(-3600 * 30),
            language: .english
        )
        context.insert(meeting)

        let recording = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 512,
            transcriptionStatus: .done
        )
        context.insert(recording)
        writeSilentAudioFile(fileName: recording.fileName)

        let segments: [TranscriptSegment] = [
            .init(speakerLabel: "Speaker 1", startTime: 0, endTime: 30,
                  text: "Tell me about the last time you had to dig up notes from an old meeting."),
            .init(speakerLabel: "Speaker 1", startTime: 30, endTime: 58,
                  text: "It took me twenty minutes to find who owned a decision we made two months ago.")
        ]
        let transcript = Transcript(recording: recording, segments: segments, language: "en-US")
        context.insert(transcript)

        let summary = Summary(
            meeting: meeting,
            sections: [
                SummarySection(
                    title: "Summary",
                    body: "Customer struggles to find decisions and owners from past meetings; search and clear action-item tracking are the biggest asks."
                )
            ],
            templateName: "General",
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)
    }

    // MARK: - "Weekly Standup — Archived" — archived, no summary

    private static func seedArchivedStandup(into context: ModelContext) {
        let meeting = Meeting(
            title: "Weekly Standup",
            createdAt: Date().addingTimeInterval(-3600 * 24 * 9),
            language: .english,
            archivedAt: Date().addingTimeInterval(-3600 * 24 * 8)
        )
        context.insert(meeting)

        let recording = Recording(
            meeting: meeting,
            fileName: AudioFileStore.fileName(meetingID: meeting.id),
            duration: 128,
            transcriptionStatus: .done
        )
        context.insert(recording)
        writeSilentAudioFile(fileName: recording.fileName)

        let segments: [TranscriptSegment] = [
            .init(speakerLabel: "Speaker 1", startTime: 0, endTime: 20,
                  text: "Quick round: what shipped last week, what's blocked?")
        ]
        let transcript = Transcript(recording: recording, segments: segments, language: "en-US")
        context.insert(transcript)
    }

    // MARK: - Silent audio backing file

    /// Synthesizes a ~1 second silent AAC file so seeded `Recording`s resolve
    /// to a real, playable file via `AudioFileStore` instead of a dangling
    /// path — avoids bundling a binary asset just for screenshot automation.
    private static func writeSilentAudioFile(fileName: String) {
        guard let directory = try? AudioFileStore.ensureRecordingsDirectory() else { return }
        let url = directory.appendingPathComponent(fileName)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = 44_100
        try? file.write(from: buffer)
    }
}
#endif
