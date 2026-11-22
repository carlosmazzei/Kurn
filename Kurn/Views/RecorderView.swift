//
//  RecorderView.swift
//  Kurn
//
//  Full-screen recorder: pulsing record control, live waveform meter, elapsed
//  timer, pause/resume, and stop-and-save. Recording is offline-first; the file
//  is written to Documents as it records. The session behind it is app-wide
//  (`RecordingSessionController`), so the screen can be minimized into the
//  floating mini bar and expanded again without touching the capture.
//

import Combine
import os
import SwiftData
import SwiftUI

struct RecorderView: View {
    /// The live session; this view only presents it. Capture outlives the
    /// view, so dismissing the screen minimizes the recording into the mini
    /// bar (`RecordingSessionPresenter`) rather than abandoning it.
    let session: RecordingSessionController

    var body: some View {
        Group {
            if let vm = session.viewModel {
                RecorderContent(vm: vm, session: session)
            } else {
                ProgressView()
            }
        }
        // Locked for the whole screen, not just the photo sheet: this is a
        // fixed immersive layout with no landscape variant, and rotating
        // mid-recording only invited the photo sheet's camera preview to
        // come up sideways. See `AppOrientationLock`'s header.
        .onAppear { AppOrientationLock.shared.lockToPortrait() }
        .onDisappear { AppOrientationLock.shared.unlock() }
    }
}

private struct RecorderContent: View {
    @Bindable var vm: RecorderViewModel
    let session: RecordingSessionController

    @State private var levels: [Float] = Array(repeating: 0, count: 40)
    @State private var showingPhotoCapture = false
    @Environment(\.openURL) private var openURL
    /// Fixed 20 Hz drive for the waveform scroll — the same cadence as the
    /// recorder's metering tick.
    private let waveformClock = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    /// The timer digits have no standard `TextStyle` at this size, so they scale
    /// from their own base rather than a semantic `Theme` font.
    @ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 64

