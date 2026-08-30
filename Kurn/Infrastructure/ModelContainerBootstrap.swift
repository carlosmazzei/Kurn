//
//  ModelContainerBootstrap.swift
//  Kurn
//
//  Pure extraction of the production `ModelContainer` creation logic out of
//  `KurnApp`'s property initializer, so it is callable — and its failure
//  path testable — without instantiating the app itself. This does not fix
//  the rest of H2 (the roadmap's "Recoverable store bootstrap" item: a boot
//  state machine, protected backups, restore/salvage UI); `KurnApp` still
//  `fatalError`s on a construction failure exactly as it did before. Schema
//  and migration-plan selection are injectable (see `KurnSchema.swift`) so a
//  test can exercise the real versioned/migrating path, and this gives that
//  failure a seam a test can drive deterministically, which H2's eventual
//  state machine will build on.
//

import Foundation
import SwiftData

protocol ModelContainerFactory: Sendable {
    func makeContainer(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configurations: [ModelConfiguration]
    ) throws -> ModelContainer
}

struct SystemModelContainerFactory: ModelContainerFactory {
    func makeContainer(
        schema: Schema,
        migrationPlan: (any SchemaMigrationPlan.Type)?,
        configurations: [ModelConfiguration]
    ) throws -> ModelContainer {
        guard let migrationPlan else {
            return try ModelContainer(for: schema, configurations: configurations)
        }
        return try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: configurations)
    }
}

enum ModelContainerBootstrap {
    /// Builds the on-disk store, applying file protection both before creation
    /// (hardening a pre-existing store) and after (hardening a store SwiftData
    /// just created for the first time) — the same two-call shape
    /// `KurnApp`'s container initializer used inline.
    ///
    /// Defaults to the app's one centralized, versioned schema
    /// (`KurnModelGraph`) rather than requiring every call site to pass it, so
    /// production and tests exercise the same graph unless a test deliberately
    /// substitutes another one (e.g. `LegacyStoreAdoptionTests` opening a store
    /// written with a bare, unversioned schema).
    static func makeStore(
        schema: Schema = KurnModelGraph.schema,
        migrationPlan: (any SchemaMigrationPlan.Type)? = KurnModelGraph.migrationPlan,
        factory: some ModelContainerFactory = SystemModelContainerFactory()
    ) throws -> ModelContainer {
        ModelStoreProtection.apply()
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try factory.makeContainer(
            schema: schema,
            migrationPlan: migrationPlan,
            configurations: [configuration]
        )
        ModelStoreProtection.apply()
        return container
    }
}
