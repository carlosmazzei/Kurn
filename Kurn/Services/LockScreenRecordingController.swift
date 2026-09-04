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

    // H8 PR 19: `start()` used to fire an untracked `Task` that, once
    // scheduled, always ran to completion and unconditionally set
    // `activity` — including after an immediate `end()` had already run,
    // found `activity` still `nil` (the start `Task` hadn't executed yet),
    // and done nothing. `Activity.request` is `throws` but not `async`, so
    // once its `Task` actually starts running there is no `await` between
    // then and `activity = try Activity.request(...)` for anything else to
    // interleave on — the only race is *scheduling order* between the
    // start and end `Task`s themselves, which Swift's concurrency model
    // does not guarantee to match call order for independently-created
    // unstructured tasks. If `end()`'s task happened to run first, the
    // later-running `start()` task would still create a real Live Activity
    // and store it — one `end()` already decided nothing needed ending,
    // so nothing would ever end it: an orphan on the Lock Screen/Dynamic
    // Island until the system eventually evicts it.
    //
    // `runID` closes that hole: every `start()`/`end()` bumps it, and the
    // start task captures the id current when it was scheduled and checks
    // it again — synchronously, with no intervening `await` — right before
    // creating anything. An `end()` that ran first already moved `runID`
    // on, so a start task that (however it got scheduled) runs after it
    // sees the mismatch and skips creating an activity nothing would
    // manage, rather than creating one and only then discovering it's
    // orphaned. `startTask` is retained so `end()` can also explicitly
    // cancel it — belt-and-suspenders alongside `runID`, since a bare
    // `Task.cancel()` can't interrupt `Activity.request` itself (a foreign
    // synchronous call), only signal intent for code that checks it.
    private var runID = UUID()
    private var startTask: Task<Void, Never>?

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
        let id = UUID()
        runID = id

        let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        AppLog.recorderUI.atNotice.notice("LockScreenRecordingController: start requested, activitiesEnabled=\(activitiesEnabled, privacy: .public)")
        guard activitiesEnabled else { return }

        startTask = Task { [weak self] in
            guard let self else { return }
            guard self.runID == id else {
                AppLog.recorderUI.atNotice.notice("LockScreenRecordingController: start superseded before running, skipped")
                return
            }
            do {
                let attributes = RecordingActivityAttributes(meetingTitle: title)
                let content = ActivityContent(
                    state: self.contentState(state: state, elapsed: elapsed, highlightCount: highlightCount),
                    staleDate: nil
                )
                self.activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                AppLog.recorderUI.atNotice.notice("LockScreenRecordingController: Live Activity started")
            } catch {
                AppLog.recorderUI.atError.error("LockScreenRecordingController: Activity.request failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
                self.activity = nil
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
        let id = runID

        Task { @MainActor [weak self] in
            guard let self, self.runID == id else { return }
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
        // Supersedes the current run: a start task still waiting to run
        // will see this and skip creating an activity; `startTask.cancel()`
        // is the same signal for anything that checks `Task.isCancelled`.
        runID = UUID()
        startTask?.cancel()
        startTask = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
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
