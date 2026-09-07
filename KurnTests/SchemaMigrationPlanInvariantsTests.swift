//
//  SchemaMigrationPlanInvariantsTests.swift
//  KurnTests
//
//  Structural guards over `KurnSchemaMigrationPlan` that hold for *every*
//  version in it, not just V1/V2, so that adding `KurnSchemaV3` is checked by
//  the same tests without anyone remembering to extend them.
//
//  They exist because of a migration that failed in production while CI was
//  green: the first cut of `KurnSchemaV2` left `KurnSchemaV1.models` pointing
//  at the live `@Model` classes, so "1.0.0" silently acquired
//  `Meeting.chatSessions` — a relationship to an entity V1 did not even list.
//  No real 1.0.0 store matched that description, so the plan had nothing to
//  migrate from. `LegacyStoreAdoptionTests` did not notice because its fixture
//  was written with the same live classes. Each test below would have failed
//  on that commit: the type-sharing check directly, the dangling-destination
//  check because V1's `Meeting` pointed at `ChatSession`, and the entity-name
//  check because the "frozen" schema described the new shape.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

struct SchemaMigrationPlanInvariantsTests {

    private var schemas: [any VersionedSchema.Type] { KurnSchemaMigrationPlan.schemas }

    @Test func versionsAreStrictlyIncreasingAndTheLastOneIsTheCurrentGraph() throws {
        let versions = schemas.map(\.versionIdentifier)
        #expect(versions.count >= 2)
        for (older, newer) in zip(versions, versions.dropFirst()) {
            #expect(older < newer, "\(older) must precede \(newer)")
        }

        let current = try #require(schemas.last)
        #expect(current.versionIdentifier == KurnModelGraph.currentSchemaVersion)
        #expect(
            Set(current.models.map { ObjectIdentifier($0) })
                == Set(KurnModelGraph.currentModels.map { ObjectIdentifier($0) })
        )
    }

    @Test func stagesChainEveryConsecutivePairOfVersionsInOrder() {
        let stages = KurnSchemaMigrationPlan.stages
        #expect(stages.count == schemas.count - 1)

        for (index, stage) in stages.enumerated() where index + 1 < schemas.count {
            let (from, to) = endpoints(of: stage)
            #expect(from == schemas[index].versionIdentifier, "stage \(index) must start at \(schemas[index].versionIdentifier)")
            #expect(to == schemas[index + 1].versionIdentifier, "stage \(index) must end at \(schemas[index + 1].versionIdentifier)")
        }
    }

    /// The core rule: a version is only a version if its model types belong
    /// to it alone. Two versions listing the same class describe the same
    /// shape, so the older one follows every edit to the live class and stops
    /// matching the stores it is supposed to describe.
    @Test func noTwoVersionsShareAModelType() {
        var seen: [ObjectIdentifier: Schema.Version] = [:]
        for schema in schemas {
            for model in schema.models {
                let identifier = ObjectIdentifier(model)
                if let owner = seen[identifier] {
                    Issue.record("\(model) is listed by both \(owner) and \(schema.versionIdentifier); freeze a copy per version")
                }
                seen[identifier] = schema.versionIdentifier
            }
        }
    }

    /// Only the newest version may be built from the live classes — every
    /// older one has to be frozen copies, otherwise the live edit that
    /// introduced the newest version has already leaked into its predecessor.
    @Test func onlyTheCurrentVersionListsTheLiveModelClasses() {
        let liveIdentifiers = Set(KurnModelGraph.currentModels.map { ObjectIdentifier($0) })
        for schema in schemas.dropLast() {
            for model in schema.models where liveIdentifiers.contains(ObjectIdentifier(model)) {
                Issue.record("\(schema.versionIdentifier) lists the live \(model); it must use a frozen copy")
            }
        }
    }

    /// Every relationship in every version must point at an entity that
    /// version actually lists. A frozen `Meeting` that still references
    /// `ChatSession` is exactly how a stale version betrays itself.
    @Test func everyRelationshipDestinationExistsInItsOwnVersion() {
        for schema in schemas {
            let built = Schema(versionedSchema: schema)
            let names = Set(built.entities.map(\.name))
            #expect(names.count == schema.models.count, "\(schema.versionIdentifier) has duplicate entity names")
            for entity in built.entities {
                for relationship in entity.relationships where !names.contains(relationship.destination) {
                    Issue.record(
                        "\(schema.versionIdentifier): \(entity.name).\(relationship.name) points at \(relationship.destination), which that version does not list"
                    )
                }
            }
        }
    }

    /// Frozen copies keep the entity names of their live counterparts — the
    /// store's tables are keyed by entity name, so a rename here would be a
    /// silent drop-and-recreate rather than a migration.
    @Test func everyOlderVersionsEntitiesStillExistInTheNextVersion() {
        for (older, newer) in zip(schemas, schemas.dropFirst()) {
            let olderNames = Set(Schema(versionedSchema: older).entities.map(\.name))
            let newerNames = Set(Schema(versionedSchema: newer).entities.map(\.name))
            let dropped = olderNames.subtracting(newerNames)
            #expect(
                dropped.isEmpty,
                "\(older.versionIdentifier) → \(newer.versionIdentifier) drops entities \(dropped.sorted()); a removal needs a .custom stage and a deliberate decision"
            )
        }
    }

    private func endpoints(of stage: MigrationStage) -> (from: Schema.Version, to: Schema.Version) {
        switch stage {
        case .lightweight(let from, let to):
            return (from.versionIdentifier, to.versionIdentifier)
        case .custom(let from, let to, _, _):
            return (from.versionIdentifier, to.versionIdentifier)
        @unknown default:
            Issue.record("unknown MigrationStage case")
            return (Schema.Version(0, 0, 0), Schema.Version(0, 0, 0))
        }
    }
}
