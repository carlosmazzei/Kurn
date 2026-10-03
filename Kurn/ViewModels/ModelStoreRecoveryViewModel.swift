//
//  ModelStoreRecoveryViewModel.swift
//  Kurn
//
//  Drives `ModelStoreRecoveryView`'s actions (H2 PR 4,
//  docs/resilience-megaplan.md): list/restore backup generations, attempt
//  salvage, export diagnostics, and a confirmed fresh start. Deliberately
//  store-independent like the view it backs — everything here talks to the
//  filesystem directly (`ModelStoreBackupManager`, `ModelStoreSalvage`),
//  never a `ModelContext`, since the whole point is working when the store
//  itself can't be opened.
//
//  Restore, salvage and fresh start re-authenticate first when the recordings
//  lock is on. This shell runs before the store is open, so the app's security
//  cover is not in place yet — and salvage in particular exports every meeting
//  it can still read. Diagnostics carry no content and stay unauthenticated.
//

import Foundation
import KurnCore
import SwiftUI

@MainActor
@Observable
final class ModelStoreRecoveryViewModel {
    private(set) var backupGenerations: [ModelStoreBackupGeneration] = []
    private(set) var isPerformingAction = false
    private(set) var salvageResult: ModelStoreSalvageResult?
    var errorMessage: String?
    var shareItem: ShareItem?

    private let appSupportDirectory: URL
    private let backupManager: ModelStoreBackupManager
    private let authorizer: SensitiveActionAuthorizer
    /// `AppSettings.requireAuthForRecordings`, read at action time.
    private let requiresAuthentication: @MainActor () -> Bool
    /// Called after a restore or fresh start moves the live store aside (or
    /// replaces it) — the caller retries opening.
    private let onStoreReplaced: () -> Void

    init(
        appSupportDirectory: URL,
        authorizer: SensitiveActionAuthorizer = SensitiveActionAuthorizer(),
        requiresAuthentication: @escaping @MainActor () -> Bool,
        onStoreReplaced: @escaping () -> Void
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.backupManager = ModelStoreBackupManager(appSupportDirectory: appSupportDirectory)
        self.authorizer = authorizer
        self.requiresAuthentication = requiresAuthentication
        self.onStoreReplaced = onStoreReplaced
        refreshGenerations()
    }

    func refreshGenerations() {
        backupGenerations = backupManager.listGenerations()
    }

    /// Quarantines the current live store (never deletes it) and copies
    /// `generation`'s files back into place, then asks the caller to retry
    /// opening.
    func restore(_ generation: ModelStoreBackupGeneration) async {
        guard await authorizeContentAccess() else { return }
        performAction {
            try backupManager.restore(generation: generation)
            onStoreReplaced()
        }
    }

    /// Quarantines the current live store (never deletes it) and leaves the
    /// live location empty, so the next open attempt creates a brand-new
    /// store there. Never automatic — only called from an explicit,
    /// double-confirmed user action in the view.
    func confirmedFreshStart() async {
        guard await authorizeContentAccess() else { return }
        performAction {
            try backupManager.quarantineLiveStore()
            onStoreReplaced()
        }
    }

    /// Best-effort recovery of readable data without touching the live
    /// store — see `ModelStoreSalvage` for why this can succeed even when
    /// the live open just failed, and why it sometimes won't.
    func attemptSalvage() async {
        guard await authorizeContentAccess() else { return }
        performAction {
            let (result, markdown) = ModelStoreSalvage.attempt(appSupportDirectory: appSupportDirectory)
            salvageResult = result
            if let markdown {
                let url = try MeetingExport.temporaryFile(
                    markdown: markdown, suggestedName: "kurn-salvage-\(Int(Date().timeIntervalSince1970))"
                )
                shareItem = ShareItem(urls: [url])
            }
        }
    }

    /// A content-free-except-for-what's-already-shown-on-screen report: the
    /// classified reason and the available backup generations. No raw error
    /// text, no meeting content — matches `AppError.logCode`'s privacy bar.
    func exportDiagnostics(failure: ModelStoreOpenFailure) {
        performAction {
            let url = try MeetingExport.temporaryFile(
                markdown: diagnosticsText(failure: failure),
                suggestedName: "kurn-store-diagnostics-\(Int(Date().timeIntervalSince1970))"
            )
            shareItem = ShareItem(urls: [url])
        }
    }

    private func diagnosticsText(failure: ModelStoreOpenFailure) -> String {
        var out = "# Kurn store recovery diagnostics\n\n"
        out += "Reason: \(failure.reason.rawValue)\n"
        out += "Log code: \(failure.logCode)\n\n"
        out += "## Backup generations\n\n"
        if backupGenerations.isEmpty {
            out += "(none)\n"
        } else {
            for generation in backupGenerations {
                out += "- \(generation.id) — schema \(generation.schemaVersion), "
                out += "app \(generation.appVersion) (\(generation.appBuild))\n"
            }
        }
        return out
    }

    private func authorizeContentAccess() async -> Bool {
        switch await authorizer.authorize(requireAuth: requiresAuthentication()) {
        case .authorized:
            return true
        case .cancelled:
            return false
        case .denied(let error):
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func performAction(_ action: () throws -> Void) {
        isPerformingAction = true
        defer {
            isPerformingAction = false
            refreshGenerations()
        }
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
