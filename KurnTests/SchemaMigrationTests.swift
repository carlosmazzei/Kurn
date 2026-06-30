//
//  SchemaMigrationTests.swift
//  KurnTests
//
//  Smoke-tests the schema versioning wiring: each `VersionedSchema` declares
//  the expected models, the `KurnMigrationPlan` chains V1 → V2 with a
//  lightweight stage, and a `ModelContainer` built from V2 + the plan opens
//  cleanly. Apple's lightweight migration itself is well-tested upstream — our
//  responsibility here is to make sure the plan is correctly assembled and
//  that the V1 snapshot stays in sync with the V2 surface area for the
//  unchanged entities.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct SchemaMigrationTests {

    @Test func versionIdentifiersAreV1AndV2() {
        #expect(KurnSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(KurnSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    }

    @Test func v1ListsFivePreFolderModels() {
        let names = KurnSchemaV1.models.map { String(describing: $0) }.sorted()
        #expect(names == ["Meeting", "Recording", "Speaker", "Summary", "Transcript"])
    }

    @Test func v2AddsFolderToTheModelSet() {
        let names = KurnSchemaV2.models.map { String(describing: $0) }.sorted()
        #expect(names == ["Folder", "Meeting", "Recording", "Speaker", "Summary", "Transcript"])
    }

    @Test func migrationPlanChainsV1ToV2() {
        let schemaNames = KurnMigrationPlan.schemas.map { String(describing: $0) }
        #expect(schemaNames == ["KurnSchemaV1", "KurnSchemaV2"])
        #expect(KurnMigrationPlan.stages.count == 1)
    }

    @Test func v2ContainerOpensWithMigrationPlan() throws {
        // Building an in-memory container with the migration plan exercises the
        // schema's internal consistency without touching disk: SwiftData would
        // throw at construction if any relationship inverse or property type
        // failed to resolve.
        let schema = Schema(KurnSchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: KurnMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        let folder = Folder(name: "Smoke")
        let meeting = Meeting(title: "Smoke", folder: folder)
        context.insert(folder)
        context.insert(meeting)
        try context.save()
        #expect(folder.meetings.contains(where: { $0.persistentModelID == meeting.persistentModelID }))
    }
}
