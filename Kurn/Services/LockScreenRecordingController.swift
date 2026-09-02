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
    // H8 PR 18: was `nonisolated(unsafe)`. The whole type is already
    // `@MainActor`, and every read/write site (`start`, `update`, `end`) is
    // inside a `Task { }`/`Task { @MainActor in }` created from a
    // `@MainActor` method — which inherits `@MainActor` isolation by
    // default, not `.detached` — so access was already serialized through
    // the main actor before this change; the annotation wasn't protecting
    // anything the actor didn't already guarantee.
    private var activity: Activity<RecordingActivityAttributes>?

    private var title = ""
    private var state: AudioRecorderService.State = .idle
    private var elapsed: TimeInterval = 0
    private var highlightCount = 0
    private var isActive = false

    func start(
        title: String,
        state: AudioRecorderService.State,
        elapsed: TimeInterval,
        highlightCount: Int
    ) {
        self.title = title
        self.state = state
        self.elapsed = elapsed
        self.highlightCount = highlightCount
        self.isActive = true

        let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        AppLog.recorderUI.atNotice.notice("LockScreenRecordingController: start requested, activitiesEnabled=\(activitiesEnabled, privacy: .public)")
        guard activitiesEnabled else { return }

        Task {
            do {
                let attributes = RecordingActivityAttributes(meetingTitle: title)
                let content = ActivityContent(
                    state: contentState(state: state, elapsed: elapsed, highlightCount: highlightCount),
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

    func update(state: AudioRecorderService.State, elapsed: TimeInterval, highlightCount: Int) {
        guard isActive else { return }

        self.state = state
        self.elapsed = elapsed
        self.highlightCount = highlightCount

        AppLog.recorderUI.atDebug.debug("LockScreenRecordingController: update state=\(String(describing: state), privacy: .public)")

        let content = ActivityContent(
            state: contentState(state: state, elapsed: elapsed, highlightCount: highlightCount),
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
            state: contentState(state: .idle, elapsed: elapsed, highlightCount: highlightCount),
            staleDate: nil
        )

        title = ""
        state = .idle
        elapsed = 0
        highlightCount = 0
        isActive = false

        Task { @MainActor in
            await self.activity?.end(finalContent, dismissalPolicy: .immediate)
            self.activity = nil
        }
    }

    private func contentState(
        state: AudioRecorderService.State,
        elapsed: TimeInterval,
        highlightCount: Int
    ) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            isPaused: state != .recording,
            elapsed: elapsed,
            referenceDate: Date(),
            highlightCount: highlightCount
        )
    }
}
