//
//  ModelContainerBootstrapTests.swift
//  KurnTests
//
//  Proves the `ModelContainerFactory` seam: a construction failure
//  propagates through `ModelContainerBootstrap.makeStore` rather than being
//  swallowed or masquerading as success, and that `makeStore` defaults to the
//  app's one centralized, versioned schema (`KurnModelGraph`) instead of each
//  call site re-declaring its own model list. This is the seam H2's eventual
//  migration/bootstrap state machine will drive with real failure fixtures
//  (locked store, incompatible schema, full disk) — here it only needs to
//  prove the plumbing works with a canned error, and that the schema/
//  migration-plan values reaching a factory are the centralized ones.
//
//  See `LegacyStoreAdoptionTests` for the round-trip proof that a store
//  written with a bare, unversioned schema (exactly what every Kurn store
//  predating this file is) still opens through `KurnModelGraph` without data
//  loss.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

struct ModelContainerBootstrapTests {

    @Test func propagatesFactoryFailureRatherThanSucceeding() {
        let schema = Schema([Meeting.self])
        let failure = NSError(domain: "test", code: 42)

        #expect(throws: Error.self) {
            _ = try ModelContainerBootstrap.makeStore(
                schema: schema,
                migrationPlan: nil,
                factory: ThrowingModelContainerFactory(error: failure)
            )
        }
    }

    @Test func succeedsWithAWorkingFactory() throws {
        // Exercises the same `factory.makeContainer` call
        // `SystemModelContainerFactory` makes in production, but against an
        // in-memory configuration passed through a stand-in factory — this
        // proves `makeStore`'s own plumbing (both `ModelStoreProtection.apply()`
        // calls, the container it returns) without touching the shared,
        // on-disk default store `SystemModelContainerFactory` itself targets.
        struct InMemoryModelContainerFactory: ModelContainerFactory {
            func makeContainer(
                schema: Schema,
                migrationPlan: (any SchemaMigrationPlan.Type)?,
                configurations: [ModelConfiguration]
            ) throws -> ModelContainer {
                try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            }
        }
        let schema = Schema([Meeting.self])
        let container = try ModelContainerBootstrap.makeStore(
            schema: schema, migrationPlan: nil, factory: InMemoryModelContainerFactory()
        )
        #expect(container.schema.entities.map(\.name) == schema.entities.map(\.name))
    }

    @Test func defaultsToTheCentralizedVersionedSchemaAndMigrationPlan() throws {
        final class RecordingModelContainerFactory: ModelContainerFactory, @unchecked Sendable {
            private(set) var capturedSchema: Schema?
            private(set) var capturedMigrationPlan: (any SchemaMigrationPlan.Type)?

            func makeContainer(
                schema: Schema,
                migrationPlan: (any SchemaMigrationPlan.Type)?,
                configurations: [ModelConfiguration]
            ) throws -> ModelContainer {
                capturedSchema = schema
                capturedMigrationPlan = migrationPlan
                // Real construction needs an in-memory configuration — the
                // caller-provided one targets the on-disk default store.
                let inMemoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [inMemoryConfiguration])
            }
        }

        let factory = RecordingModelContainerFactory()
        _ = try ModelContainerBootstrap.makeStore(factory: factory)

        let expectedNames = Set(KurnModelGraph.schema.entities.map(\.name))
        #expect(Set(factory.capturedSchema?.entities.map(\.name) ?? []) == expectedNames)
        let capturedMigrationPlanIdentifier = factory.capturedMigrationPlan.map { ObjectIdentifier($0) }
        #expect(capturedMigrationPlanIdentifier == ObjectIdentifier(KurnSchemaMigrationPlan.self))
    }
}

struct KurnModelGraphTests {

    @Test func declaresEveryPersistentModelExactlyOnce() {
        let identifiers = Set(KurnModelGraph.currentModels.map { ObjectIdentifier($0) })
        #expect(identifiers.count == KurnModelGraph.currentModels.count)
        #expect(identifiers == Set([
            ObjectIdentifier(Meeting.self),
            ObjectIdentifier(Recording.self),
            ObjectIdentifier(Transcript.self),
            ObjectIdentifier(Speaker.self),
            ObjectIdentifier(Summary.self),
            ObjectIdentifier(Folder.self),
            ObjectIdentifier(Tag.self),
            ObjectIdentifier(SmartFolder.self),
            ObjectIdentifier(SemanticChunk.self),
            ObjectIdentifier(WikiArticle.self),
            ObjectIdentifier(GeneratedDocument.self)
        ]))
    }

    @Test func migrationPlanDeclaresOnlyTheCurrentSchemaWithNoStagesYet() {
        // Correct and complete for a first-ever versioned schema: there is
        // nothing to migrate *from* yet. The next non-additive model change
        // must add KurnSchemaV2 here rather than editing KurnSchemaV1 in place.
        #expect(KurnSchemaMigrationPlan.schemas.count == 1)
        #expect(KurnSchemaMigrationPlan.schemas.map { ObjectIdentifier($0) } == [ObjectIdentifier(KurnSchemaV1.self)])
        #expect(KurnSchemaMigrationPlan.stages.isEmpty)
    }

    @Test func versionedSchemaModelsMatchTheCentralizedGraph() {
        let versionedIdentifiers = Set(KurnSchemaV1.models.map { ObjectIdentifier($0) })
        let graphIdentifiers = Set(KurnModelGraph.currentModels.map { ObjectIdentifier($0) })
        #expect(versionedIdentifiers == graphIdentifiers)
    }
}
