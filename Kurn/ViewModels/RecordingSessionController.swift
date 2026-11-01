//
//  RecordingSessionController.swift
//  Kurn
//
//  The one live recording session, owned for the life of the process rather
//  than by the screen that shows it. `RecorderView` used to construct its own
//  `RecorderViewModel` in `onAppear` and hold it in `@State`, which tied the
//  capture to the sheet: the sheet could not be dismissed mid-recording
//  (`interactiveDismissDisabled`), so the rest of the app was unreachable for
//  as long as a meeting lasted.
//
//  Lifting the view model here is what lets the recorder be *minimized*: the
//  full-screen controls collapse into the floating mini bar
//  (`RecordingSessionPresenter`) while capture, the Live Activity, the Watch
//  and `RecordingCommandRouter` carry on untouched, because none of them ever
//  depended on the view being on screen. The start (`prepareToRecord`) runs
//  in a task owned here too, so dismissing the view can no longer cancel it.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RecordingSessionController {
    /// The meeting being recorded into, `nil` when no session exists.
    private(set) var meeting: Meeting?
    /// The live session's view model, `nil` when no session exists.
    private(set) var viewModel: RecorderViewModel?
    /// Whether the full-screen recorder is presented. `false` with a live
    /// session means it is minimized to the mini bar.
    private(set) var isExpanded = false

    private let modelContext: ModelContext
    private let makeViewModel: @MainActor (Meeting, ModelContext) -> RecorderViewModel
    private let prepare: @MainActor (RecorderViewModel) async -> Void
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// - Parameters:
    ///   - makeViewModel: builds the session's view model; the production
    ///     default reads the recording preferences from `settings` at the
    ///     moment the session begins, exactly as `RecorderView` used to.
    ///   - prepare: starts capture; a seam so tests never touch the
    ///     microphone or `AVAudioSession`.
    init(
        modelContext: ModelContext,
        settings: AppSettings,
        makeViewModel: (@MainActor (Meeting, ModelContext) -> RecorderViewModel)? = nil,
        prepare: @escaping @MainActor (RecorderViewModel) async -> Void = { await $0.prepareToRecord() }
    ) {
        self.modelContext = modelContext
        if let makeViewModel {
            self.makeViewModel = makeViewModel
        } else {
            self.makeViewModel = { meeting, context in
                RecordingSessionController.defaultViewModel(meeting: meeting, modelContext: context, settings: settings)
            }
        }
        self.prepare = prepare
    }

    var isActive: Bool { viewModel != nil }

    /// Whether the live session is paused — the record buttons that re-open
    /// a running session say "Paused" rather than "Recording" then.
    var isPaused: Bool { viewModel?.state == .paused }

    /// Whether the recorder may collapse into the mini bar. Only once capture
    /// is actually running: before that the screen may still be asking which
    /// microphone to use or reporting a permission denial, and a minimized
    /// session with nothing recording would be a mini bar for nothing.
    var canMinimize: Bool {
        guard let viewModel else { return false }
        return viewModel.state != .idle && !viewModel.isStarting && viewModel.micChoices.isEmpty
    }

    /// Whether `meeting` is the one being recorded into.
    func isRecording(into meeting: Meeting) -> Bool {
        self.meeting?.id == meeting.id
    }

    /// Starts a session recording into `meeting` and presents the recorder.
    /// When a session already exists — into this meeting or another — it is
    /// brought back to full screen instead: there is one microphone, so a
    /// second concurrent capture is never started. Returns whether a new
    /// session was started.
    @discardableResult
    func begin(meeting: Meeting) -> Bool {
        guard viewModel == nil else {
            isExpanded = true
            return false
        }
        let viewModel = makeViewModel(meeting, modelContext)
        self.meeting = meeting
        self.viewModel = viewModel
        isExpanded = true
        startTask = Task { await self.prepare(viewModel) }
        return true
    }

    /// Collapses the recorder into the mini bar, when that is allowed.
    func minimize() {
        guard canMinimize else { return }
        isExpanded = false
    }

    /// Brings the recorder back to full screen.
    func expand() {
        guard isActive else { return }
        isExpanded = true
    }

    /// The presentation binding's setter. A swipe-down dismissal minimizes a
    /// running session; anything else that dismisses the recorder (nothing
    /// should, since dismissal is disabled until `canMinimize`) is treated as
    /// a minimize too, never as a silent discard.
    func setPresented(_ presented: Bool) {
        if presented {
            expand()
        } else if canMinimize {
            isExpanded = false
        }
    }

    /// Brings the recorder forward when it needs the user — an error or a
    /// permission denial is presented by the full-screen recorder, which a
    /// minimized session would otherwise leave invisible.
    func surfaceIfNeeded() {
        guard let viewModel, viewModel.error != nil || viewModel.permissionDenied else { return }
        isExpanded = true
    }

    /// Discards the session: deletes the in-progress recording (if any) and
    /// ends the session.
    func discard() {
        startTask?.cancel()
        viewModel?.cancel()
        end()
    }

    /// Ends the session once the recording has been saved (from the recorder,
    /// the mini bar, the Live Activity or the Watch — all converge on
    /// `RecorderViewModel.didSaveRecording`).
    func finishIfSaved() {
        guard viewModel?.didSaveRecording == true else { return }
        end()
    }

    private func end() {
        startTask = nil
        viewModel = nil
        meeting = nil
        isExpanded = false
    }

    private static func defaultViewModel(
        meeting: Meeting,
        modelContext: ModelContext,
        settings: AppSettings
    ) -> RecorderViewModel {
        RecorderViewModel(
            meeting: meeting,
            modelContext: modelContext,
            defaultMode: settings.transcriptionEngine.storageMode,
            options: RecorderOptions(
                micPickup: settings.micPickup,
                audioQuality: settings.audioQuality,
                alwaysUseBuiltInMic: settings.alwaysUseBuiltInMic,
                liveTranscriptionEnabled: settings.liveTranscriptionEnabled,
                liveTranscriptionModelsConsented: settings.selectedFluidAudioLiveModelsConsented,
                largeTransferPolicy: settings.largeTransferPolicy,
                hideLiveActivityMeetingTitle: settings.hideLiveActivityMeetingTitle,
                liveTranscriptionModel: settings.fluidAudioLiveModel
            ),
            onRecordingSaved: { [weak settings] in settings?.recordRecordingCompleted() }
        )
    }
}
