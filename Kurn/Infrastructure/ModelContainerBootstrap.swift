//
//  ModelContainerBootstrap.swift
//  Kurn
//
//  Pure extraction of the production `ModelContainer` creation logic out of
//  `KurnApp`'s property initializer, so it is callable — and its failure
//  path testable — without instantiating the app itself. This does not fix
//  H2 (the roadmap's "Recoverable store bootstrap" item: a boot state
//  machine, versioned migrations, protected backups); `KurnApp` still
//  `fatalError`s on a construction failure exactly as it did before. It only
//  gives that failure a seam a test can drive deterministically, which H2's
//  eventual state machine will build on.
//

import Foundation
import SwiftData

protocol ModelContainerFactory: Sendable {
    func makeContainer(schema: Schema, configurations: [ModelConfiguration]) throws -> ModelContainer
}

struct SystemModelContainerFactory: ModelContainerFactory {
    func makeContainer(schema: Schema, configurations: [ModelConfiguration]) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: configurations)
    }
}

enum ModelContainerBootstrap {
    /// Builds the on-disk store, applying file protection both before creation
    /// (hardening a pre-existing store) and after (hardening a store SwiftData
    /// just created for the first time) — the same two-call shape
    /// `KurnApp`'s container initializer used inline.
    static func makeStore(
        schema: Schema,
        factory: some ModelContainerFactory = SystemModelContainerFactory()
    ) throws -> ModelContainer {
        ModelStoreProtection.apply()
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = try factory.makeContainer(schema: schema, configurations: [configuration])
        ModelStoreProtection.apply()
        return container
    }
}
