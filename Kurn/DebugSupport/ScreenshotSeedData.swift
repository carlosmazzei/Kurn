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

#if DEBUG
import AVFoundation
import Foundation
import SwiftData

@MainActor
enum ScreenshotSeedData {
    static func seed(into context: ModelContext) {
        seedRoadmapMeeting(into: context)
        seedOnboardingMeeting(into: context)
        seedArchivedStandup(into: context)
        try? context.save()
    }

    // MARK: - "Product Roadmap Sync" — multi-speaker, favorited, full summary

    private static func seedRoadmapMeeting(into context: ModelContext) {
        let meeting = Meeting(
            title: "Product Roadmap Sync",
            createdAt: Date().addingTimeInterval(-3600 * 26),
            language: .english,
            isFavorite: true
        )
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
                        "Sam — finalize the export flow design.",
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

    // MARK: - "Client Onboarding Call" — folder + tags, single speaker

    private static func seedOnboardingMeeting(into context: ModelContext) {
        let folder = Folder(name: "Clients")
        context.insert(folder)

        let tagOnboarding = Tag(name: "Onboarding")
        let tagPriority = Tag(name: "Priority")
        context.insert(tagOnboarding)
        context.insert(tagPriority)

        let meeting = Meeting(
            title: "Client Onboarding Call",
            createdAt: Date().addingTimeInterval(-3600 * 4),
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

        let summary = Summary(
            meeting: meeting,
            sections: [
                SummarySection(
                    title: "Summary",
                    body: "Walked the client through on-device recording, transcription, and summaries."
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
        let url = AudioFileStore.recordingsDirectoryURL.appendingPathComponent(fileName)
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
