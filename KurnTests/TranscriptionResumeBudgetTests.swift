//
//  TranscriptionResumeBudgetTests.swift
//  KurnTests
//
//  H4 PR 9: automatic (unattended) resume attempts are bounded so a systemic
//  failure can't retry forever — or, for a cloud engine, keep re-paying —
//  every time the app launches or foregrounds. A manual retry always resets
//  the budget, since a deliberate user action is exactly what the bound is
//  waiting for.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TranscriptionResumeBudgetTests {

    @Test func pureBoundAllowsAttemptsUnderTheMaxAndRefusesAtIt() {
        for attempts in 0..<TranscriptionViewModel.maxAutomaticResumeAttemptsWithoutProgress {
            #expect(TranscriptionViewModel.canAttemptAutomaticResume(afterPriorAttempts: attempts))
        }
        #expect(!TranscriptionViewModel.canAttemptAutomaticResume(
            afterPriorAttempts: TranscriptionViewModel.maxAutomaticResumeAttemptsWithoutProgress
        ))
        #expect(!TranscriptionViewModel.canAttemptAutomaticResume(afterPriorAttempts: 1_000))
    }

    @Test func resetAutomaticResumeBudgetZeroesTheCounter() {
        let recording = Recording(fileName: "a.m4a", duration: 10)
        recording.automaticResumeAttempts = 7
        let vm = TranscriptionViewModel(modelContext: TestModelContainer.make().mainContext)

        vm.resetAutomaticResumeBudget(for: recording)

        #expect(recording.automaticResumeAttempts == 0)
    }

    @Test func exhaustedBudgetMarksFailedWithoutRestartingAndKeepsTheCheckpoint() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let vm = TranscriptionViewModel(modelContext: context)
        let meeting = Meeting(title: "M")
        context.insert(meeting)
        let recording = Recording(
            meeting: meeting,
            fileName: "a.m4a",
            duration: 10,
            transcriptionStatus: .pending
        )
        recording.automaticResumeAttempts = TranscriptionViewModel.maxAutomaticResumeAttemptsWithoutProgress
        recording.transcriptionCheckpoint = .fixture(
            engine: .whisperCpp, language: .english, compacted: false,
            totalChunks: 4, completedChunks: 2, detectedLanguage: "en", spans: []
        )
        context.insert(recording)
        try context.save()

        vm.resumePendingTranscriptions(settings: AppSettings())

        // Exhausted before `startTranscription` is ever reached, so this
        // assertion is synchronous and deterministic — no background
        // pipeline task is spawned for this recording.
        #expect(recording.transcriptionStatus == .failed)
        #expect(recording.automaticResumeAttempts == TranscriptionViewModel.maxAutomaticResumeAttemptsWithoutProgress)
        #expect(recording.transcriptionCheckpoint?.completedChunks == 2)
    }

    @Test func underBudgetIncrementsTheCounterBeforeAttemptingToResume() throws {
        let container = TestModelContainer.make()
        let context = container.mainContext
        let vm = TranscriptionViewModel(modelContext: context)
        let meeting = Meeting(title: "M")
        context.insert(meeting)
        // Not `.ready`, so `startTranscription` is a synchronous no-op below
        // (it bails before spawning any task) — isolating this test to the
        // budget bookkeeping in `resumePendingTranscriptions` itself, without
        // racing a real transcription pipeline against a nonexistent file.
        let recording = Recording(
            meeting: meeting,
            fileName: "a.m4a",
            duration: 10,
            transcriptionStatus: .pending,
            captureState: .recoveryNeeded
        )
        recording.automaticResumeAttempts = 1
        context.insert(recording)
        try context.save()

        vm.resumePendingTranscriptions(settings: AppSettings())

        #expect(recording.automaticResumeAttempts == 2)
        #expect(recording.transcriptionStatus == .pending)
    }
}
