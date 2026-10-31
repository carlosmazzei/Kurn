//
//  RecordingControlIntent.swift
//  Kurn
//
//  The Live Activity's pause/resume, stop and highlight buttons. Compiled into
//  both the Kurn and KurnLiveActivityExtension targets, like
//  `StartRecordingIntent`, so the widget can reference it in `Button(intent:)`.
//
//  These buttons used to be `Link`s to `kurn://recording/...`. A custom URL
//  scheme is public: any app can open it, and any web page can after Safari's
//  confirmation, so anything on the device could stop or pause a meeting
//  being recorded. An App Intent is reachable only from the surfaces the
//  system wires it to (here, the Live Activity), and `isDiscoverable = false`
//  keeps it out of Shortcuts and Spotlight.
//
//  A `LiveActivityIntent` that is a member of the app target runs in the app's
//  process, so `perform()` reaches the live recorder through
//  `RecordingControlRouting.handler`, which `KurnApp` installs at launch. The
//  hook exists for the same reason `StartRecordingIntent` posts a
//  notification: the extension target cannot name `RecordingCommandRouter`.
//
//  Stop and pause also update the Live Activity here, before `perform()`
//  returns. The recorder's own `LockScreenRecordingController` calls run in
//  unstructured tasks, and once capture stops or pauses nothing may keep a
//  backgrounded app running: iOS can suspend it as soon as the intent returns,
//  before those tasks run, leaving the activity on the Lock Screen with its
//  timer still counting over a recording that has stopped or paused.
//

import ActivityKit
import AppIntents
import Foundation

/// What a Live Activity button asks the recorder to do.
enum RecordingControlAction: String, Sendable, CaseIterable {
    case togglePause
    case stop
    case highlight
}

/// The app-side receiver for `RecordingControlIntent`. `nil` in the widget
/// extension's process, where there is no recorder to reach. Returns whether
/// a live recorder handled the action.
enum RecordingControlRouting {
    @MainActor static var handler: ((RecordingControlAction) -> Bool)?
}

struct RecordingControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "intent.recordingControl.title"
    static let isDiscoverable = false

    @Parameter(title: "intent.recordingControl.action")
    var actionRawValue: String

    init() {
        actionRawValue = RecordingControlAction.togglePause.rawValue
    }

    init(_ action: RecordingControlAction) {
        actionRawValue = action.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let action = RecordingControlAction(rawValue: actionRawValue) else { return .result() }
        // Read before the recorder acts, so a recorder update that lands
        // while this intent awaits cannot be toggled a second time.
        let toggled = Self.currentActivityState()?.togglingPause()
        let handled = RecordingControlRouting.handler?(action) ?? false
        switch action {
        case .stop:
            await Self.endRecordingActivities()
        case .togglePause:
            if handled, let toggled { await Self.updateRecordingActivities(to: toggled) }
        case .highlight:
            break
        }
        return .result()
    }

    private nonisolated static func currentActivityState() -> RecordingActivityAttributes.ContentState? {
        Activity<RecordingActivityAttributes>.activities.first?.content.state
    }

    private nonisolated static func updateRecordingActivities(
        to state: RecordingActivityAttributes.ContentState
    ) async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Ends every recording Live Activity and waits for it, so the activity is
    /// gone before the system may suspend the app. After a stop none of them
    /// has a live recorder behind it, including one a killed process left.
    private nonisolated static func endRecordingActivities() async {
        for activity in Activity<RecordingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
