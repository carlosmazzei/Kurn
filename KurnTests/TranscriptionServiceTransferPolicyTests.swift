//
//  TranscriptionServiceTransferPolicyTests.swift
//  KurnTests
//
//  Cloud transcription uploads the whole recording, so it follows the
//  large-transfer policy. These pin that a path the policy refuses is found
//  before any local stage runs — the failure used to surface only when the
//  first chunk was sent, minutes into a run the user watched as
//  "transcribing", and read as "not connected to the internet".
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@Suite("TranscriptionService large-transfer preflight")
struct TranscriptionServiceTransferPolicyTests {

    private static let regions = [
        SpeechRegion(start: 0.2, end: 1.2),
        SpeechRegion(start: 1.8, end: 2.8)
    ]

    private static let blockedPath = FixedNetworkPath(
        snapshot: NetworkPathSnapshot(isExpensive: true, isConstrained: true)
    )

    private static func config(
        transcription: TranscriptionEngine,
        policy: LargeTransferPolicy = .wifiOnly
    ) -> PipelineConfiguration {
        var config = PipelineConfiguration()
        config.preprocessing = .none
        config.transcription = transcription
        config.cloudTranscriptionConsented = transcription == .whisperAPI
        config.diarization = .heuristic
        config.largeTransferPolicy = policy
        return config
    }

    @Test func cloudUploadOnABlockedPathFailsBeforeAnyStageRuns() async throws {
        let url = try AudioFixtures.wav(segments: [(220, 3.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let phases = PhaseCounter()

        do {
            _ = try await TranscriptionService(engines: harness.catalog, network: Self.blockedPath).transcribe(
                fileURL: url,
                fileName: "fixture.wav",
                language: .english,
                config: Self.config(transcription: .whisperAPI),
                onPhase: { _ in phases.increment() }
            )
            Issue.record("expected the transfer policy to refuse the upload")
        } catch let error as AppError {
            #expect(error.logCode == AppError.networkPolicyRestricted.logCode)
        }
        #expect(harness.transcriber.requests.isEmpty)
        #expect(phases.count == 0)
    }

    @Test func cloudUploadProceedsOnAPathTheUserAllowed() async throws {
        let url = try AudioFixtures.wav(segments: [(220, 3.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)
        let permissive = LargeTransferPolicy(allowsExpensiveAccess: true, allowsConstrainedAccess: true)

        _ = try await TranscriptionService(engines: harness.catalog, network: Self.blockedPath).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: Self.config(transcription: .whisperAPI, policy: permissive)
        )
        #expect(!harness.transcriber.requests.isEmpty)
    }

    @Test func onDeviceEngineIgnoresTheUploadPolicy() async throws {
        let url = try AudioFixtures.wav(segments: [(220, 3.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = FakeEngines(regions: Self.regions)

        let output = try await TranscriptionService(engines: harness.catalog, network: Self.blockedPath).transcribe(
            fileURL: url,
            fileName: "fixture.wav",
            language: .english,
            config: Self.config(transcription: .appleSpeech)
        )
        #expect(!output.segments.isEmpty)
    }
}

private struct FixedNetworkPath: NetworkPathSnapshotProviding {
    let snapshot: NetworkPathSnapshot
}

private final class PhaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
