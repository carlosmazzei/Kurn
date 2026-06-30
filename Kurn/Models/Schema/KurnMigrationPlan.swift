//
//  KurnMigrationPlan.swift
//  Kurn
//
//  Maps the on-disk store between schema versions. The current jump (V1 → V2)
//  only adds a new entity (`Folder`) and an optional relationship
//  (`Meeting.folder`), so SwiftData can handle it with `.lightweight`: existing
//  meetings come back with `folder == nil` and no `Folder` rows exist.
//
//  When a future change is non-trivial (renames, splits, type changes), add a
//  new `KurnSchemaV3` and a `.custom` stage here. The schemas array dictates
//  the chain SwiftData walks, oldest first.
//

import Foundation
import SwiftData

enum KurnMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KurnSchemaV1.self, KurnSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: KurnSchemaV1.self,
                toVersion: KurnSchemaV2.self
            )
        ]
    }
}
