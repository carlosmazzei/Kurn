//
//  SmartFolder.swift
//  Kurn
//
//  A saved, reusable filter that behaves like a folder: it does not own
//  meetings, but dynamically lists every meeting that matches its predicate.
//  Matches the "Smart Mailboxes" / Otter Smart Search pattern.
//

import Foundation
import SwiftData

@Model
final class SmartFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    /// SF Symbol shown in the sidebar.
    var iconName: String
    /// Hex color shown in the sidebar.
    var colorHex: String
    /// JSON-encoded `MeetingFilter`.
    private var predicateData: Data = Data()
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "sparkles.square.fill.on.square",
        colorHex: String = FolderColorPalette.default,
        filter: MeetingFilter = MeetingFilter(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.predicateData = JSONStorage.encode(filter)
        self.createdAt = createdAt
    }

    /// The decoded filter predicate.
    var filter: MeetingFilter {
        get { JSONStorage.decode(MeetingFilter.self, from: predicateData) ?? MeetingFilter() }
        set { predicateData = JSONStorage.encode(newValue) }
    }

    /// Meetings from the provided list that match the saved predicate.
    func meetings(matching source: [Meeting]) -> [Meeting] {
        source.filter { filter.matches($0) }
    }
}
