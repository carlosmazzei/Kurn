//
//  TemplateSyncMerger.swift
//  Kurn
//
//  Pure merge for custom summary templates synced via iCloud key-value storage
//  (see CloudSettingsSync). Built-ins are never synced — they're already
//  re-seeded locally by AppSettings.mergedTemplates — so this only reconciles
//  user-created ones between the copy on this device and the one just read
//  back from iCloud.
//

import Foundation

enum TemplateSyncMerger {
    /// Per id, keeps whichever side was edited more recently. A template
    /// present on only one side is kept as-is — deletions don't propagate
    /// across devices in this v1; the same id reappearing after a delete just
    /// means the other device hasn't synced its delete yet.
    static func merge(local: [SummaryTemplate], remote: [SummaryTemplate]) -> [SummaryTemplate] {
        var merged: [String: SummaryTemplate] = [:]
        for template in local {
            merged[template.id] = template
        }
        for template in remote {
            if let existing = merged[template.id], existing.updatedAt >= template.updatedAt {
                continue
            }
            merged[template.id] = template
        }
        return merged.values.sorted { $0.createdAt < $1.createdAt }
    }
}
