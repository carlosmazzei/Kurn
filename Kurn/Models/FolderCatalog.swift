//
//  FolderCatalog.swift
//  Kurn
//
//  Curated palettes used by `FolderFormView` to keep folder creation
//  fast and visually consistent. Free-form text input for SF Symbol names or
//  arbitrary hex values is intentionally avoided so a typo can't leave a row
//  rendering as `?` in the sidebar.
//

import Foundation

/// Curated list of SF Symbol names safe to use as folder icons. The first
/// entry matches the `Folder` model's default so creating a folder without
/// customising the icon picks this one.
enum FolderIconCatalog {
    static let `default` = "folder.fill"

    static let icons: [String] = [
        "folder.fill",
        "briefcase.fill",
        "house.fill",
        "person.2.fill",
        "graduationcap.fill",
        "heart.fill",
        "star.fill",
        "book.fill",
        "doc.fill",
        "bookmark.fill",
        "bag.fill",
        "airplane",
        "car.fill",
        "gift.fill",
        "camera.fill",
        "pin.fill",
        "flag.fill",
        "tag.fill"
    ]
}

/// Curated hex palette used by the folder colour swatch row. The first entry
/// matches the `Folder` model's default colour.
enum FolderColorPalette {
    static let `default` = "#5E5CE6"

    static let colors: [String] = [
        "#5E5CE6", // indigo (default)
        "#FF3B30", // red
        "#FF9500", // orange
        "#FFCC00", // yellow
        "#34C759", // green
        "#00C7BE", // teal
        "#007AFF", // blue
        "#AF52DE", // purple-pink
        "#8E8E93"  // gray
    ]
}
