//
//  UITestLaunchOptions.swift
//  Kurn
//
//  Launch arguments only the UI test flows pass. `#if DEBUG` only, compiled
//  out of Release, like the "UI-Testing-Screenshots" seam in `KurnApp`.
//

#if DEBUG
import UIKit

enum UITestLaunchOptions {
    /// Turns off UIKit animations — sheet presentation, navigation pushes,
    /// swipe-action reveals. A tap that lands while one of them is still
    /// running is silently dropped, which is the commonest source of a flow
    /// failing later on an unrelated "element missing"; without them each
    /// transition also stops costing its animation time.
    static let disableAnimations = "UI-Testing-DisableAnimations"
    /// Wipes the app's persistent `UserDefaults` domain before `AppSettings`
    /// loads, so a flow that adds providers or grants consent starts from a
    /// fresh install every run instead of accumulating earlier runs' state.
    static let resetDefaults = "UI-Testing-ResetDefaults"

    @MainActor
    static func apply(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if arguments.contains(disableAnimations) {
            UIView.setAnimationsEnabled(false)
        }
        if arguments.contains(resetDefaults), let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }
}
#endif
