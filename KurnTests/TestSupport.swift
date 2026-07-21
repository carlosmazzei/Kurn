//
//  TestSupport.swift
//  KurnTests
//

import Foundation
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

/// Shared helper for tests that need real SwiftData relationship behavior
/// (inverse relationships are only guaranteed once objects are inserted into
/// a context) without touching the on-disk store.
@MainActor
enum TestModelContainer {
    static func make() -> ModelContainer {
        let schema = Schema([
            Meeting.self, Recording.self, Speaker.self, Summary.self, Transcript.self, Folder.self,
            Tag.self, SmartFolder.self, SemanticChunk.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }
}
