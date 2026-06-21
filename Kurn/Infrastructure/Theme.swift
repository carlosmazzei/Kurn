//
//  Theme.swift
//  Kurn
//
//  Design-system tokens derived from the iOS design handoff. Colors are adaptive
//  (the handoff specifies the dark-mode palette; light-mode falls back to the
//  matching system materials), so the app honors the system appearance while
//  matching the mock pixel-for-pixel in dark mode.
//

import SwiftUI

enum Theme {
    // MARK: - Palette

    /// App background (behind scroll content). Near-black in dark mode.
    static let background = adaptive(dark: 0x0A0A0F, light: nil, lightSystem: .systemGroupedBackground)
    /// Elevated surface for cards / grouped rows (#1C1C1E in dark).
    static let surface = adaptive(dark: 0x1C1C1E, light: nil, lightSystem: .secondarySystemGroupedBackground)
    /// Subtle fill (chips, icon wells) — translucent white in dark.
    static let fill = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.systemGray5
    })

    /// Brand / record accent.
    static let accent = Color(hex: "#FF3B30")
    static let success = Color(hex: "#32D74B")
    static let info = Color(hex: "#0A84FF")
    static let warning = Color(hex: "#FF9F0A")

    /// Hairline separator matching the mock (rgba(84,84,88,.4) in dark).
    static let separator = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 84/255, green: 84/255, blue: 88/255, alpha: 0.4)
            : UIColor.separator
    })

    // MARK: - Text

    static let textPrimary = Color.primary
    static let textSecondary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.5)
            : UIColor.secondaryLabel
    })
    static let textTertiary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.3)
            : UIColor.tertiaryLabel
    })

    // MARK: - Helpers

    private static func adaptive(dark: Int, light: Int?, lightSystem: UIColor) -> Color {
        Color(uiColor: UIColor { t in
            if t.userInterfaceStyle == .dark { return UIColor(rgb: dark) }
            if let light { return UIColor(rgb: light) }
            return lightSystem
        })
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
