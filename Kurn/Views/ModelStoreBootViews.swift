//
//  ModelStoreBootViews.swift
//  Kurn
//
//  The two views `KurnApp` renders before a `ModelContainer` exists —
//  `ModelStoreLaunchProgressView` for `.waitingForProtectedData`/`.opening`,
//  `ModelStoreRecoveryView` for `.recoveryRequired`. Both are deliberately
//  store-independent (no `ModelContext`, no `AppSettings`): the recovery
//  shell must not depend on the very thing that failed to open.
//
//  H2 PR 3 (docs/resilience-megaplan.md) shipped Retry as the only action.
//  H2 PR 4 adds the rest — restore from a protected backup, best-effort
//  salvage into a separate read-only container, diagnostics export, and a
//  confirmed fresh start — all driven by `ModelStoreRecoveryViewModel`.
//  Restore and fresh start are both double-confirmed and never destructive:
//  `ModelStoreBackupManager` quarantines (moves, never deletes) the current
//  live store before either replaces it.
//

import SwiftUI

/// Shown while the boot coordinator hasn't resolved a container yet. On the
/// common path (protected data available, store opens cleanly) this is never
/// actually visible — `beginBoot()` resolves synchronously before `body` is
/// first evaluated. It only renders for a background-only launch while the
/// device is locked, briefly, before the scene ever becomes visible.
struct ModelStoreLaunchProgressView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ProgressView()
                .tint(Theme.accent)
                .accessibilityLabel(Text(NSLocalizedString("store_launch.opening", comment: "Opening")))
                .accessibilityIdentifier("storeLaunch.progress")
        }
    }
}

/// Shown when the store failed to open. Explains why (one of the classified
/// reasons) and offers every H2 recovery action: Retry, restore from a
/// protected backup, best-effort salvage, diagnostics export, and a
/// double-confirmed fresh start.
struct ModelStoreRecoveryView: View {
    let failure: ModelStoreOpenFailure
    let retry: () -> Void
    @Bindable var viewModel: ModelStoreRecoveryViewModel

    @State private var confirmingFreshStart = false
    @State private var confirmingRestoreOf: ModelStoreBackupGeneration?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                retryButton
                if !viewModel.backupGenerations.isEmpty {
                    backupsSection
                }
                salvageSection
                exportDiagnosticsButton
                startFreshButton
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .disabled(viewModel.isPerformingAction)
        .overlay {
            if viewModel.isPerformingAction {
                ProgressView().tint(Theme.accent)
            }
        }
        .sheet(item: $viewModel.shareItem) { item in ActivityView(items: item.urls) }
        .kurnDialog(
            isPresented: $confirmingFreshStart,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.warning,
            title: NSLocalizedString("store_recovery.start_fresh_confirm_title", comment: "Start fresh?"),
            message: NSLocalizedString("store_recovery.start_fresh_confirm_message", comment: "Old data moved aside, not deleted"),
            primaryTitle: NSLocalizedString("store_recovery.start_fresh_button", comment: "Start Fresh"),
            primaryRole: .destructive,
            primaryAction: { viewModel.confirmedFreshStart() },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: Binding(get: { confirmingRestoreOf != nil }, set: { if !$0 { confirmingRestoreOf = nil } }),
            iconSystemName: "arrow.uturn.backward",
            iconTint: Theme.accent,
            title: NSLocalizedString("store_recovery.restore_confirm_title", comment: "Restore this backup?"),
            message: NSLocalizedString("store_recovery.restore_confirm_message", comment: "Current data moved aside, not deleted"),
            primaryTitle: NSLocalizedString("store_recovery.restore_button", comment: "Restore"),
            primaryRole: .destructive,
            primaryAction: {
                if let generation = confirmingRestoreOf { viewModel.restore(generation) }
                confirmingRestoreOf = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .alert(
            NSLocalizedString("common.error", comment: "Error"),
            isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })
        ) {
            Button(NSLocalizedString("common.ok", comment: "OK")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(NSLocalizedString("store_recovery.title", comment: "Kurn couldn't open your data"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("storeRecovery.title")
            Text(reasonMessage)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var retryButton: some View {
        Button(action: retry) {
            Text(NSLocalizedString("store_recovery.retry", comment: "Retry"))
                .font(Theme.subheadlineEmphasized)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("storeRecovery.retryButton")
    }

    private var backupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("store_recovery.backups_title", comment: "Restore from Backup"))
                .font(Theme.subheadlineEmphasized)
                .foregroundStyle(Theme.textPrimary)
            ForEach(viewModel.backupGenerations) { generation in
                Button {
                    confirmingRestoreOf = generation
                } label: {
                    HStack {
                        Text(generation.createdAt, style: .relative)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(12)
                    .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storeRecovery.backupRow.\(generation.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var salvageSection: some View {
        VStack(spacing: 10) {
            secondaryButton(
                title: NSLocalizedString("store_recovery.salvage_button", comment: "Attempt Data Recovery"),
                identifier: "storeRecovery.salvageButton",
                action: { viewModel.attemptSalvage() }
            )
            if let salvageResult = viewModel.salvageResult {
                Text(salvageMessage(for: salvageResult))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var exportDiagnosticsButton: some View {
        secondaryButton(
            title: NSLocalizedString("store_recovery.export_diagnostics_button", comment: "Export Diagnostics"),
            identifier: "storeRecovery.exportDiagnosticsButton",
            action: { viewModel.exportDiagnostics(failure: failure) }
        )
    }

    private var startFreshButton: some View {
        Button(role: .destructive) {
            confirmingFreshStart = true
        } label: {
            Text(NSLocalizedString("store_recovery.start_fresh_button", comment: "Start Fresh"))
                .font(Theme.subheadlineEmphasized)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.warning)
        .padding(.top, 8)
        .accessibilityIdentifier("storeRecovery.startFreshButton")
    }

    private func secondaryButton(title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.subheadlineEmphasized)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Theme.accent)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func salvageMessage(for result: ModelStoreSalvageResult) -> String {
        switch result {
        case .unavailable, .failed:
            return NSLocalizedString("store_recovery.salvage_result_none", comment: "No data could be recovered")
        case .recovered(let meetingCount):
            return String(
                format: NSLocalizedString("store_recovery.salvage_result_recovered", comment: "%d meetings recovered"),
                meetingCount
            )
        }
    }

    private var reasonMessage: String {
        switch failure.reason {
        case .protectedDataUnavailable:
            return NSLocalizedString(
                "store_recovery.reason_protected_data_unavailable",
                comment: "Device locked, unlock and retry"
            )
        case .storageFull:
            return NSLocalizedString(
                "store_recovery.reason_storage_full",
                comment: "Device out of storage"
            )
        case .migrationIncompatible:
            return NSLocalizedString(
                "store_recovery.reason_migration_incompatible",
                comment: "Store schema incompatible with this app version"
            )
        case .corruptOrUnknown:
            return NSLocalizedString(
                "store_recovery.reason_corrupt_or_unknown",
                comment: "Unclassified open failure, data preserved"
            )
        case .protectionVerificationFailed:
            return NSLocalizedString(
                "store_recovery.reason_protection_verification_failed",
                comment: "Store protection could not be verified"
            )
        }
    }
}
