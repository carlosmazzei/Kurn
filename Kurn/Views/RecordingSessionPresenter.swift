//
//  RecordingSessionPresenter.swift
//  Kurn
//
//  Presents the app-wide `RecordingSessionController` from the root of the
//  hierarchy: the full-screen recorder as a sheet while the session is
//  expanded, and a floating Liquid Glass mini bar — status, title, elapsed
//  time, pause/resume and stop — pinned above the bottom safe area while it is
//  minimized, so every other screen stays usable during a recording.
//
//  It lives at the root (`ContentView`) rather than on the screen that started
//  the recording because the mini bar has to outlive that screen: the user can
//  start recording from the list, push a meeting, open the transcript of an
//  earlier one, and come back. For the same reason the intent-driven start
//  (`RecordingLauncher`) is picked up here.
//
//  A screen with a bottom toolbar (the meetings list) hosts the bar itself
//  through `hostsRecordingMiniBar()`: the system toolbar is laid out against
//  the navigation stack's own safe area and ignores an inset added outside it,
//  so a root-level bar sat on top of the toolbar. Inside the screen, the safe
//  area already includes the toolbar, so the bar floats just above it.
//

import Combine
import SwiftUI
import UIKit

extension View {
    /// Attaches the recorder sheet and the minimized mini bar for the
    /// environment's `RecordingSessionController`.
    func recordingSessionPresenter() -> some View {
        modifier(RecordingSessionPresenter())
    }

    /// Shows the mini bar inside this screen's safe area instead of at the
    /// root, for a screen whose bottom toolbar the root bar would cover.
    func hostsRecordingMiniBar() -> some View {
        modifier(HostedRecordingMiniBar())
    }
}

/// How many on-screen views currently host the mini bar themselves; the root
/// presenter draws it only when none does.
@MainActor @Observable
final class RecordingMiniBarPlacement {
    fileprivate var hostCount = 0
    /// The keyboard state, shared so a hosted bar steps aside like the root one.
    fileprivate var isKeyboardVisible = false
}

/// The mini bar as both placements show it.
private struct MiniBarSlot: View {
    @Environment(RecordingSessionController.self) private var session
    @Environment(RecordingMiniBarPlacement.self) private var placement

    var body: some View {
        if let vm = session.viewModel, !session.isExpanded, !placement.isKeyboardVisible {
            RecordingMiniBar(vm: vm, onExpand: { session.expand() })
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct HostedRecordingMiniBar: ViewModifier {
    @Environment(RecordingMiniBarPlacement.self) private var placement
    @State private var isHosting = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isHosting { MiniBarSlot() }
            }
            .onAppear {
                guard !isHosting else { return }
                isHosting = true
                placement.hostCount += 1
            }
            .onDisappear {
                guard isHosting else { return }
                isHosting = false
                placement.hostCount -= 1
            }
    }
}

private struct RecordingSessionPresenter: ViewModifier {
    @Environment(RecordingSessionController.self) private var session
    /// Owned here and handed down so a screen can host the bar itself. The
    /// bar steps aside while the keyboard is up, so it never sits between a
    /// text field (the chat composer, search) and the keyboard.
    @State private var placement = RecordingMiniBarPlacement()

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if placement.hostCount == 0 { MiniBarSlot() }
            }
            .environment(placement)
            .kurnAnimation(.spring(duration: 0.35), value: session.isExpanded)
            .sheet(isPresented: Binding(
                get: { session.isExpanded },
                set: { session.setPresented($0) }
            )) {
                NavigationStack { RecorderView(session: session) }
            }
            // Every way of stopping — the recorder, the mini bar, the Live
            // Activity, the Watch — lands on `didSaveRecording`, and only this
            // modifier is guaranteed to be on screen when it flips.
            .onChange(of: session.viewModel?.didSaveRecording ?? false) { _, saved in
                if saved { session.finishIfSaved() }
            }
            .onChange(of: needsAttention) { _, needs in
                if needs { session.surfaceIfNeeded() }
            }
            // `StartRecordingIntent` (Siri/Shortcuts/Control Center/Action
            // Button) queues a meeting instead of calling into a View; start
            // it exactly like a tap on the record button. `initial: true`
            // covers an intent that ran (e.g. a cold launch through
            // `openAppWhenRun`) before this view first appeared.
            .onChange(of: RecordingLauncher.shared.pendingAutoStartMeeting, initial: true) { _, meeting in
                guard meeting != nil, let next = RecordingLauncher.shared.consumePendingAutoStart() else { return }
                session.begin(meeting: next)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                placement.isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                placement.isKeyboardVisible = false
            }
    }

    private var needsAttention: Bool {
        guard let vm = session.viewModel else { return false }
        return vm.error != nil || vm.permissionDenied
    }
}

/// The minimized recorder: a floating glass capsule. Tapping its body expands
/// the full recorder; pause/resume and stop work in place, so the common
/// mid-meeting actions never need the full screen.
struct RecordingMiniBar: View {
    let vm: RecorderViewModel
    let onExpand: () -> Void

    /// The round controls are fixed geometry, so they scale from their own
    /// base and the subtree caps Dynamic Type, like `RecorderView`.
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = 40

    private var isPaused: Bool { vm.state == .paused }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onExpand) {
                HStack(spacing: 12) {
                    statusIndicator
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.meetingTitle)
                            .font(Theme.subheadlineEmphasized)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(statusText)
                            .font(Theme.caption)
                            .foregroundStyle(isPaused ? Theme.warning : Theme.accent)
                    }
                    Spacer(minLength: 8)
                    Text(vm.elapsed.clockDisplay)
                        .font(Theme.subheadlineEmphasized)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(
                format: NSLocalizedString(
                    "recorder.mini.accessibility_label",
                    comment: "Mini recorder bar: status, meeting title, elapsed time"
                ),
                statusText,
                vm.meetingTitle,
                vm.elapsed.clockDisplay
            ))
            .accessibilityHint(NSLocalizedString("recorder.mini.hint", comment: "Opens the full recorder"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("recorder.mini.expand")

            Button {
                AppLog.recorderUI.atInfo.info("UI: mini bar pause/resume tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.togglePause()
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(Theme.bodyEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: controlSize, height: controlSize)
                    .background(Theme.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused
                ? NSLocalizedString("recorder.resume", comment: "Resume")
                : NSLocalizedString("recorder.pause", comment: "Pause"))
            .accessibilityIdentifier("recorder.mini.pause")

            Button {
                AppLog.recorderUI.atInfo.info("UI: mini bar stop tapped, state=\(String(describing: vm.state), privacy: .public)")
                vm.stopAndSave()
            } label: {
                Image(systemName: "stop.fill")
                    .font(Theme.bodyEmphasized)
                    .foregroundStyle(.white)
                    .frame(width: controlSize, height: controlSize)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("recorder.stop", comment: "Stop"))
            .accessibilityIdentifier("recorder.mini.stop")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .glassEffect(.regular.interactive(), in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sensoryFeedback(.selection, trigger: vm.state)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        // Shape as well as colour: a pulsing dot while recording, a pause
        // glyph while paused, so the state never reads by colour alone.
        if isPaused {
            Image(systemName: "pause.circle.fill")
                .font(Theme.bodyEmphasized)
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
        } else {
            PulsingDot(color: Theme.accent)
                .accessibilityHidden(true)
        }
    }

    private var statusText: String {
        isPaused
            ? NSLocalizedString("recorder.mini.paused", comment: "Mini recorder bar: paused")
            : NSLocalizedString("recorder.mini.recording", comment: "Mini recorder bar: recording")
    }
}
