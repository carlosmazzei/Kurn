//
//  AppCompositionTests.swift
//  KurnTests
//
//  The background transcription runner used to build its own view model with
//  no semantic-index or wiki coordinator, so a run finished in a
//  `BGProcessingTask` window was silently left unindexed. These pin the
//  wiring that replaced it: every coordinator gets its dependencies at
//  construction, from the one composition root both entry points share.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct AppCompositionTests {

    @Test func makeEnvironmentWiresEveryCoordinatorAtConstruction() throws {
        let container = TestModelContainer.make()
        let settings = try makeSettings()

        let environment = AppComposition.makeEnvironment(container: container, settings: settings)

        #expect(environment.modelContainer === container)
        #expect(environment.transcription.appSettings === settings)
        #expect(environment.transcription.semanticIndexCoordinator === environment.semanticIndex)
        #expect(environment.transcription.wikiCoordinator === environment.wiki)
        #expect(environment.semanticIndex.appSettings === settings)
        #expect(environment.wiki.appSettings === settings)
        #expect(environment.summaries.appSettings === settings)
        #expect(environment.summaries.modelContext === container.mainContext)
    }

    @Test func eachCallBuildsIndependentCoordinators() throws {
        let container = TestModelContainer.make()
        let settings = try makeSettings()

        let first = AppComposition.makeEnvironment(container: container, settings: settings)
        let second = AppComposition.makeEnvironment(container: container, settings: settings)

        // `makeEnvironment` is pure wiring; sharing instances across entry
        // points is `AppComposition.environment(for:)`'s job, not this one's.
        #expect(first.transcription !== second.transcription)
        #expect(second.transcription.semanticIndexCoordinator === second.semanticIndex)
    }

    private func makeSettings() throws -> AppSettings {
        let defaults = try #require(UserDefaults(suiteName: "AppCompositionTests-\(UUID().uuidString)"))
        return AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults)
    }
}
