//
//  TestSupport.swift
//  KurnTests
//

import Foundation
import KurnCore
import SwiftData
@testable import Kurn

/// Actor used to serialize tests that inspect the temporary directory, avoiding
/// race conditions when other tests create or remove temp files concurrently.
///
/// A plain `actor` method isn't enough on its own: actors are reentrant, so if
/// `operation` suspends (any `await` inside it), another caller's `run` can
/// interleave on this same actor while the first is suspended. This queues
/// waiters explicitly so only one `operation` body executes at a time.
actor TempFileTestLocker {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

let tempFileTestLock = TempFileTestLocker()

extension TranscriptionCheckpoint {
    /// Test-only convenience: builds a checkpoint from the loose identity
    /// fields most fixtures care about (engine/language/compaction/provider),
    /// filling in the rest of `TranscriptionPipelineFingerprint` with
    /// deterministic placeholder source/chunk-plan identity. Two fixtures
    /// built with the same arguments compare equal under `matches`; changing
    /// any one argument is enough to make them differ, which is what the H4
    /// fingerprint tests exercise.
    static func fixture(
        engine: TranscriptionEngine,
        language: MeetingLanguage,
        compacted: Bool,
        totalChunks: Int,
        completedChunks: Int,
        detectedLanguage: String,
        spans: [Span],
        providerID: String? = nil,
        sourceFileSize: Int64 = 1_000,
        sourceDuration: TimeInterval = 60,
        sourceDigest: String? = "fixture-source",
        preprocessing: PreprocessingEngine = .standardDSP,
        vad: VADEngine = .energyThreshold,
        compactionDigest: String? = nil,
        chunkPlanDigest: String = "fixture-plan"
    ) -> TranscriptionCheckpoint {
        TranscriptionCheckpoint(
            fingerprint: TranscriptionPipelineFingerprint(
                sourceFileSize: sourceFileSize,
                sourceDuration: sourceDuration,
                sourceDigest: sourceDigest,
                preprocessing: preprocessing,
                vad: vad,
                language: language,
                engine: engine,
                providerID: providerID,
                compacted: compacted,
                compactionDigest: compactionDigest
            ),
            chunkPlanDigest: chunkPlanDigest,
            totalChunks: totalChunks,
            completedChunks: completedChunks,
            detectedLanguage: detectedLanguage,
            spans: spans
        )
    }
}

/// Shared helper for tests that need real SwiftData relationship behavior
/// (inverse relationships are only guaranteed once objects are inserted into
/// a context) without touching the on-disk store.
@MainActor
enum TestModelContainer {
    static func make() -> ModelContainer {
        // Reads the same centralized model list production uses
        // (`KurnModelGraph`) so this container cannot silently diverge from
        // what `KurnApp` actually persists.
        let schema = Schema(KurnModelGraph.currentModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }
}
