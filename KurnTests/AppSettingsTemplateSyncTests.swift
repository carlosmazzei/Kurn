//
//  AppSettingsTemplateSyncTests.swift
//  KurnTests
//
//  AppSettings' iCloud key-value sync for custom summary templates
//  (CloudSettingsSync/TemplateSyncMerger), exercised through an in-memory
//  CloudKeyValueStore fake — CI has no signed-in iCloud account.
//

import Foundation
import Testing
@testable import Kurn

/// In-memory stand-in for `CloudSettingsSync`, so sync logic is testable
/// without a real `NSUbiquitousKeyValueStore`.
final class InMemoryCloudKeyValueStore: CloudKeyValueStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    var didChangeExternally: (([String]) -> Void)?

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func setData(_ data: Data?, forKey key: String) {
        storage[key] = data
    }

    /// Simulates another device writing to the store and iCloud notifying
    /// this process of the change.
    func simulateExternalWrite(_ templates: [SummaryTemplate], forKey key: String) {
        storage[key] = try? JSONEncoder().encode(templates)
        didChangeExternally?([key])
    }

    func decodedTemplates(forKey key: String) -> [SummaryTemplate] {
        guard let data = storage[key] else { return [] }
        return (try? JSONDecoder().decode([SummaryTemplate].self, from: data)) ?? []
    }
}

@MainActor
struct AppSettingsTemplateSyncTests {
    private static let cloudKey = "cloud.summaryTemplates"

    /// Mirrors `AppSettingsTests.withScopedDefaults`, but builds `AppSettings`
    /// against a fresh in-memory cloud store instead of the real one.
    private func withScopedDefaults(_ body: (AppSettings, InMemoryCloudKeyValueStore) -> Void) {
        let defaults = UserDefaults.standard
        let snapshot = AppSettingsTests.keys.reduce(into: [String: Any]()) { acc, key in
            if let value = defaults.object(forKey: key) { acc[key] = value }
        }
        defer {
            for key in AppSettingsTests.keys {
                if let value = snapshot[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in AppSettingsTests.keys { defaults.removeObject(forKey: key) }
        let store = InMemoryCloudKeyValueStore()
        body(AppSettings(cloudStore: store), store)
    }

    private func customTemplate(name: String) -> SummaryTemplate {
        .custom(name: name, instructions: "Instructions", sections: ["Section"])
    }

    @Test func syncDisabledByDefaultNeverTouchesCloud() {
        withScopedDefaults { settings, cloud in
            #expect(settings.templatesSyncEnabled == false)
            settings.addTemplate(customTemplate(name: "Local Only"))
            #expect(cloud.data(forKey: Self.cloudKey) == nil)
        }
    }

    @Test func enablingSyncPushesExistingCustomTemplates() {
        withScopedDefaults { settings, cloud in
            settings.addTemplate(customTemplate(name: "Pre-existing"))
            settings.templatesSyncEnabled = true

            let synced = cloud.decodedTemplates(forKey: Self.cloudKey)
            #expect(synced.map(\.name) == ["Pre-existing"])
        }
    }

    @Test func enablingSyncNeverPushesBuiltIns() {
        withScopedDefaults { settings, cloud in
            settings.templatesSyncEnabled = true
            let synced = cloud.decodedTemplates(forKey: Self.cloudKey)
            #expect(synced.isEmpty)
        }
    }

    @Test func enablingSyncAdoptsTemplatesAlreadyInCloud() {
        withScopedDefaults { settings, cloud in
            let remote = customTemplate(name: "From Other Device")
            cloud.setData(try? JSONEncoder().encode([remote]), forKey: Self.cloudKey)

            settings.templatesSyncEnabled = true

            #expect(settings.summaryTemplates.contains { $0.id == remote.id && $0.name == "From Other Device" })
        }
    }

    @Test func addingTemplateWhileSyncedPushesToCloud() {
        withScopedDefaults { settings, cloud in
            settings.templatesSyncEnabled = true
            settings.addTemplate(customTemplate(name: "New Template"))

            let synced = cloud.decodedTemplates(forKey: Self.cloudKey)
            #expect(synced.map(\.name) == ["New Template"])
        }
    }

    /// The external-change handler dispatches its merge onto a `Task` (it has
    /// to hop back to `@MainActor` from a store notification), so this one
    /// needs to yield before asserting instead of using the synchronous helper.
    @Test func externalCloudChangeMergesIntoLocalTemplates() async {
        let defaults = UserDefaults.standard
        let snapshot = AppSettingsTests.keys.reduce(into: [String: Any]()) { acc, key in
            if let value = defaults.object(forKey: key) { acc[key] = value }
        }
        defer {
            for key in AppSettingsTests.keys {
                if let value = snapshot[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in AppSettingsTests.keys { defaults.removeObject(forKey: key) }

        let cloud = InMemoryCloudKeyValueStore()
        let settings = AppSettings(cloudStore: cloud)
        settings.templatesSyncEnabled = true
        let fromOtherDevice = customTemplate(name: "Written Elsewhere")

        cloud.simulateExternalWrite([fromOtherDevice], forKey: Self.cloudKey)
        await Task.yield()

        #expect(settings.summaryTemplates.contains { $0.id == fromOtherDevice.id })
    }

    @Test func disablingSyncClearsCloudCopy() {
        withScopedDefaults { settings, cloud in
            settings.templatesSyncEnabled = true
            settings.addTemplate(customTemplate(name: "Will Be Cleared"))
            #expect(cloud.data(forKey: Self.cloudKey) != nil)

            settings.templatesSyncEnabled = false

            #expect(cloud.data(forKey: Self.cloudKey) == nil)
        }
    }

    @Test func newerLocalEditWinsOverStaleCloudCopy() {
        withScopedDefaults { settings, cloud in
            let original = customTemplate(name: "Local Edit")
            settings.addTemplate(original)

            var stale = original
            stale.name = "Remote Stale"
            stale.updatedAt = Date().addingTimeInterval(-3600)
            cloud.setData(try? JSONEncoder().encode([stale]), forKey: Self.cloudKey)

            settings.templatesSyncEnabled = true

            #expect(settings.template(for: original.id)?.name == "Local Edit")
        }
    }
}
