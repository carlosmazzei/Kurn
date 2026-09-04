//
//  TranscriptionSchedulerTests.swift
//  KurnTests
//
//  The two decisions behind `TranscriptionScheduler.scheduleIfWorkRemains`,
//  tested without `BGTaskScheduler` (which rejects submissions from a test
//  host): which pipelines may run in a background window at all, and which
//  recordings count as interrupted work worth a window.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct TranscriptionSchedulerTests {

    private func insertRecording(
        in context: ModelContext,
        status: TranscriptionStatus,
        captureState: RecordingCaptureState = .ready
    ) {
        let meeting = Meeting(title: "M")
        context.insert(meeting)
        let recording = Recording(meeting: meeting, fileName: "\(UUID()).m4a", duration: 30)
        recording.transcriptionStatus = status
        recording.captureState = captureState
        context.insert(recording)
    }

    // MARK: - pipelineUsesCoreML

    @Test func appleSpeechWithEnergyVADAndHeuristicDiarizerCanRunInBackground() {
        var config = PipelineConfiguration()
        config.transcription = .appleSpeech
        config.vad = .energyThreshold
        config.diarization = .heuristic
        config.languageDetection = .byTranscriber
        #expect(!TranscriptionScheduler.pipelineUsesCoreML(config))
    }

    @Test func whisperAPIWithoutOnDeviceStagesCanRunInBackground() {
        var config = PipelineConfiguration()
        config.transcription = .whisperAPI
        config.vad = .energyThreshold
        config.diarization = .heuristic
        config.languageDetection = .byTranscriber
        #expect(!TranscriptionScheduler.pipelineUsesCoreML(config))
    }

    @Test(arguments: [TranscriptionEngine.fluidAudioParakeet, .whisperCpp])
    func onDeviceGPUTranscribersAreNotSchedulable(engine: TranscriptionEngine) {
        var config = PipelineConfiguration()
        config.transcription = engine
        config.vad = .energyThreshold
        config.diarization = .heuristic
        config.languageDetection = .byTranscriber
        #expect(TranscriptionScheduler.pipelineUsesCoreML(config))
    }

    @Test func anySingleFluidAudioStageMakesThePipelineUnschedulable() {
        var base = PipelineConfiguration()
        base.transcription = .appleSpeech
        base.vad = .energyThreshold
        base.diarization = .heuristic
        base.languageDetection = .byTranscriber

        var vad = base
        vad.vad = .fluidAudio
        #expect(TranscriptionScheduler.pipelineUsesCoreML(vad))

        var diarization = base
        diarization.diarization = .fluidAudio
        #expect(TranscriptionScheduler.pipelineUsesCoreML(diarization))

        var lid = base
        lid.languageDetection = .fluidAudioLID
        #expect(TranscriptionScheduler.pipelineUsesCoreML(lid))
    }

    // MARK: - interruptedRecordings

    @Test func interruptedRecordingsIncludePendingAndInProgressOnly() {
        let context = TestModelContainer.make().mainContext
        insertRecording(in: context, status: .pending)
        insertRecording(in: context, status: .inProgress)
        insertRecording(in: context, status: .done)
        insertRecording(in: context, status: .failed)
        insertRecording(in: context, status: .none)

        let interrupted = TranscriptionScheduler.interruptedRecordings(context: context)
        #expect(interrupted.count == 2)
        #expect(Set(interrupted.map(\.transcriptionStatus)) == [.pending, .inProgress])
    }

    @Test func recordingsStillBeingCapturedOrAwaitingRecoveryAreNotInterruptedWork() {
        let context = TestModelContainer.make().mainContext
        insertRecording(in: context, status: .pending, captureState: .recording)
        insertRecording(in: context, status: .pending, captureState: .finalizing)
        insertRecording(in: context, status: .pending, captureState: .recoveryNeeded)

        #expect(TranscriptionScheduler.interruptedRecordings(context: context).isEmpty)
    }

    @Test func emptyStoreHasNoInterruptedWork() {
        let context = TestModelContainer.make().mainContext
        #expect(TranscriptionScheduler.interruptedRecordings(context: context).isEmpty)
    }
}
