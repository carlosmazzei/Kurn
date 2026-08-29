//
//  ThrowingModelContainerFactory.swift
//  KurnTests
//
//  A `ModelContainerFactory` double that always fails, so a test can drive
//  `ModelContainerBootstrap.makeStore`'s failure path without needing a real
//  unopenable store (a locked file, an incompatible schema, a full disk).
//

import Foundation
import SwiftData
@testable import Kurn

struct ThrowingModelContainerFactory: ModelContainerFactory {
    let error: Error

    init(error: Error = NSError(domain: "ThrowingModelContainerFactory", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "simulated container creation failure"
    ])) {
        self.error = error
    }

    func makeContainer(schema: Schema, configurations: [ModelConfiguration]) throws -> ModelContainer {
        throw error
    }
}
