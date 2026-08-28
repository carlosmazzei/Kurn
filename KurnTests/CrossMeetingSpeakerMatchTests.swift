//
//  CrossMeetingSpeakerMatchTests.swift
//  KurnTests
//
//  D6: a voiceprint match found in a *different* meeting must be offered, not
//  silently applied — a misidentified voice would otherwise attach the wrong
//  name to the wrong person with no error anywhere.
//
//  Runs against a real in-memory `ModelContainer`, like `SpeakerSyncTests`,
//  because what's under test is `syncSpeakers`'s SwiftData-facing behavior
//  (which rows exist, whether a name gets set) rather than the pure matching
//  arithmetic — that's covered separately in `SpeakerIdentityTests`.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct CrossMeetingSpeakerMatchTests {

    // MARK: - Fixtures

    private static func unitVector(axis: Int, noise: Float = 0, dimension: Int = 8) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        vector[axis % dimension] = 1
        vector[(axis + 1) % dimension] = noise
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    private struct Fixture {
        var context: ModelContext
        var viewModel: TranscriptionViewModel
        var meetingA: Meeting
        var recordingA: Recording
        var meetingB: Meeting
        var recordingB: Recording
    }

    private static func make() -> Fixture {
        let container = TestModelContainer.make()
        let context = ModelContext(container)

        let meetingA = Meeting(title: "Weekly Sync")
        context.insert(meetingA)
        let recordingA = Recording(meeting: meetingA, fileName: "a.m4a", duration: 60)
        context.insert(recordingA)

        let meetingB = Meeting(title: "Planning")
        context.insert(meetingB)
        let recordingB = Recording(meeting: meetingB, fileName: "b.m4a", duration: 60)
        context.insert(recordingB)

        return Fixture(
            context: context,
            viewModel: TranscriptionViewModel(modelContext: context),
            meetingA: meetingA,
            recordingA: recordingA,
            meetingB: meetingB,
            recordingB: recordingB
        )
    }

    private static func setTranscript(_ labels: [String], on fixture: Fixture, recording: Recording) {
        if let existing = recording.transcript {
            recording.transcript = nil
            fixture.context.delete(existing)
        }
        let segments = labels.enumerated().map { index, label in
            TranscriptSegment(
                speakerLabel: label,
                startTime: TimeInterval(index * 10),
                endTime: TimeInterval(index * 10 + 10),
                text: "linha \(index)",
                confidence: nil
            )
        }
        let transcript = Transcript(recording: recording, segments: segments, language: "en")
        fixture.context.insert(transcript)
    }

    /// Meeting A gets one named, voiceprinted speaker — the only kind of row
    /// D6 should ever offer as a cross-meeting candidate.
    private static func seedNamedSpeaker(
        _ name: String,
        voiceprint: [Float],
        in fixture: Fixture,
        recording: Recording,
        meeting: Meeting
    ) throws {
        setTranscript(["Speaker 1"], on: fixture, recording: recording)
        recording.speakerVoiceprints = ["Speaker 1": voiceprint]
        fixture.viewModel.syncSpeakers(for: meeting)
        try fixture.context.save()
        let row = try #require(meeting.speakers.first)
        row.name = name
        try fixture.context.save()
    }

    // MARK: - Tests

    @Test func aNamedSpeakerInAnotherMeetingIsOfferedNotApplied() throws {
        let fixture = Self.make()
        let ana = Self.unitVector(axis: 0)
        try Self.seedNamedSpeaker("Ana", voiceprint: ana, in: fixture, recording: fixture.recordingA, meeting: fixture.meetingA)

        // A brand-new speaker in a different meeting, same voice.
        Self.setTranscript(["Speaker 1"], on: fixture, recording: fixture.recordingB)
        fixture.recordingB.speakerVoiceprints = ["Speaker 1": Self.unitVector(axis: 0, noise: 0.05)]
        fixture.viewModel.syncSpeakers(for: fixture.meetingB)
        try fixture.context.save()

        let match = try #require(fixture.viewModel.pendingCrossMeetingMatches.first)
        #expect(match.matchedSpeaker.name == "Ana")
        #expect(match.matchedMeetingTitle == "Weekly Sync")
        // Never applied silently: the new row is still unnamed.
        #expect(match.newSpeaker.name.isEmpty)
        #expect(fixture.meetingB.speakers.allSatisfy { $0.name.isEmpty })
    }

    @Test func applyingTheMatchSetsTheNameAndClearsTheQueue() throws {
        let fixture = Self.make()
        let ana = Self.unitVector(axis: 0)
        try Self.seedNamedSpeaker("Ana", voiceprint: ana, in: fixture, recording: fixture.recordingA, meeting: fixture.meetingA)

        Self.setTranscript(["Speaker 1"], on: fixture, recording: fixture.recordingB)
        fixture.recordingB.speakerVoiceprints = ["Speaker 1": Self.unitVector(axis: 0, noise: 0.05)]
        fixture.viewModel.syncSpeakers(for: fixture.meetingB)
        try fixture.context.save()

        let match = try #require(fixture.viewModel.pendingCrossMeetingMatches.first)
        fixture.viewModel.applyCrossMeetingMatch(match)

        #expect(fixture.viewModel.pendingCrossMeetingMatches.isEmpty)
        let newRow = try #require(fixture.meetingB.speakers.first)
        #expect(newRow.name == "Ana")
    }

    @Test func dismissingTheMatchLeavesTheNewSpeakerUnnamed() throws {
        let fixture = Self.make()
        let ana = Self.unitVector(axis: 0)
        try Self.seedNamedSpeaker("Ana", voiceprint: ana, in: fixture, recording: fixture.recordingA, meeting: fixture.meetingA)

        Self.setTranscript(["Speaker 1"], on: fixture, recording: fixture.recordingB)
        fixture.recordingB.speakerVoiceprints = ["Speaker 1": Self.unitVector(axis: 0, noise: 0.05)]
        fixture.viewModel.syncSpeakers(for: fixture.meetingB)
        try fixture.context.save()

        let match = try #require(fixture.viewModel.pendingCrossMeetingMatches.first)
        fixture.viewModel.dismissCrossMeetingMatch(match)

        #expect(fixture.viewModel.pendingCrossMeetingMatches.isEmpty)
        let newRow = try #require(fixture.meetingB.speakers.first)
        #expect(newRow.name.isEmpty)
    }

    @Test func aVoiceWithNoCloseMatchProducesNoSuggestion() throws {
        let fixture = Self.make()
        let ana = Self.unitVector(axis: 0)
        try Self.seedNamedSpeaker("Ana", voiceprint: ana, in: fixture, recording: fixture.recordingA, meeting: fixture.meetingA)

        // A different voice entirely.
        Self.setTranscript(["Speaker 1"], on: fixture, recording: fixture.recordingB)
        fixture.recordingB.speakerVoiceprints = ["Speaker 1": Self.unitVector(axis: 4)]
        fixture.viewModel.syncSpeakers(for: fixture.meetingB)
        try fixture.context.save()

        #expect(fixture.viewModel.pendingCrossMeetingMatches.isEmpty)
    }

    /// Only a row the user has named is a usable candidate — offering "this
    /// might be Speaker 3 from another meeting" would suggest a label, not an
    /// identity, which is exactly the thing this whole feature exists to stop
    /// doing.
    @Test func anUnnamedSpeakerElsewhereIsNeverOfferedAsAMatch() throws {
        let fixture = Self.make()
        Self.setTranscript(["Speaker 1"], on: fixture, recording: fixture.recordingA)
        fixture.recordingA.speakerVoiceprints = ["Speaker 1": Self.unitVector(axis: 0)]
        fixture.viewModel.syncSpeakers(for: fixture.meetingA)
        try fixture.context.save()
        #expect(fixture.meetingA.speakers.first?.name.isEmpty == true)

        Self.setTranscript(["Speaker 1"], on: fixture, recording: fixture.recordingB)
        fixture.recordingB.speakerVoiceprints = ["Speaker 1": Self.unitVector(axis: 0, noise: 0.05)]
        fixture.viewModel.syncSpeakers(for: fixture.meetingB)
        try fixture.context.save()

        #expect(fixture.viewModel.pendingCrossMeetingMatches.isEmpty)
    }
}
