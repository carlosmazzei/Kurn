//
//  RecordingLauncher.swift
//  Kurn
//
//  Reachable, app-wide entry point for starting a recording from outside any
//  SwiftUI view — an App Intent (Siri/Shortcuts), a Control Center control, or
//  the Action Button. `RecorderViewModel`/`AudioRecorderService` are otherwise
//  constructed fresh inside `RecorderView.onAppear`, which only exists once
//  the user has already navigated there; this singleton creates the `Meeting`
//  the same way `MeetingsListToolbar.startRecording()` does and hands it off
//  to `MeetingsListView`, so the intent-triggered start reuses the exact same
//  `RecorderView` sheet, mic-permission flow, Live Activity, and
//  `RecordingCommandRouter` registration as a manual tap on the record button.
//
//  `StartRecordingIntent.perform()` (`Kurn/AppIntents/StartRecordingIntent.swift`)
//  cannot call into this type directly: that file is compiled into both the
//  Kurn and KurnLiveActivityExtension targets, and this type's dependency
//  chain (`MeetingsViewModel`, `Meeting`, `AppSettings`, SwiftData) is not
//  meant to exist in the widget extension. Instead the intent posts a plain
//  `Notification`, which this singleton observes once it is actually running
//  inside the app process — exactly where `openAppWhenRun` guarantees the
//  intent's `perform()` executes.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecordingLauncher {
    static let shared = RecordingLauncher()

    private var modelContext: ModelContext?
    private var settings: AppSettings?

    /// Set by `requestAutoStart()`, observed by `MeetingsListView` to present
    /// `RecorderView` exactly as it would for a manually created meeting.
    private(set) var pendingAutoStartMeeting: Meeting?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .kurnStartRecordingRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAutoStartRequest() }
        }
    }

    /// H8 PR 20, item 8: replies to `StartRecordingIntent.perform()` with
    /// whether the request could actually be queued, so the intent reports
    /// that outcome truthfully instead of assuming success the instant it
    /// posted the request.
    private func handleAutoStartRequest() {
        let accepted = requestAutoStart()
        NotificationCenter.default.post(
            name: .kurnStartRecordingRequestHandled,
            object: nil,
            userInfo: ["accepted": accepted]
        )
    }

    /// Called once from `KurnApp.init()`, alongside the app's other app-wide
    /// coordinators, so this singleton can create a `Meeting` without a View
    /// ever having to hand it a `ModelContext`.
    func configure(modelContext: ModelContext, settings: AppSettings) {
        self.modelContext = modelContext
        self.settings = settings
    }

    /// Create a meeting to record into and queue it for `MeetingsListView` to
    /// present. A no-op while a recording is already in progress, so a
    /// double-invocation (e.g. tapping the control twice) doesn't create a
    /// second `Meeting` — still a legitimate "accepted" outcome, not a
    /// failure, since the request's intent (a recording being in progress)
    /// already holds. Returns `false` only when the app genuinely couldn't
    /// act on the request — `configure()` hasn't run yet, a cold-launch race
    /// `StartRecordingIntent` needs to report truthfully rather than assume
    /// (H8 PR 20, item 8).
    @discardableResult
    func requestAutoStart() -> Bool {
        guard !RecordingCommandRouter.shared.hasActiveSession else { return true }
        guard let modelContext, let settings else {
            AppLog.recorderUI.atError.error("RecordingLauncher: auto-start requested before configure() ran")
            return false
        }
        let viewModel = MeetingsViewModel(modelContext: modelContext)
        pendingAutoStartMeeting = viewModel.createMeeting(title: "", language: settings.defaultLanguage)
        return true
    }

    /// Consumes the pending meeting so it is only presented once.
    func consumePendingAutoStart() -> Meeting? {
        defer { pendingAutoStartMeeting = nil }
        return pendingAutoStartMeeting
    }
}
