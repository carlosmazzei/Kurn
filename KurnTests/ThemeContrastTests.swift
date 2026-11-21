//
//  ThemeContrastTests.swift
//  KurnTests
//
//  Verifies that `Theme` tokens resolve across light/dark appearances and
//  normal/increased contrast, and that readable text/status/button tokens
//  meet WCAG AA (>= 4.5:1) contrast (U2 / G3).
//

import SwiftUI
import Testing
import UIKit
@testable import Kurn

struct ThemeContrastTests {
    private struct RGBA: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private func traits(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast = .normal) -> UITraitCollection {
        UITraitCollection(mutations: { mutable in
            mutable.userInterfaceStyle = style
            mutable.accessibilityContrast = contrast
        })
    }

    private func rgba(_ color: Color, traits: UITraitCollection) -> RGBA {
        let resolved = UIColor(color).resolvedColor(with: traits)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(red: r, green: g, blue: b, alpha: a)
    }

    private func composite(_ fg: RGBA, over bg: RGBA) -> RGBA {
        let alpha = fg.alpha
        return RGBA(
            red: fg.red * alpha + bg.red * (1 - alpha),
            green: fg.green * alpha + bg.green * (1 - alpha),
            blue: fg.blue * alpha + bg.blue * (1 - alpha),
            alpha: 1
        )
    }

    private func relativeLuminance(_ color: RGBA) -> Double {
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    private func contrastRatio(foreground: Color, background: Color, traits: UITraitCollection) -> Double {
        let bg = rgba(background, traits: traits)
        let fg = composite(rgba(foreground, traits: traits), over: bg)
        let l1 = relativeLuminance(fg)
        let l2 = relativeLuminance(bg)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test func readableTextTokensMeetWCAGAAAcrossAppearancesAndContrastLevels() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let collection = traits(style: style, contrast: contrast)
                let secondaryRatio = contrastRatio(foreground: Theme.textSecondary, background: Theme.surface, traits: collection)
                let tertiaryRatio = contrastRatio(foreground: Theme.textTertiary, background: Theme.surface, traits: collection)
                #expect(secondaryRatio >= 4.5, "textSecondary contrast \(secondaryRatio) < 4.5 for \(style)/\(contrast)")
                #expect(tertiaryRatio >= 4.5, "textTertiary contrast \(tertiaryRatio) < 4.5 for \(style)/\(contrast)")
            }
        }
    }

    @Test func statusAndButtonFillTokensMeetWCAGAAContrast() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let collection = traits(style: style)
            for token in [Theme.accent, Theme.success, Theme.info, Theme.warning] {
                let ratio = contrastRatio(foreground: token, background: Theme.surface, traits: collection)
                #expect(ratio >= 4.5, "status token contrast \(ratio) < 4.5 for \(style)")
            }
            #expect(contrastRatio(foreground: .white, background: Theme.accentFill, traits: collection) >= 4.5)
            #expect(contrastRatio(foreground: .white, background: Theme.infoFill, traits: collection) >= 4.5)
        }
    }

    @Test func chromeTokensBoostUnderIncreaseContrastInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let normal = traits(style: style, contrast: .normal)
            let high = traits(style: style, contrast: .high)

            let fillNormal = rgba(Theme.fill, traits: normal)
            let fillHigh = rgba(Theme.fill, traits: high)
            let sepNormal = rgba(Theme.separator, traits: normal)
            let sepHigh = rgba(Theme.separator, traits: high)
            let decoNormal = rgba(Theme.decorationTertiary, traits: normal)

            if style == .dark {
                #expect(fillHigh.alpha > fillNormal.alpha)
                #expect(sepHigh.alpha > sepNormal.alpha)
                #expect(decoNormal.alpha > 0)
            } else {
                #expect(fillHigh != fillNormal)
                #expect(sepHigh.alpha >= sepNormal.alpha)
                #expect(decoNormal.alpha > 0)
            }
        }
    }
}
