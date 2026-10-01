//
//  AppSettings+Templates.swift
//  Kurn
//
//  Summary template management and iCloud key-value sync: add, update and
//  remove a template, merge stored templates with the built-in presets, and
//  reconcile user-created templates with the other devices. See CLAUDE.md,
//  "Template sync is iCloud key-value, deliberately not CloudKit".
//

import Foundation
import KurnCore

extension AppSettings {

    func template(for id: String) -> SummaryTemplate? {
        summaryTemplates.first(where: { $0.id == id })
    }

    func addTemplate(_ template: SummaryTemplate) {
        summaryTemplates.append(template)
        pushTemplatesToCloudIfSyncing()
    }

    func updateTemplate(_ template: SummaryTemplate) {
        guard let index = summaryTemplates.firstIndex(where: { $0.id == template.id }) else { return }
        var updated = template
        updated.updatedAt = Date()
        summaryTemplates[index] = updated
        pushTemplatesToCloudIfSyncing()
    }

    func removeTemplate(_ template: SummaryTemplate) {
        guard !template.isBuiltIn else { return }
        summaryTemplates.removeAll { $0.id == template.id }
        if lastSummaryTemplateID == template.id {
            lastSummaryTemplateID = summaryTemplates.first?.id ?? SummaryTemplate.general.id
        }
        pushTemplatesToCloudIfSyncing()
    }

    /// Merges this device's custom templates with whatever is currently in
    /// iCloud (`TemplateSyncMerger`), applies the result locally if it
    /// changed, and pushes the merged set back so both sides converge.
    func reconcileTemplatesWithCloud() {
        let localCustom = summaryTemplates.filter { !$0.isBuiltIn }
        let remoteCustom: [SummaryTemplate]
        if let data = cloudStore.data(forKey: Self.cloudTemplatesKey),
           let decoded = try? JSONDecoder().decode([SummaryTemplate].self, from: data) {
            remoteCustom = decoded
        } else {
            remoteCustom = []
        }
        let merged = TemplateSyncMerger.merge(local: localCustom, remote: remoteCustom)
        if merged != localCustom {
            let builtIns = summaryTemplates.filter(\.isBuiltIn)
            summaryTemplates = builtIns + merged
        }
        if let data = try? JSONEncoder().encode(merged) {
            cloudStore.setData(data, forKey: Self.cloudTemplatesKey)
        }
    }

    func pushTemplatesToCloudIfSyncing() {
        guard templatesSyncEnabled else { return }
        let custom = summaryTemplates.filter { !$0.isBuiltIn }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        cloudStore.setData(data, forKey: Self.cloudTemplatesKey)
    }

    /// Keep stored templates (user edits to built-ins persist) and append any
    /// built-in preset that isn't present yet, so new presets appear on upgrade.
    static func mergedTemplates(_ stored: [SummaryTemplate]) -> [SummaryTemplate] {
        var templates = stored
        for builtIn in SummaryTemplate.defaultTemplates
        where !templates.contains(where: { $0.id == builtIn.id }) {
            templates.append(builtIn)
        }
        return templates
    }
}
