//
//  AppOrientationLock.swift
//  Kurn
//
//  The app supports portrait and landscape at the `Info.plist` level (for
//  every other screen), but `RecorderView` is a fixed, hand-tuned immersive
//  layout — and its camera photo-capture sheet (`PhotoCaptureView`) draws a
//  raw `AVCaptureVideoPreviewLayer` that never re-derives its rotation angle
//  from a change in interface orientation. Letting the device rotate while
//  either is on screen left the camera preview visibly wrong-side-up instead
//  of just re-laying-out. Since neither screen has a landscape layout to
//  rotate into anyway, both lock the app to portrait for as long as they're
//  presented, via `KurnAppDelegate.application(_:supportedInterfaceOrientationsFor:)`
//  reading this singleton.
//
//  A plain mutable singleton rather than an `@Observable`/environment value:
//  UIKit reads `mask` synchronously from a delegate callback that SwiftUI's
//  environment can't reach, so there is no cleaner seam here.
//

import Foundation
#if canImport(UIKit)
import UIKit

@MainActor
final class AppOrientationLock {
    static let shared = AppOrientationLock()

    private(set) var mask: UIInterfaceOrientationMask = .all
    /// Nested locks (e.g. `PhotoCaptureView` presented from `RecorderView`,
    /// both wanting portrait) must not have the inner one's `unlock()` undo
    /// the outer one's lock.
    private var lockCount = 0

    private init() {}

    func lockToPortrait() {
        lockCount += 1
        mask = .portrait
        requestPortraitGeometryIfNeeded()
    }

    func unlock() {
        lockCount = max(0, lockCount - 1)
        guard lockCount == 0 else { return }
        mask = .all
    }

    private func requestPortraitGeometryIfNeeded() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
            AppLog.recorderUI.atDebug.debug(
                "AppOrientationLock: geometry update failed code=\(error.publicLogCode, privacy: .public)"
            )
        }
    }
}
#endif
