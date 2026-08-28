//
//  SecurityCoverWindow.swift
//  Kurn
//
//  Hosts the security cover in a dedicated `UIWindow` above everything the app
//  presents.
//
//  The gate used to work by swapping a view branch inside `MeetingsListView`,
//  which conflated "what is visible" with "what exists in the hierarchy": every
//  sheet attached to the branch was destroyed on lock. That made protecting
//  content and preserving the user's work mutually exclusive — keeping a sheet
//  inside the branch protected the transcript but discarded an in-progress
//  Settings edit, and moving it out preserved the edit but left the transcript
//  on screen. A window sidesteps the trade entirely: nothing is torn down, and
//  a higher window level covers what an in-hierarchy overlay cannot — pushed
//  destinations, presented sheets, and sheets presented from those sheets.
//
//  Two system windows deliberately still sit above this one, and both are
//  required: the biometric/passcode prompt (drawn by another process entirely)
//  and the keyboard, without which the Settings escape hatch could not be typed
//  into.
//

import KurnCore
import SwiftData
import SwiftUI
import UIKit

private extension ScenePhase {
    /// One-line mapping to KurnCore's portable stand-in, so
    /// `SecurityCoverState.resolve` never needs to import SwiftUI.
    var kurnLifecyclePhase: AppLifecyclePhase {
        switch self {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .background
        }
    }
}

/// Owns the cover window's lifecycle. Not `@Observable`: it is driven from the
/// outside by `securityCover(...)`, which recomputes the state from the scene
/// phase and the gate.
@MainActor
final class SecurityCoverWindow {
    /// The most recent thing asked of the cover. Retained because the request
    /// can arrive before the scene does: at cold launch the first state is
    /// resolved while the view tree is still being laid out, so `didMoveToWindow`
    /// has not run yet. Without replaying it, a launch straight into `.locked`
    /// would leave the app uncovered.
    private struct Request {
        let state: SecurityCoverState
        let gate: RecordingAccessGate
        let settings: AppSettings
        let downloads: ModelDownloadController
        let modelContainer: ModelContainer
    }

    private var window: UIWindow?
    private var host: UIHostingController<SecurityCoverView>?
    private var scene: UIWindowScene?
    private var request: Request?

    nonisolated init() {}

    /// Adopt the scene the app is actually running in, then honour whatever was
    /// last asked for. A window belongs to one scene, so any window built for a
    /// previous one is discarded.
    func adopt(scene newScene: UIWindowScene) {
        guard scene !== newScene else { return }
        scene = newScene
        window?.isHidden = true
        window = nil
        host = nil
        apply()
    }

    /// Show, update, or hide the cover. Hiding is `isHidden` rather than a
    /// teardown so the next lock is instant and the hosted view's state (an
    /// open Settings escape hatch, say) is not rebuilt underneath the user.
    func update(
        state: SecurityCoverState,
        gate: RecordingAccessGate,
        settings: AppSettings,
        downloads: ModelDownloadController,
        modelContainer: ModelContainer
    ) {
        request = Request(
            state: state,
            gate: gate,
            settings: settings,
            downloads: downloads,
            modelContainer: modelContainer
        )
        apply()
    }

    private func apply() {
        guard let request else { return }
        guard request.state.isCovering else {
            window?.isHidden = true
            return
        }
        guard let scene else { return }

        let content = SecurityCoverView(
            state: request.state,
            gate: request.gate,
            settings: request.settings,
            downloads: request.downloads,
            modelContainer: request.modelContainer
        )

        if let host {
            host.rootView = content
        } else {
            let controller = UIHostingController(rootView: content)
            let coverWindow = UIWindow(windowScene: scene)
            coverWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            coverWindow.rootViewController = controller
            host = controller
            window = coverWindow
        }

        // Only the lock screen takes key status; see `needsKeyWindow`.
        if request.state.needsKeyWindow {
            window?.makeKeyAndVisible()
        } else {
            window?.isHidden = false
        }
    }
}

/// Reports the scene this view tree is running in. `didMoveToWindow` is the
/// precise moment the window (and therefore the scene) becomes known — reading
/// it from `UIApplication.shared.connectedScenes` would be a guess, and one
/// that gets less safe if the app ever supports more than one scene.
private struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneCaptureView {
        let view = SceneCaptureView()
        view.isUserInteractionEnabled = false
        view.onScene = onScene
        return view
    }

    func updateUIView(_ uiView: SceneCaptureView, context: Context) {
        uiView.onScene = onScene
    }

    final class SceneCaptureView: UIView {
        var onScene: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            onScene?(scene)
        }
    }
}

private struct SecurityCoverModifier: ViewModifier {
    let gate: RecordingAccessGate
    let settings: AppSettings
    let downloads: ModelDownloadController
    let modelContainer: ModelContainer

    @Environment(\.scenePhase) private var scenePhase
    @State private var cover = SecurityCoverWindow()

    /// Reading both observable inputs here is what makes `onChange` fire when
    /// the gate locks or the user toggles the requirement, not just on a scene
    /// transition.
    private var state: SecurityCoverState {
        .resolve(
            phase: scenePhase.kurnLifecyclePhase,
            requireAuth: settings.requireAuthForRecordings,
            isUnlocked: gate.isUnlocked
        )
    }

    func body(content: Content) -> some View {
        content
            .background(WindowSceneReader { scene in cover.adopt(scene: scene) })
            .onChange(of: state, initial: true) { _, newState in
                cover.update(
                    state: newState,
                    gate: gate,
                    settings: settings,
                    downloads: downloads,
                    modelContainer: modelContainer
                )
            }
    }
}

extension View {
    /// Cover this app's window with the privacy placeholder or the lock screen
    /// as the scene phase and the recordings gate require.
    func securityCover(
        gate: RecordingAccessGate,
        settings: AppSettings,
        downloads: ModelDownloadController,
        modelContainer: ModelContainer
    ) -> some View {
        modifier(
            SecurityCoverModifier(
                gate: gate,
                settings: settings,
                downloads: downloads,
                modelContainer: modelContainer
            )
        )
    }
}
