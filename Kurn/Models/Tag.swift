//
//  Tag.swift
//  Kurn
//
//  A user-defined tag that can be attached to many meetings. Tags are a
//  cross-cutting dimension (a meeting has one folder but many tags), matching
//  the pattern used by Plaud/Otter/Fireflies.
//

import Foundation
import SwiftData

@Model
final class Tag {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Hex string ("#RRGGBB") rendered through `Color(hex:)`.
    var colorHex: String
    var createdAt: Date

    /// Meetings that carry this tag. Many-to-many via SwiftData's inverse
    /// relationship. `.nullify` so deleting a tag only detaches it from
    /// meetings; deleting a meeting only detaches it from the tag.
    @Relationship(deleteRule: .nullify, inverse: \Meeting.tags)
    var meetings: [Meeting] = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = TagColorPalette.default,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}

/// Small palette reused for tags so the UI stays consistent without
/// introducing another full color picker.
enum TagColorPalette {
    static let `default` = colors[0]

    static let colors: [String] = [
        "#FF453A", // red
        "#FF9500", // orange
        "#FFCC00", // yellow
        "#34C759", // green
        "#5E5CE6", // indigo
        "#007AFF", // blue
        "#AF52DE", // purple
        "#FF2D55", // pink
        "#8E8E93", // gray
        "#C69F6B"  // brown
    ]
}
