//
//  TestSupport.swift
//  KurnTests
//

import Foundation
import SwiftData
@testable import Kurn

/// Actor used to serialize tests that inspect the temporary directory, avoiding
/// race conditions when other tests create or remove temp files concurrently.
actor TempFileTestLocker {
    func run<T: Sendable>(operation: @Sendable () async throws -> T) async rethrows -> T {
        try await operation()
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
            Tag.self, SmartFolder.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }
}