    var body: some View {
        ZStack {
            // Immersive black backdrop with a soft red glow, per the design mock.
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [Theme.record.opacity(0.12), .clear],
                center: .center, startRadius: 0, endRadius: 260
            )
            .ignoresSafeArea()
            .opacity(vm.state == .recording ? 1 : 0.4)

            if vm.permissionDenied {
                permissionDeniedContent
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    headerLine
                    titleField
                        .padding(.top, 8)
                    startingIndicator
                    timer
                        .padding(.top, 14)
                    statusLine
                        .padding(.top, 8)
                    waveform
                        .padding(.top, 20)
                    liveTranscriptArea
                        .padding(.top, 16)
                    routeMessage
                    Spacer()
                    controls
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        // This screen is a fixed, immersive layout (58pt transport buttons,
        // a hand-tuned timer size) rather than a scrolling list of text, so —
        // unlike the rest of the app — it caps how far Dynamic Type can grow
        // instead of scaling without bound.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .navigationTitle(NSLocalizedString("recorder.title", comment: "Record"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                // `cancel()` deletes the in-progress recording once one
                // exists, so the label and role must say so — a plain
                // "Cancel" here would misrepresent a destructive action as a
                // no-op dismiss, unlike every other exit affordance in the app.
                let hasRecordingInProgress = vm.state != .idle || vm.isStarting
                Button(
                    hasRecordingInProgress
                        ? NSLocalizedString("recorder.discard", comment: "Discard the in-progress recording")
                        : NSLocalizedString("common.cancel", comment: "Cancel"),
                    role: hasRecordingInProgress ? .destructive : .cancel
                ) {
                    session.discard()
                }
                // Collapses the recorder into the floating mini bar so the
                // rest of the app stays usable while capture continues.
                Button {
                    session.minimize()
                } label: {
                    Image(systemName: "chevron.down")
                        .accessibilityLabel(NSLocalizedString("recorder.minimize", comment: "Minimize the recorder"))
                }
                .disabled(!session.canMinimize)
                .accessibilityIdentifier("recorder.minimize")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Photo — a photo needs an active recording to attach its
                // timestamp to (see `AudioRecorderService.registerPhoto`).
                Button {
                    AppLog.recorderUI.atInfo.info("UI: photo tapped, state=\(String(describing: vm.state), privacy: .public)")
                    showingPhotoCapture = true
                } label: {
                    Image(systemName: "camera")
                        .accessibilityLabel(NSLocalizedString("recorder.photo", comment: "Photo"))
                }
                .disabled(vm.state != .recording)
                .accessibilityShowsLargeContentViewer {
                    Label(NSLocalizedString("recorder.photo", comment: "Photo"), systemImage: "camera")
                }

                // Highlight. Marking during a pause has no "current instant"
                // to capture (mirrors `markHighlight()`'s guard).
                Button {
                    AppLog.recorderUI.atInfo.info("UI: highlight tapped, state=\(String(describing: vm.state), privacy: .public)")
                    vm.markHighlight()
                } label: {
                    Image(systemName: "flag")
                        .accessibilityLabel(NSLocalizedString("recorder.highlight", comment: "Highlight"))
                }
                .disabled(vm.state != .recording)
                .sensoryFeedback(.success, trigger: vm.highlightCount)
                .accessibilityShowsLargeContentViewer {
                    Label(NSLocalizedString("recorder.highlight", comment: "Highlight"), systemImage: "flag")
                }
            }
        }
        // The backdrop is a fixed immersive black, so pin the whole screen —
        // including the glass navigation bar — to the dark appearance rather
        // than letting it render light chrome over black in light mode.
        .preferredColorScheme(.dark)
        // Scroll on a fixed clock rather than on level *changes*: the
        // change-driven path proved able to stall after a background/lock
        // round-trip (frozen bars) even while capture continued. A clocked
        // pull of the current level can't freeze while the view is on screen.
        .onReceive(waveformClock) { _ in
            guard vm.state == .recording else { return }
            levels.removeFirst()
            levels.append(vm.level)
        }
        .confirmationDialog(
            NSLocalizedString("recorder.choose_mic.title", comment: "Choose microphone"),
            isPresented: Binding(
                get: { !vm.micChoices.isEmpty },
                set: { isPresented in
                    if !isPresented { vm.chooseMic(uid: nil) }
                }
            ),
            titleVisibility: .visible
        ) {
            ForEach(vm.micChoices) { option in
                Button(option.name) { vm.chooseMic(uid: option.id) }
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {
                vm.chooseMic(uid: nil)
            }
        }
        .errorAlert(Binding(
            get: { vm.error },
            set: { newValue in
                if let newValue {
                    vm.error = newValue
                } else {
                    vm.dismissError()
                }
            }
        ))
        // Swiping the sheet down minimizes a running recording (the
        // presentation binding routes it to `session.setPresented`); until
        // capture is running there is nothing to minimize into.
        .interactiveDismissDisabled(!session.canMinimize)
        .fullScreenCover(isPresented: $showingPhotoCapture) {
            PhotoCaptureView { data in
                vm.capturePhoto(jpegData: data)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var startingIndicator: some View {
        if vm.isStarting {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text(NSLocalizedString("recorder.connecting", comment: "Setting up the microphone before recording starts"))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var timer: some View {
        let content = VStack(spacing: 4) {
            Text(vm.elapsed.clockDisplay)
                .font(.system(size: timerFontSize, weight: .ultraLight, design: .default))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            if vm.highlightCount > 0 {
                Label("\(vm.highlightCount)", systemImage: "bookmark.fill")
                    .font(Theme.footnoteEmphasized)
                    .foregroundStyle(Theme.warning)
                    .contentTransition(.numericText())
            }
        }
        // Elapsed time and highlight count used to be two separate VoiceOver
        // stops; combined into one composed phrase (e.g. "12:34, 2
        // highlights") instead of leaving them as unrelated elements.
        if vm.highlightCount > 0 {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(timerAccessibilityLabel)
        } else {
            content
        }
    }

    private var timerAccessibilityLabel: String {
        String(
            format: NSLocalizedString(
                "recorder.accessibility.timer_with_highlights",
                comment: "Elapsed time, highlight count"
            ),
            vm.elapsed.clockDisplay,
            vm.highlightCount
        )
    }

    private var titleField: some View {
        TextField(
            "",
            text: $vm.meetingTitle,
            prompt: Text(vm.provisionalTitle).foregroundStyle(.white.opacity(0.35))
        )
        .font(.title2.bold())
        .foregroundStyle(.white)
        .tint(Theme.record)
        // Explicit, persistent label — VoiceOver stops reading the
        // placeholder as soon as the field has a value, unlike a label.
        .accessibilityLabel(NSLocalizedString(
            "recorder.title_field.accessibility_label",
            comment: "Meeting title text field (VoiceOver)"
        ))
    }

    @ViewBuilder
    private var liveTranscriptArea: some View {
        if vm.isLiveTranscriptionRequested {
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("recorder.live_caption", comment: "Live transcript caption"))
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.45))
                ScrollView {
                    Text(liveTranscriptText)
                        .font(Theme.subheadline)
                        .foregroundStyle(liveTranscriptColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            .padding(14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var liveTranscriptText: String {
        if vm.isLiveTranscriptionUnavailable {
            return NSLocalizedString("recorder.live_unavailable", comment: "Live transcription unavailable")
        }
        if vm.isLiveTranscriptionLoading {
            return NSLocalizedString("recorder.live_loading", comment: "Preparing live transcription")
        }
        if !vm.livePartialText.isEmpty {
            return vm.livePartialText
        }
        return NSLocalizedString("recorder.live_listening", comment: "Listening…")
    }

    private var liveTranscriptColor: Color {
        if vm.isLiveTranscriptionUnavailable { return Theme.warning }
        return vm.livePartialText.isEmpty ? .white.opacity(0.4) : .white.opacity(0.85)
    }

    @ViewBuilder
    private var routeMessage: some View {
        if let message = vm.routeMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(barColor.opacity(i.isMultiple(of: 3) ? 0.7 : 1))
                    .frame(width: 3, height: max(4, CGFloat(levels[i]) * 56))
            }
        }
        .frame(height: 56)
        .kurnAnimation(.linear(duration: 0.06), value: levels)
        // Purely decorative: the recording state and elapsed time are already
        // announced as text above, and a live level readout at 20 Hz would be
        // noise, not signal, to VoiceOver.
        .accessibilityHidden(true)
    }

    /// Three fixed circles: pause and the mic at 64pt on dark glass, and the
    /// one red control — Stop — larger at 84pt with a thin white ring.
    private var controls: some View {
        HStack(spacing: 28) {
            controlCircle(size: 64, disabled: vm.state == .idle) {
                AppLog.recorderUI.atInfo.info("UI: pause/resume tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.togglePause()
            } label: {
                Image(systemName: vm.state == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(vm.state == .paused
                ? NSLocalizedString("recorder.resume", comment: "Resume")
                : NSLocalizedString("recorder.pause", comment: "Pause"))
            .accessibilityShowsLargeContentViewer {
                Label(
                    vm.state == .paused
                        ? NSLocalizedString("recorder.resume", comment: "Resume")
                        : NSLocalizedString("recorder.pause", comment: "Pause"),
                    systemImage: vm.state == .paused ? "play.fill" : "pause.fill"
                )
            }

            // Stop & save — the only red control on the screen.
            Button {
                AppLog.recorderUI.atInfo.info("UI: stop tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.stopAndSave()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(Theme.record, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 5))
            }
            .buttonStyle(.plain)
            .disabled(vm.state == .idle)
            .accessibilityLabel(NSLocalizedString("recorder.stop", comment: "Stop"))
            .accessibilityIdentifier("recorder.stop")
            .accessibilityShowsLargeContentViewer {
                Label(NSLocalizedString("recorder.stop", comment: "Stop"), systemImage: "stop.fill")
            }

            controlCircle(size: 64, disabled: false) {
                vm.presentMicChoices()
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(NSLocalizedString("recorder.choose_mic.title", comment: "Choose microphone"))
            .accessibilityShowsLargeContentViewer {
                Label(
                    NSLocalizedString("recorder.choose_mic.title", comment: "Choose microphone"),
                    systemImage: "mic"
                )
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(vm.state == .idle ? 0.5 : 1)
    }

    /// The 64pt glass circle shared by the pause and mic controls.
    private func controlCircle<Label: View>(
        size: CGFloat,
        disabled: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: size, height: size)
                .background(.white.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var barColor: Color {
        switch vm.state {
        case .recording: return Theme.record
        case .paused: return Theme.warning
        case .idle: return .white.opacity(0.3)
        }
    }
}

/// A self-contained pulsing dot. Isolating the `repeatForever` animation here
/// keeps it from interacting with the recorder's 20 Hz metering re-renders.
/// Shared with the mini bar (`RecordingMiniBar`).
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                // Reduce Motion: never start the infinite pulse, just render solid.
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

private extension RecorderContent {
    /// "New meeting · <Fri, Nov 21>" — the date the capture started, kept
    /// small and secondary above the editable title.
    private var headerLine: some View {
        Text(String(
            format: NSLocalizedString("recorder.header", comment: "Recorder header with date"),
            vm.recordingStartDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        ))
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.6))
    }

    /// One line under the timer: state word + the input in use. The mic name
    /// comes from the live route, so it follows a mid-recording switch to a
    /// headset.
    private var statusLine: some View {
        HStack(spacing: 8) {
            if vm.state == .recording {
                PulsingDot(color: Theme.record, size: 9)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(vm.state == .paused ? Theme.warning : Theme.record)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            Text(statusLineText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var statusLineText: String {
        let paused = vm.state == .paused
        if let mic = vm.currentMicName {
            return String(
                format: NSLocalizedString(
                    paused ? "recorder.status.paused_with_mic" : "recorder.status.recording_with_mic",
                    comment: "Recorder status with microphone name"
                ),
                mic
            )
        }
        return NSLocalizedString(
            paused ? "recorder.mini.paused" : "recorder.mini.recording",
            comment: "Recorder status"
        )
    }

    /// Replaces the old mic-permission dialog: the screen itself explains
    /// what is missing and offers the system Settings route, with a close
    /// button that discards the (empty) session exactly as the old OK did.
    private var permissionDeniedContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "mic.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
                Text(NSLocalizedString("recorder.permission.title", comment: "Mic permission"))
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text(NSLocalizedString("recorder.permission.message", comment: ""))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text(NSLocalizedString("recorder.permission.open_settings", comment: "Open Settings"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Theme.ink, in: Capsule())
                }
                .padding(.top, 6)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            Button {
                session.discard()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(14)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(NSLocalizedString("common.close", comment: "Close"))
            .padding(10)
        }
    }

}
