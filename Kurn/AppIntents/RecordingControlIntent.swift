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
        if let action = RecordingControlAction(rawValue: actionRawValue) {
            RecordingControlRouting.handler?(action)
        }
        return .result()
    }
}
