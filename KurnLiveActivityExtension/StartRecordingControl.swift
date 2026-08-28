//
//  StartRecordingControl.swift
//  KurnLiveActivityExtension
//
//  A Control Center / Lock Screen / Action Button control that starts a
//  recording via `StartRecordingIntent` (`Kurn/AppIntents/
//  StartRecordingIntent.swift`, compiled into this target too). The intent's
//  `openAppWhenRun = true` means tapping this always launches/foregrounds the
//  app and runs the intent there — this file only needs to describe the
//  control's UI and reference the shared intent type, never touch app state
//  itself, so no App Group is needed.
//
//  Placement (Control Center vs. the Lock Screen's corner slots vs. the
//  Action Button) is entirely the user's choice via system settings; there is
//  no API to restrict a control to a subset of those surfaces. The
//  description text below calls out the Lock Screen placement explicitly so
//  that choice is informed rather than a side effect of adding the control to
//  Control Center.
//

import AppIntents
import SwiftUI
import WidgetKit

struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "ai.kurn.app.control.startRecording"
        ) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("control.startRecording.title", systemImage: "record.circle.fill")
            }
        }
        .displayName("control.startRecording.displayName")
        .description("control.startRecording.description")
    }
}
