//
//  ModelStoreBootViews.swift
//  Kurn
//
//  The two views `KurnApp` renders before a `ModelContainer` exists —
//  `ModelStoreLaunchProgressView` for `.waitingForProtectedData`/`.opening`,
//  `ModelStoreRecoveryView` for `.recoveryRequired`. Both are deliberately
//  store-independent (no `ModelContext`, no `AppSettings`): per
//  docs/resilience-megaplan.md's H2 PR 3 scope, the recovery shell must not
//  depend on the very thing that failed to open, and it never offers a
//  destructive "start fresh" action — only Retry. Backup/restore/salvage is
//  PR 4.
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

/// Shown when the store failed to open. Explains why (one of the four
/// classified reasons) and offers Retry — the only non-destructive recovery
/// action available before PR 4's backup/restore/salvage UI lands.
struct ModelStoreRecoveryView: View {
    let failure: ModelStoreOpenFailure
    let retry: () -> Void

    var body: some View {
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
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
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
        }
    }
}
