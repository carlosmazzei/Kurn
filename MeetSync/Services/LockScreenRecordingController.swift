//
//  LockScreenRecordingController.swift
//  MeetSync
//
//  Owns the ActivityKit lifecycle for an active recording. The Widget Extension
//  renders the Lock Screen / Dynamic Island UI; the app keeps this activity in
//  sync with the recorder state.
//

import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPaused: Bool
        var elapsed: TimeInterval
        var referenceDate: Date
    }

    var meetingTitle: String
}

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

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

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
            } catch {
                activity = nil
            }
        }
    }

    func update(state: AudioRecorderService.State, elapsed: TimeInterval) {
        guard isActive else { return }

        self.state = state
        self.elapsed = elapsed

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
