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

    @MainActor
    static func apply(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if arguments.contains(disableAnimations) {
            UIView.setAnimationsEnabled(false)
        }
    }
}
#endif
