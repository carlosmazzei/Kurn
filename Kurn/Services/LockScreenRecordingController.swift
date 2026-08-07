//
//  LockScreenRecordingController.swift
//  Kurn
//
//  Owns the ActivityKit lifecycle for an active recording. The Widget Extension
//  renders the Lock Screen / Dynamic Island UI; the app keeps this activity in
//  sync with the recorder state.
//

import ActivityKit
import Foundation

@MainActor
final class LockScreenRecordingController {
    nonisolated(unsafe) private var activity: Activity<RecordingActivityAttributes>?

    private var title = ""
    private var state: AudioRecorderService.State = .idle
    private var elapsed: TimeInterval = 0
    private var isActive = false

    func start(
        title: String,
        state: AudioRecorderService.State,
        elapsed: TimeInterval
    ) {
        self.title = title
        self.state = state
        self.elapsed = elapsed
        self.isActive = true

        let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        AppLog.recorderUI.atNotice.notice("LockScreenRecordingController: start requested, activitiesEnabled=\(activitiesEnabled, privacy: .public)")
        guard activitiesEnabled else { return }

        Task {
            do {
                let attributes = RecordingActivityAttributes(meetingTitle: title)
                let content = ActivityContent(
                    state: contentState(state: state, elapsed: elapsed),
                    staleDate: nil
                )
                activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                AppLog.recorderUI.atNotice.notice("LockScreenRecordingController: Live Activity started")
            } catch {
                AppLog.recorderUI.atError.error("LockScreenRecordingController: Activity.request failed: \(error.localizedDescription, privacy: .public)")
                activity = nil
            }
        }
    }

    func update(state: AudioRecorderService.State, elapsed: TimeInterval) {
        guard isActive else { return }

        self.state = state
        self.elapsed = elapsed

        AppLog.recorderUI.atDebug.debug("LockScreenRecordingController: update state=\(String(describing: state), privacy: .public)")

        let content = ActivityContent(
            state: contentState(state: state, elapsed: elapsed),
            staleDate: nil
        )

        Task { @MainActor in
            await self.activity?.update(content)
        }
    }

    func end() {
        guard isActive else { return }

        AppLog.recorderUI.atNotice.notice("LockScreenRecordingController: end")

        let finalContent = ActivityContent(
            state: contentState(state: .idle, elapsed: elapsed),
            staleDate: nil
        )

        title = ""
        state = .idle
        elapsed = 0
        isActive = false

        Task { @MainActor in
            await self.activity?.end(finalContent, dismissalPolicy: .immediate)
            self.activity = nil
        }
    }

    private func contentState(
        state: AudioRecorderService.State,
        elapsed: TimeInterval
    ) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            isPaused: state != .recording,
            elapsed: elapsed,
            referenceDate: Date()
        )
    }
}
