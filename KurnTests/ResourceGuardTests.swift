//
//  ResourceGuardTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ResourceGuardTests {

    @Test func hugeStorageRequirementThrowsResourceUnavailable() {
        guard ResourceGuard.availableStorageBytes() != nil else { return }

        do {
            try ResourceGuard.requireFreeStorage(atLeast: Int64.max)
            Issue.record("Expected resourceUnavailable for impossible storage requirement")
        } catch let error as AppError {
            guard case .resourceUnavailable = error else {
                Issue.record("Expected resourceUnavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppError, got \(error)")
        }
    }

    @Test func cocoaOutOfSpaceMapsToResourceUnavailable() throws {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteOutOfSpace.rawValue
        )
        let appError = try #require(ResourceGuard.appErrorIfResourceFailure(error))
        guard case .resourceUnavailable = appError else {
            Issue.record("Expected resourceUnavailable, got \(appError)")
            return
        }
    }

    @Test func recordingStorageKeepsUnknownCapacityExplicit() {
        let monitor = RecordingStorageMonitor(bitRate: 64_000)
        let state = monitor.assess(
            capacity: .unknown,
            fileSize: nil,
            writtenOutputFrames: 0
        )

        #expect(state == .unknown)
        #expect(state.userMessage != nil)
        #expect(monitor.startError(for: state) == nil)
    }

    @Test func recordingStoragePreflightRequiresThirtyMinutesOfRunway() {
        let monitor = RecordingStorageMonitor(bitRate: 64_000)
        let insufficient = monitor.assess(
            capacity: .available(monitor.requiredStartBytes - 1),
            fileSize: nil,
            writtenOutputFrames: 0
        )
        let sufficient = monitor.assess(
            capacity: .available(monitor.requiredStartBytes),
            fileSize: nil,
            writtenOutputFrames: 0
        )

        #expect(monitor.startError(for: insufficient) != nil)
        #expect(monitor.startError(for: sufficient) == nil)
    }

    @Test func recordingStorageUsesMeasuredFileRateAfterTenSeconds() throws {
        #expect(RecordingStorageMonitor.outputSampleRate == AudioRecorderService.storageSampleRate)
        let monitor = RecordingStorageMonitor(bitRate: 64_000)
        let frames = Int64(AudioRecorderService.storageSampleRate * 10)
        let early = monitor.assess(
            capacity: .available(100_000_000),
            fileSize: 200_000,
            writtenOutputFrames: frames - 1
        )
        let measured = monitor.assess(
            capacity: .available(100_000_000),
            fileSize: 200_000,
            writtenOutputFrames: frames
        )

        let earlyEstimate = try #require(early.estimate)
        let measuredEstimate = try #require(measured.estimate)
        #expect(earlyEstimate.rateBasis == .configured)
        #expect(measuredEstimate.rateBasis == .measured)
        #expect(abs(measuredEstimate.bytesPerSecond - 20_000) < 0.001)
        #expect(measuredEstimate.runway < earlyEstimate.runway)
    }

    @Test func recordingStorageSurfacesCriticalRunway() throws {
        let monitor = RecordingStorageMonitor(bitRate: 64_000)
        let capacity = RecordingStorageMonitor.safetyReserveBytes
            + Int64(monitor.configuredBytesPerSecond * 60)
        let state = monitor.assess(
            capacity: .available(capacity),
            fileSize: nil,
            writtenOutputFrames: 0
        )

        guard case .low = state else {
            Issue.record("Expected a low-storage state, got \(state)")
            return
        }
        #expect(state.userMessage != nil)
    }

    @Test @MainActor func recorderKeepsUnknownPreflightVisible() throws {
        let recorder = AudioRecorderService(
            storageProbe: StubRecordingStorageProbe(capacity: .unknown, fileSize: nil)
        )

        try recorder.prepareStorageForRecording(
            bitRate: 64_000,
            directory: FileManager.default.temporaryDirectory
        )

        #expect(recorder.storageState == .unknown)
    }

    @Test @MainActor func recorderRejectsInsufficientPreflightCapacity() {
        let monitor = RecordingStorageMonitor(bitRate: 64_000)
        let recorder = AudioRecorderService(storageProbe: StubRecordingStorageProbe(
            capacity: .available(monitor.requiredStartBytes - 1),
            fileSize: nil
        ))

        #expect(throws: AppError.self) {
            try recorder.prepareStorageForRecording(
                bitRate: 64_000,
                directory: FileManager.default.temporaryDirectory
            )
        }
    }

    @Test @MainActor func recorderRefreshesRunwayFromMeasuredFileSize() throws {
        let recorder = AudioRecorderService(storageProbe: StubRecordingStorageProbe(
            capacity: .available(100_000_000),
            fileSize: 200_000
        ))
        try recorder.prepareStorageForRecording(
            bitRate: 64_000,
            directory: FileManager.default.temporaryDirectory
        )
        recorder.refreshStorage(
            snapshot: AudioSinkSnapshot(
                writtenOutputFrames: Int64(AudioRecorderService.storageSampleRate * 10)
            ),
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("recording.m4a")
        )

        let estimate = try #require(recorder.storageState.estimate)
        #expect(estimate.rateBasis == .measured)
        #expect(abs(estimate.bytesPerSecond - 20_000) < 0.001)
    }

    @Test func pipelineBoundaryRejectsAnAlreadyCancelledTask() async {
        let stopped = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await ResourceGuard.requireHealthyResources(minimumFreeStorage: 0)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(stopped)
    }
}

private struct StubRecordingStorageProbe: RecordingStorageProbing {
    let capacityValue: RecordingStorageCapacity
    let fileSizeValue: Int64?

    init(capacity: RecordingStorageCapacity, fileSize: Int64?) {
        self.capacityValue = capacity
        self.fileSizeValue = fileSize
    }

    func capacity(at url: URL) -> RecordingStorageCapacity {
        capacityValue
    }

    func fileSize(at url: URL) -> Int64? {
        fileSizeValue
    }
}
