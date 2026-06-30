//
//  TestSupport.swift
//  KurnTests
//

import Foundation
import SwiftData
@testable import Kurn

/// Shared helper for tests that need real SwiftData relationship behavior
/// (inverse relationships are only guaranteed once objects are inserted into
/// a context) without touching the on-disk store.
@MainActor
enum TestModelContainer {
    static func make() -> ModelContainer {
        // Tests use the current (V2) schema so new entities like `Folder` and
        // V2-only fields are available; migration-specific tests build their
        // own V1 containers.
        let schema = Schema(KurnSchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create in-memory ModelContainer: \(error)")
        }
    }
}
