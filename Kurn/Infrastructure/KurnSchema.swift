//
//  KurnSchema.swift
//  Kurn
//
//  Single source of truth for the app's SwiftData model graph. Production
//  (`KurnApp`), the screenshot in-memory container, and `TestModelContainer`
//  used to each list the eleven `@Model` types by hand, which made it possible
//  for the three to silently diverge (a model added to one and missed in
//  another compiles fine — SwiftData just never persists it there). This file
//  is the fix: everything downstream now reads `KurnModelGraph`.
//
//  `KurnSchemaV1` is also the first `VersionedSchema` this app has declared —
//  every store shipped before this file existed was opened with a bare,
//  unversioned `Schema([...])`. Declaring the current graph as version 1.0.0
//  does not by itself change what is on disk; it gives future model changes a
//  place to add version 1.1.0/2.0.0 and a `MigrationStage` between them,
//  which is the point of this PR (`docs/resilience-megaplan.md`'s H2 track).
//  `LegacyStoreAdoptionTests` proves an existing store created the old,
//  unversioned way still opens through this schema and migration plan without
//  data loss — see that file for why this is tested with a same-run generated
//  fixture rather than a committed binary store file.
//

import SwiftData

/// Version 1.0.0 of the app's model graph: exactly the eleven `@Model` types
/// that existed before this file did. Nothing here may be renamed or removed
/// without adding `KurnSchemaV2` and a `MigrationStage` — see the "Data
/// model" section of `CLAUDE.md` for the same rule already documented for
/// `Meeting.languageRaw`.
enum KurnSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            Meeting.self,
            Recording.self,
            Transcript.self,
            Speaker.self,
            Summary.self,
            Folder.self,
            Tag.self,
            SmartFolder.self,
            SemanticChunk.self,
            WikiArticle.self,
            GeneratedDocument.self
        ]
    }
}

/// The app's migration plan. A single schema with no stages is the correct,
/// documented shape for "this is the first version we've ever declared" —
/// there is nothing to migrate *from* yet. The next non-additive model change
/// adds `KurnSchemaV2` to `schemas` and a `MigrationStage` (lightweight or
/// custom) to `stages`; it must never edit `KurnSchemaV1` in place.
enum KurnSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KurnSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

/// What `KurnApp`, `ModelContainerBootstrap`, the screenshot container, and
/// `TestModelContainer` should all build their `ModelContainer` from, instead
/// of each re-listing the model types.
enum KurnModelGraph {
    /// The current model graph, for call sites that need the bare type list
    /// (e.g. an in-memory test container with no migration concerns).
    static var currentModels: [any PersistentModel.Type] {
        KurnSchemaV1.models
    }

    /// The versioned schema production and screenshot containers should use.
    static var schema: Schema {
        Schema(versionedSchema: KurnSchemaV1.self)
    }

    /// The migration plan production and screenshot containers should use.
    static var migrationPlan: any SchemaMigrationPlan.Type {
        KurnSchemaMigrationPlan.self
    }
}
