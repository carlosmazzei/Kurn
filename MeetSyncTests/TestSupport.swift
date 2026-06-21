//
//  TestSupport.swift
//  MeetSyncTests
//

import Foundation
import SwiftData
@testable import MeetSync

/// Shared helper for tests that need real SwiftData relationship behavior
/// (inverse relationships are only guaranteed once objects are inserted into
/// a context) without touching the on-disk store.
@MainActor
enum TestModelContainer {
    static func make() -> ModelContainer {
        let schema = Schema([Meeting.self, Recording.self, Speaker.self, Summary.self, Transcript.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }
}
