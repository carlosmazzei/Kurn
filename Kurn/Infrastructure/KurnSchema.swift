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
/// that existed before this file did, as they were shaped *then*. The entries
/// below resolve to the frozen nested copies in `KurnSchemaV1Models.swift`
/// (`KurnSchemaV1.Meeting`, …), not to the live classes: a `VersionedSchema`
/// that lists the live classes is redefined by every edit to them, stops
/// matching the stores it is supposed to describe, and leaves the migration
/// plan with no version to migrate *from*. Nothing here may change — a model
/// change goes into the current version's live classes plus a new
/// `KurnSchemaVn` and `MigrationStage`.
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

/// Version 1.1.0: adds `ChatSession` (saved "chat with your meetings"
/// conversations) and its cascade relationship on `Meeting`. Both are
/// additive — a new entity and a new to-many relationship, nothing renamed or
/// removed — which is exactly what `MigrationStage.lightweight` below exists
/// for: SwiftData infers the migration from the two schemas without a custom
/// transform. This is the *current* version, so it lists the live `@Model`
/// classes; when the next version is added, these eleven-plus-one get frozen
/// copies of their own the way `KurnSchemaV1Models.swift` does for 1.0.0.
enum KurnSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 1, 0) }

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
            GeneratedDocument.self,
            ChatSession.self
        ]
    }
}

/// The app's migration plan. `KurnSchemaV1` shipped with no stages — the
/// correct, documented shape for "this is the first version we've ever
/// declared", nothing to migrate *from* yet. `KurnSchemaV2` is the first real
/// use of this plan: a lightweight stage covers it because the change is
/// purely additive (see `KurnSchemaV2`'s doc comment). The next
/// *non*-additive model change adds `KurnSchemaV3` here with a `.custom`
/// stage; it must never edit `KurnSchemaV1`/`KurnSchemaV2` in place.
enum KurnSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [KurnSchemaV1.self, KurnSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: KurnSchemaV1.self, toVersion: KurnSchemaV2.self)]
    }
}

/// What `KurnApp`, `ModelContainerBootstrap`, the screenshot container, and
/// `TestModelContainer` should all build their `ModelContainer` from, instead
/// of each re-listing the model types.
enum KurnModelGraph {
    /// The current model graph, for call sites that need the bare type list
    /// (e.g. an in-memory test container with no migration concerns).
    static var currentModels: [any PersistentModel.Type] {
        KurnSchemaV2.models
    }

    /// The versioned schema production and screenshot containers should use.
    static var schema: Schema {
        Schema(versionedSchema: KurnSchemaV2.self)
    }

    /// The version a store written by the current graph is at — what backup
    /// metadata and diagnostics should record, so it moves with `schema`
    /// rather than being pinned to whichever version happened to be current
    /// when the call site was written.
    static var currentSchemaVersion: Schema.Version {
        KurnSchemaV2.versionIdentifier
    }

    /// The migration plan production and screenshot containers should use.
    static var migrationPlan: any SchemaMigrationPlan.Type {
        KurnSchemaMigrationPlan.self
    }
}
