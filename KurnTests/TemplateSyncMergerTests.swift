//
//  TemplateSyncMergerTests.swift
//  KurnTests
//
//  Pure merge logic for iCloud-synced custom summary templates.
//

import Foundation
import Testing
@testable import Kurn

struct TemplateSyncMergerTests {

    private func template(
        id: String,
        name: String = "Template",
        createdAt: Date = Date(),
        updatedAt: Date
    ) -> SummaryTemplate {
        SummaryTemplate(
            id: id,
            name: name,
            iconName: "doc.text",
            instructions: "Instructions",
            sections: ["Section"],
            isBuiltIn: false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    @Test func keepsNewerLocalEditOverOlderRemote() {
        let base = Date()
        let local = template(id: "a", name: "Local edit", updatedAt: base.addingTimeInterval(60))
        let remote = template(id: "a", name: "Remote (stale)", updatedAt: base)

        let merged = TemplateSyncMerger.merge(local: [local], remote: [remote])

        #expect(merged.count == 1)
        #expect(merged[0].name == "Local edit")
    }

    @Test func adoptsNewerRemoteEditOverOlderLocal() {
        let base = Date()
        let local = template(id: "a", name: "Local (stale)", updatedAt: base)
        let remote = template(id: "a", name: "Remote edit", updatedAt: base.addingTimeInterval(60))

        let merged = TemplateSyncMerger.merge(local: [local], remote: [remote])

        #expect(merged.count == 1)
        #expect(merged[0].name == "Remote edit")
    }

    @Test func unionsTemplatesPresentOnOnlyOneSide() {
        let now = Date()
        let local = template(id: "local-only", updatedAt: now)
        let remote = template(id: "remote-only", updatedAt: now)

        let merged = TemplateSyncMerger.merge(local: [local], remote: [remote])

        #expect(Set(merged.map(\.id)) == ["local-only", "remote-only"])
    }

    @Test func isStableWhenBothSidesAreIdentical() {
        let now = Date()
        let template = template(id: "a", updatedAt: now)

        let merged = TemplateSyncMerger.merge(local: [template], remote: [template])

        #expect(merged == [template])
    }

    @Test func emptyRemoteKeepsLocalUnchanged() {
        let now = Date()
        let local = [template(id: "a", updatedAt: now), template(id: "b", updatedAt: now)]

        let merged = TemplateSyncMerger.merge(local: local, remote: [])

        #expect(Set(merged.map(\.id)) == Set(local.map(\.id)))
    }
}
