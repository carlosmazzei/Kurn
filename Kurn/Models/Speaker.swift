//
//  Speaker.swift
//  Kurn
//
//  A speaker identity within a meeting. The `label` is auto-assigned by the
//  diarizer ("Speaker 1"); `name` is the user-editable display name.
//

import Foundation
import SwiftData

@Model
final class Speaker {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var label: String
    var name: String
    /// Hex color used to tint this speaker in the transcript UI.
    var color: String

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        label: String,
        name: String = "",
        color: String
    ) {
        self.id = id
        self.meeting = meeting
        self.label = label
        self.name = name
        self.color = color
    }

    /// Falls back to the auto label when the user hasn't named the speaker.
    var displayName: String {
        name.isEmpty ? label : name
    }
}
