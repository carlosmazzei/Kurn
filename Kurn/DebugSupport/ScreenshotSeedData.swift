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
//  Every word written here comes from `ScreenshotSeedText`, in the language
//  `snapshot` launched the app in, so each store language's screenshots show
//  meetings in that language.
//

#if DEBUG
import AVFoundation
import Foundation
import KurnCore
import SwiftData

@MainActor
enum ScreenshotSeedData {
    static func seed(into context: ModelContext, text: ScreenshotSeedText = .current()) {
        seedRoadmapMeeting(into: context, text: text)
        seedDesignReviewMeeting(into: context, text: text)
        seedOnboardingMeeting(into: context, text: text)
        seedCustomerInterviewMeeting(into: context, text: text)
        seedArchivedStandup(into: context, text: text)
        try? context.save()
    }

    /// Transcript segments for `lines`, one per line, on the timings and
    /// speakers `ScreenshotSeedData` gives them in every language.
    private static func timedSegments(_ lines: [String], _ timeline: [(String, Double, Double)]) -> [TranscriptSegment] {
        zip(lines, timeline).map { line, slot in
            TranscriptSegment(speakerLabel: slot.0, startTime: slot.1, endTime: slot.2, text: line)
        }
    }

    private static func summarySections(_ sections: [ScreenshotSeedSection]) -> [SummarySection] {
        sections.map { SummarySection(title: $0.title, items: $0.items) }
    }

    // MARK: - "Product Roadmap Sync" — hero meeting: newest, multi-speaker,
    // multiple recordings, favorited, folder + tags, full bulleted summary.

    private static func seedRoadmapMeeting(into context: ModelContext, text: ScreenshotSeedText) {
        let folder = Folder(name: text.productFolder, iconName: "lightbulb", colorHex: "#5E5CE6")
        context.insert(folder)

        let tagRoadmap = Tag(name: text.roadmapTags[0])
        let tagQ3 = Tag(name: text.roadmapTags[1])
        context.insert(tagRoadmap)
        context.insert(tagQ3)

        let meeting = Meeting(
            title: text.roadmapTitle,
            createdAt: Date().addingTimeInterval(-3600 * 1),
            language: text.language,
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

        let segments = timedSegments(text.roadmapLines, [
            ("Speaker 1", 0, 18),
            ("Speaker 2", 18, 40),
            ("Speaker 3", 40, 61),
            ("Speaker 1", 61, 90),
            ("Speaker 2", 90, 112),
            ("Speaker 3", 112, 138),
            ("Speaker 1", 138, 160),
            ("Speaker 2", 160, 182)
        ])
        let transcript = Transcript(recording: recording, segments: segments, language: text.transcriptLanguage)
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

        let followUpSegments = timedSegments(text.roadmapFollowUp, [
            ("Speaker 1", 0, 22),
            ("Speaker 3", 22, 41)
        ])
        let followUpTranscript = Transcript(recording: followUp, segments: followUpSegments, language: text.transcriptLanguage)
        context.insert(followUpTranscript)

        let summary = Summary(
            meeting: meeting,
            sections: summarySections(text.roadmapSections),
            templateName: text.templateName,
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)

        // Metadata only, no file: enough for the Recordings tab's Documents
        // row (and its accessibility audit), which never opens it.
        context.insert(MeetingAttachment(
            meeting: meeting,
            fileName: "screenshot-roadmap.pdf",
            displayName: text.roadmapAttachmentName,
            fileSize: 482_000,
            pageCount: 6,
            extractedText: text.roadmapAttachmentText
        ))
    }

    // MARK: - "Design Review" — second-newest, two speakers, one recording,
    // its own folder + tag, bulleted summary.

    private static func seedDesignReviewMeeting(into context: ModelContext, text: ScreenshotSeedText) {
        let folder = Folder(name: text.designFolder, iconName: "paintpalette", colorHex: "#FF9500")
        context.insert(folder)

        let tagUI = Tag(name: text.designTag)
        context.insert(tagUI)

        let meeting = Meeting(
            title: text.designTitle,
            createdAt: Date().addingTimeInterval(-3600 * 3),
            language: text.language,
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

        let segments = timedSegments(text.designLines, [
            ("Speaker 1", 0, 26),
            ("Speaker 2", 26, 58),
            ("Speaker 1", 58, 84),
            ("Speaker 2", 84, 110)
        ])
        let transcript = Transcript(recording: recording, segments: segments, language: text.transcriptLanguage)
        context.insert(transcript)

        let summary = Summary(
            meeting: meeting,
            sections: summarySections(text.designSections),
            templateName: text.templateName,
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)
    }

    // MARK: - "Client Onboarding Call" — folder + tags, two recordings,
    // bulleted summary.

    private static func seedOnboardingMeeting(into context: ModelContext, text: ScreenshotSeedText) {
        let folder = Folder(name: text.clientsFolder, iconName: "person.2", colorHex: "#34C759")
        context.insert(folder)

        let tagOnboarding = Tag(name: text.onboardingTags[0])
        let tagPriority = Tag(name: text.onboardingTags[1])
        context.insert(tagOnboarding)
        context.insert(tagPriority)

        let meeting = Meeting(
            title: text.onboardingTitle,
            createdAt: Date().addingTimeInterval(-3600 * 6),
            language: text.language,
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

        let segments = timedSegments(text.onboardingLines, [
            ("Speaker 1", 0, 24),
            ("Speaker 1", 24, 52)
        ])
        let transcript = Transcript(recording: recording, segments: segments, language: text.transcriptLanguage)
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

        let checkInSegments = timedSegments(text.onboardingCheckIn, [
            ("Speaker 1", 0, 19),
            ("Speaker 2", 19, 44)
        ])
        let checkInTranscript = Transcript(recording: checkIn, segments: checkInSegments, language: text.transcriptLanguage)
        context.insert(checkInTranscript)

        let summary = Summary(
            meeting: meeting,
            sections: summarySections(text.onboardingSections),
            templateName: text.templateName,
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)
    }

    // MARK: - "Customer Interview" — older, single speaker, prose summary,
    // no folder/tags.

    private static func seedCustomerInterviewMeeting(into context: ModelContext, text: ScreenshotSeedText) {
        let meeting = Meeting(
            title: text.interviewTitle,
            createdAt: Date().addingTimeInterval(-3600 * 30),
            language: text.language
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

        let segments = timedSegments(text.interviewLines, [
            ("Speaker 1", 0, 30),
            ("Speaker 1", 30, 58)
        ])
        let transcript = Transcript(recording: recording, segments: segments, language: text.transcriptLanguage)
        context.insert(transcript)

        let summary = Summary(
            meeting: meeting,
            sections: [SummarySection(title: text.interviewSummaryTitle, body: text.interviewSummary)],
            templateName: text.templateName,
            provider: .openAI,
            model: "gpt-4o-mini"
        )
        context.insert(summary)
    }

    // MARK: - "Weekly Standup — Archived" — archived, no summary

    private static func seedArchivedStandup(into context: ModelContext, text: ScreenshotSeedText) {
        let meeting = Meeting(
            title: text.standupTitle,
            createdAt: Date().addingTimeInterval(-3600 * 24 * 9),
            language: text.language,
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

        let segments = timedSegments([text.standupLine], [
            ("Speaker 1", 0, 20)
        ])
        let transcript = Transcript(recording: recording, segments: segments, language: text.transcriptLanguage)
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
