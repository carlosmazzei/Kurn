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
//  Stop also ends the Live Activity here, before `perform()` returns. The
//  recorder's own `LockScreenRecordingController.end()` runs in an
//  unstructured task, and once capture stops nothing keeps a backgrounded app
//  running: iOS can suspend it as soon as the intent returns, before that task
//  runs, leaving the activity on the Lock Screen with its timer still counting
//  over a recording that has already stopped.
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
/// extension's process, where there is no recorder to reach.
enum RecordingControlRouting {
    @MainActor static var handler: ((RecordingControlAction) -> Void)?
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
        RecordingControlRouting.handler?(action)
        if action == .stop {
            await Self.endRecordingActivities()
        }
        return .result()
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
