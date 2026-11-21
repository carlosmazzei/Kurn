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
    /// Pins the app to `accessibilityExtraExtraExtraLarge` (AX5) via UIKit's
    /// preferred content size category launch argument (U0.2).
    static let accessibilityContentSize = "UI-Testing-AX5"
    private static let contentSizeKey = "-UIPreferredContentSizeCategoryName"
    private static let ax5Value = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue

    @MainActor
    static func apply(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if arguments.contains(disableAnimations) {
            UIView.setAnimationsEnabled(false)
        }
        if arguments.contains(accessibilityContentSize), !arguments.contains(contentSizeKey) {
            UserDefaults.standard.set(ax5Value, forKey: "UIPreferredContentSizeCategoryName")
        }
    }
}
#endif
