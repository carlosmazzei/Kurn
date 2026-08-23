//
//  ColorAccessibility.swift
//  Kurn
//
//  VoiceOver reads whatever string an `.accessibilityLabel` provides, and a
//  raw hex code ("#FF3B30") is not a color to a screen reader. `FolderColorPalette`
//  is a small, curated, closed set (see `Models/FolderCatalog.swift`), so a static
//  lookup table of localized names is the right fix — no general hex-to-name
//  inference is needed or attempted.
//

import Foundation

extension FolderColorPalette {
    /// A human-readable, localized name for a color in `FolderColorPalette.colors`,
    /// for use as an `.accessibilityLabel`. Falls back to the raw hex for any value
    /// outside the curated palette, which should not happen in practice since the
    /// picker only ever offers `colors`.
    static func accessibleName(for hex: String) -> String {
        switch hex.uppercased() {
        case "#5E5CE6": return NSLocalizedString("folder.color.indigo", comment: "Indigo")
        case "#FF3B30": return NSLocalizedString("folder.color.red", comment: "Red")
        case "#FF9500": return NSLocalizedString("folder.color.orange", comment: "Orange")
        case "#FFCC00": return NSLocalizedString("folder.color.yellow", comment: "Yellow")
        case "#34C759": return NSLocalizedString("folder.color.green", comment: "Green")
        case "#00C7BE": return NSLocalizedString("folder.color.teal", comment: "Teal")
        case "#007AFF": return NSLocalizedString("folder.color.blue", comment: "Blue")
        case "#AF52DE": return NSLocalizedString("folder.color.purple", comment: "Purple")
        case "#8E8E93": return NSLocalizedString("folder.color.gray", comment: "Gray")
        default: return hex
        }
    }
}

extension TagColorPalette {
    /// Same rationale as `FolderColorPalette.accessibleName(for:)`: `colors` is a
    /// small closed palette (see `Models/Tag.swift`), so a static lookup is enough.
    /// Kept as a separate table rather than sharing `FolderColorPalette`'s, since
    /// the two palettes' hex values don't fully overlap (e.g. the reds differ).
    static func accessibleName(for hex: String) -> String {
        switch hex.uppercased() {
        case "#FF453A": return NSLocalizedString("tag.color.red", comment: "Red")
        case "#FF9500": return NSLocalizedString("tag.color.orange", comment: "Orange")
        case "#FFCC00": return NSLocalizedString("tag.color.yellow", comment: "Yellow")
        case "#34C759": return NSLocalizedString("tag.color.green", comment: "Green")
        case "#5E5CE6": return NSLocalizedString("tag.color.indigo", comment: "Indigo")
        case "#007AFF": return NSLocalizedString("tag.color.blue", comment: "Blue")
        case "#AF52DE": return NSLocalizedString("tag.color.purple", comment: "Purple")
        case "#FF2D55": return NSLocalizedString("tag.color.pink", comment: "Pink")
        case "#8E8E93": return NSLocalizedString("tag.color.gray", comment: "Gray")
        case "#C69F6B": return NSLocalizedString("tag.color.brown", comment: "Brown")
        default: return hex
        }
    }
}
