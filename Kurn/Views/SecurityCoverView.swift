//
//  SecurityCoverView.swift
//  Kurn
//
//  Content hosted by the security cover window. Renders the privacy placeholder
//  or the lock screen, and owns the Settings escape hatch.
//
//  The escape hatch has to be presented from here rather than from the app's
//  own hierarchy: the cover window sits above everything, so a Settings sheet
//  presented underneath it would be invisible. It exists for the case where the
//  device has no passcode or biometrics configured — authentication can then
//  never succeed, and without a way into Settings to turn the requirement off
//  the user is locked out of their own library for good.
//
//  Environment is injected explicitly because a separate window's hosting
//  controller inherits nothing from the app's view tree.
//

import KurnCore
import SwiftData
import SwiftUI

struct SecurityCoverView: View {
    let state: SecurityCoverState
    let gate: RecordingAccessGate
    let settings: AppSettings
    let downloads: ModelDownloadController
    let modelContainer: ModelContainer

    /// Drives the escape hatch. Owned here so `LockedRecordingsView` keeps the
    /// same binding-based button it already had.
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            // Painted unconditionally: a hosting controller's view is not
            // reliably opaque, and a cover that lets content show through is
            // not a cover.
            Theme.background.ignoresSafeArea()

            switch state {
            case .hidden:
                EmptyView()
            case .privacy:
                PrivacyCoverView()
            case .locked:
                LockedRecordingsView(gate: gate, showingSettings: $showingSettings)
                    .task { await gate.authenticate() }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
                .environment(settings)
                .environment(downloads)
                .modelContainer(modelContainer)
        }
        // Drop the escape hatch when the cover stops being the lock screen.
        // The window is only hidden, never rebuilt, so a `true` left behind
        // here would re-present Settings by itself the next time the app locks.
        .onChange(of: state) { _, newState in
            if newState != .locked { showingSettings = false }
        }
    }
}
