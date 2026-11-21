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
    /// Switches `AppSettings` onto a dedicated UI-testing `UserDefaults` suite
    /// and clears only that suite before launch, so flow tests start from a
    /// fresh install without wiping a developer installation's standard defaults.
    static let resetDefaults = "UI-Testing-ResetDefaults"
    static let isolatedDefaultsSuiteName = "com.kurn.ui-testing-defaults"
    /// Pins the app to `accessibilityExtraExtraExtraLarge` (AX5) via UIKit's
    /// preferred content size category launch argument (U0.2).
    static let accessibilityContentSize = "UI-Testing-AX5"
    /// Pins the app to the standard `large` Dynamic Type category so default-size
    /// baseline runs never inherit a simulator's leftover text size (U0.1).
    static let defaultContentSize = "UI-Testing-DefaultDynamicType"
    private static let contentSizeKey = "-UIPreferredContentSizeCategoryName"
    private static let ax5Value = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
    private static let defaultValue = UIContentSizeCategory.large.rawValue

    @MainActor
    static func apply(arguments: [String] = ProcessInfo.processInfo.arguments) {
        if arguments.contains(disableAnimations) {
            UIView.setAnimationsEnabled(false)
        }
        if arguments.contains(resetDefaults) {
            UserDefaults().removePersistentDomain(forName: isolatedDefaultsSuiteName)
        }
        if arguments.contains(accessibilityContentSize), !arguments.contains(contentSizeKey) {
            UserDefaults.standard.set(ax5Value, forKey: "UIPreferredContentSizeCategoryName")
        } else if arguments.contains(defaultContentSize), !arguments.contains(contentSizeKey) {
            UserDefaults.standard.set(defaultValue, forKey: "UIPreferredContentSizeCategoryName")
        }
    }

    static func settingsDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard arguments.contains(resetDefaults),
              let suite = UserDefaults(suiteName: isolatedDefaultsSuiteName) else {
            return .standard
        }
        suite.addSuite(named: UserDefaults.argumentDomain)
        return suite
    }
}
#endif
