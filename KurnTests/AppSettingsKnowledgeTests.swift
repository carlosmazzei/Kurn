//
//  AppSettingsKnowledgeTests.swift
//  KurnTests
//
//  The Knowledge Engine flag: off on a fresh install, independent of the
//  meeting wiki's consent, persisted, and observable.
//

import Foundation
import Observation
import Testing
@testable import Kurn

@MainActor
struct AppSettingsKnowledgeTests {
    @Test func offOnAFreshInstall() {
        #expect(!MeetingFixtures.isolatedSettings().knowledgeEnabled)
    }

    @Test func enablingTheWikiDoesNotEnableKnowledge() {
        let settings = MeetingFixtures.isolatedSettings()
        settings.wikiEnabled = true
        #expect(!settings.knowledgeEnabled)
    }

    @Test func persistsInItsOwnDefaultsSuite() throws {
        let suite = "kurn-knowledge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppSettings(defaults: defaults).knowledgeEnabled = true
        #expect(defaults.bool(forKey: AppSettings.Keys.knowledgeEnabled))
        #expect(AppSettings(defaults: defaults).knowledgeEnabled)
        #expect(!UserDefaults.standard.bool(forKey: AppSettings.Keys.knowledgeEnabled))
    }

    @Test func changesAreObservable() {
        let settings = MeetingFixtures.isolatedSettings()
        let changed = ChangeFlag()
        withObservationTracking {
            _ = settings.knowledgeEnabled
        } onChange: {
            changed.set()
        }
        settings.knowledgeEnabled = true
        #expect(changed.isSet)
    }
}

/// Records that an observation fired; `onChange` is `@Sendable`, so it cannot
/// mutate a captured local.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
