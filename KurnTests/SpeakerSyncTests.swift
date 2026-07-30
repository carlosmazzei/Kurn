//
//  SpeakerSyncTests.swift
//  KurnTests
//
//  The reconciliation that used to lose a name the user typed.
//
//  These run against a real in-memory `ModelContainer` rather than a stub,
//  because the failure is in the SwiftData bookkeeping — which rows are deleted,
//  which are relabelled, what `meeting.speakers` holds afterwards — and a fake
//  would only prove that a fake behaves.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SpeakerSyncTests {

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
        var meeting: Meeting
        var recording: Recording
    }

    private static func make() -> Fixture {
        let container = TestModelContainer.make()
        let context = ModelContext(container)
        let meeting = Meeting(title: "Planning")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "a.m4a", duration: 60)
        context.insert(recording)
        return Fixture(
            context: context,
            viewModel: TranscriptionViewModel(modelContext: context),
            meeting: meeting,
            recording: recording
        )
    }

    /// Sync and save. `syncSpeakers` only stages the deletes — SwiftData does
    /// not apply them to `meeting.speakers` until the context is saved, which is
    /// what `saveTranscript` does around it in production.
    private static func sync(
        _ fixture: Fixture,
        voiceprints: [String: [Float]] = [:]
    ) throws {
        fixture.viewModel.syncSpeakers(for: fixture.meeting, voiceprints: voiceprints)
        try fixture.context.save()
    }

    private static func setTranscript(_ labels: [String], on fixture: Fixture) {
        if let existing = fixture.recording.transcript {
            fixture.recording.transcript = nil
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
        let transcript = Transcript(recording: fixture.recording, segments: segments, language: "pt-BR")
        fixture.context.insert(transcript)
    }

    // MARK: - Tests

    /// The regression this whole change exists for: the diarizer renumbers, and
    /// the name has to follow the voice rather than the number.
    @Test func aRenamedSpeakerFollowsItsVoiceAcrossRenumbering() throws {
        let fixture = Self.make()
        let ana = Self.unitVector(axis: 0)
        let bruno = Self.unitVector(axis: 4)

        Self.setTranscript(["Speaker 1", "Speaker 2"], on: fixture)
        try Self.sync(fixture, voiceprints: ["Speaker 1": ana, "Speaker 2": bruno])
        let anaRow = try #require(fixture.meeting.speakers.first { $0.label == "Speaker 1" })
        anaRow.name = "Ana"
        let anaID = anaRow.id

        // Re-transcribe: the same two voices come back with the labels swapped.
        Self.setTranscript(["Speaker 1", "Speaker 2"], on: fixture)
        try Self.sync(fixture, voiceprints: [
            "Speaker 1": Self.unitVector(axis: 4, noise: 0.05),
            "Speaker 2": Self.unitVector(axis: 0, noise: 0.05)
        ])

        let named = fixture.meeting.speakers.filter { !$0.name.isEmpty }
        #expect(named.count == 1)
        #expect(named.first?.name == "Ana")
        #expect(named.first?.id == anaID)
        // Ana is now Speaker 2 — the label moved with her, and did not take
        // someone else's name with it.
        #expect(named.first?.label == "Speaker 2")
    }

    /// The original data loss: a rename, then a run that finds fewer speakers.
    /// Without a voiceprint there is no way to know who is who, so the row is
    /// kept rather than guessed at — and never deleted.
    @Test func aTypedNameIsNeverDeleted() throws {
        let fixture = Self.make()
        Self.setTranscript(["Speaker 1", "Speaker 2"], on: fixture)
        try Self.sync(fixture)

        let row = try #require(fixture.meeting.speakers.first { $0.label == "Speaker 2" })
        row.name = "Ana"

        // The diarizer now hears one voice.
        Self.setTranscript(["Speaker 1"], on: fixture)
        try Self.sync(fixture)

        #expect(fixture.meeting.speakers.contains { $0.name == "Ana" })
    }

    /// An unnamed row carries nothing but a label that no longer means anything,
    /// so it still goes — otherwise every re-run would accumulate debris.
    @Test func unnamedSpeakersAreStillCleanedUp() throws {
        let fixture = Self.make()
        Self.setTranscript(["Speaker 1", "Speaker 2", "Speaker 3"], on: fixture)
        try Self.sync(fixture)
        #expect(fixture.meeting.speakers.count == 3)

        Self.setTranscript(["Speaker 1"], on: fixture)
        try Self.sync(fixture)
        #expect(fixture.meeting.speakers.count == 1)
        #expect(fixture.meeting.speakers.first?.label == "Speaker 1")
    }

    /// A voice that genuinely is not in the new transcript must not be matched
    /// onto whoever is — that would be the same bug wearing the other hat.
    @Test func aDifferentVoiceIsNotClaimed() throws {
        let fixture = Self.make()
        Self.setTranscript(["Speaker 1"], on: fixture)
        try Self.sync(fixture, voiceprints: ["Speaker 1": Self.unitVector(axis: 0)])
        let row = try #require(fixture.meeting.speakers.first)
        row.name = "Ana"

        // A different person entirely, under a label Ana never had.
        Self.setTranscript(["Speaker 2"], on: fixture)
        try Self.sync(fixture, voiceprints: ["Speaker 2": Self.unitVector(axis: 4)])

        let ana = try #require(fixture.meeting.speakers.first { $0.name == "Ana" })
        #expect(ana.label != "Speaker 2")
        #expect(fixture.meeting.speakers.contains { $0.label == "Speaker 2" && $0.name.isEmpty })
    }

    @Test func voiceprintsArePersistedAndRefreshed() throws {
        let fixture = Self.make()
        Self.setTranscript(["Speaker 1"], on: fixture)
        try Self.sync(fixture, voiceprints: ["Speaker 1": Self.unitVector(axis: 0)])
        let row = try #require(fixture.meeting.speakers.first)
        #expect(row.voiceprint != nil)

        let refreshed = Self.unitVector(axis: 0, noise: 0.2)
        try Self.sync(fixture, voiceprints: ["Speaker 1": refreshed])
        let stored = try #require(row.voiceprint)
        #expect(zip(stored, refreshed).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    /// The heuristic engine reports no embeddings at all, and that path must
    /// keep working exactly as before — minus the deletion of named rows.
    @Test func worksWithNoVoiceprintsAtAll() throws {
        let fixture = Self.make()
        Self.setTranscript(["Speaker 1", "Speaker 2"], on: fixture)
        try Self.sync(fixture)

        #expect(fixture.meeting.speakers.count == 2)
        #expect(fixture.meeting.speakers.allSatisfy { $0.voiceprint == nil })
    }
}
