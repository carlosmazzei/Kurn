//
//  ModelContainerBootstrapTests.swift
//  KurnTests
//
//  Proves the `ModelContainerFactory` seam: a construction failure
//  propagates through `ModelContainerBootstrap.makeStore` rather than being
//  swallowed or masquerading as success. This is the seam H2's eventual
//  migration/bootstrap state machine will drive with real failure fixtures
//  (locked store, incompatible schema, full disk) — here it only needs to
//  prove the plumbing works with a canned error.
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
            func makeContainer(schema: Schema, configurations: [ModelConfiguration]) throws -> ModelContainer {
                try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            }
        }
        let schema = Schema([Meeting.self])
        let container = try ModelContainerBootstrap.makeStore(
            schema: schema, factory: InMemoryModelContainerFactory()
        )
        #expect(container.schema.entities.map(\.name) == schema.entities.map(\.name))
    }
}
