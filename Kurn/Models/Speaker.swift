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
    /// L2-normalized mean speaker embedding, as raw `Float32` bytes
    /// (`VectorData`). `nil` when the diarizer that ran produced none — the
    /// heuristic engine, or a transcript from before this field existed.
    ///
    /// This is what makes the row an identity rather than a label. `label` is
    /// reassigned in order of first appearance on every diarization run, so a
    /// re-transcription can rename the same person from "Speaker 2" to
    /// "Speaker 1" — and the name the user typed has to follow the voice, not
    /// the number. Defaulted, like `Recording.fileSize`, so SwiftData migrates
    /// the store lightly rather than needing a migration plan.
    ///
    /// It lives in the store rather than in a sidecar file so it inherits the
    /// store's file protection, like every other meeting-derived vector.
    var voiceprintData: Data?

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        label: String,
        name: String = "",
        color: String,
        voiceprintData: Data? = nil
    ) {
        self.id = id
        self.meeting = meeting
        self.label = label
        self.name = name
        self.color = color
        self.voiceprintData = voiceprintData
    }

    /// The stored voiceprint, or `nil` when there is none to compare against.
    var voiceprint: [Float]? {
        guard let voiceprintData else { return nil }
        let vector = VectorData.decode(voiceprintData)
        return vector.isEmpty ? nil : vector
    }

    /// Falls back to the auto label when the user hasn't named the speaker.
    var displayName: String {
        name.isEmpty ? label : name
    }
}
