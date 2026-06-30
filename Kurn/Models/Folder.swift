//
//  Folder.swift
//  Kurn
//
//  A user-defined folder that groups meetings. Folders are flat in the UI for
//  now but the model carries a self-relation so subfolders can be enabled later
//  without another schema migration. Built-in library views (All, Inbox,
//  Favorites, Archive) are NOT folders — they live in `MeetingsLibraryBucket`.
//

import Foundation
import SwiftData

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    /// SF Symbol name used by the sidebar list and any future folder chip.
    /// Folder picker defaults this to `"folder.fill"`.
    var iconName: String
    /// Hex string ("#RRGGBB") rendered through `Color(hex:)`. Used to tint the
    /// folder's icon and any folder chip on the meeting card.
    var colorHex: String
    var createdAt: Date

    /// Parent folder for nested folders; `nil` for root-level folders. The
    /// sidebar in this version only shows root folders; subfolder navigation
    /// is planned for a follow-up that polishes the UX.
    var parent: Folder?

    /// Subfolders. `.nullify` so deleting a parent makes children root-level
    /// rather than removing them — destructive cascade here would silently
    /// wipe entire trees on a single user mistake.
    @Relationship(deleteRule: .nullify, inverse: \Folder.parent)
    var children: [Folder] = []

    /// Meetings filed into this folder. `.nullify` so deleting a folder only
    /// detaches its meetings (they fall back to the `Inbox` virtual bucket);
    /// the audio, transcripts, and summaries are preserved.
    @Relationship(deleteRule: .nullify, inverse: \Meeting.folder)
    var meetings: [Meeting] = []

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "folder.fill",
        colorHex: String = "#5E5CE6",
        createdAt: Date = Date(),
        parent: Folder? = nil
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.parent = parent
    }

    /// Whether this folder lives at the root of the folder tree (no parent).
    /// The sidebar drawer only lists roots.
    var isRoot: Bool { parent == nil }
}
