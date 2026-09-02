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
    // H8 PR 18 audit: this `nonisolated(unsafe)` was checked and kept, not
    // removed. The whole type is `@MainActor` and every access site is
    // already serialized through it (`start`/`update`/`end` all run inside
    // a `Task { }`/`Task { @MainActor in }` that inherits the creating
    // method's `@MainActor` isolation, not `.detached`), so the annotation
    // was never guarding against real concurrent *access* — but removing it
    // fails the build: `Activity<T>.update(_:)`/`.end(_:dismissalPolicy:)`
    // are `nonisolated` async methods in ActivityKit's own API, and passing
    // a main-actor-isolated value into a `nonisolated` call is exactly what
    // Swift 6's region-based "sending" check exists to catch, regardless of
    // whether the value is genuinely raced on. Confirmed by CI, which is
    // the point of this audit item: this one is load-bearing, kept as-is.
    private nonisolated(unsafe) var activity: Activity<RecordingActivityAttributes>?

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
