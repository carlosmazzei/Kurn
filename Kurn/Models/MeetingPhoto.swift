//
//  MeetingPhoto.swift
//  Kurn
//
//  A photo captured mid-recording (the "Plaud-style" photo timeline): a
//  timestamped snapshot of a whiteboard, slide, or document, stored as a
//  JPEG in the protected recordings directory (see `PhotoFileStore`) and
//  referenced here by file name only — the same on-disk pattern
//  `Recording.fileName` uses for its `.m4a`, chosen over an in-store BLOB
//  because there is no precedent in this codebase for binary data inside the
//  SwiftData store (`SemanticChunk.vectorData` stores vectors, not media).
//
//  `capturedAt` is relative to the owning `Recording`'s own timeline, exactly
//  like `Highlight.timestamp` — both are produced by the same
//  `AudioRecorderService` clock during an active recording.
//
//  `recognizedText` is on-device OCR (Vision) run immediately after capture —
//  the single most useful piece of context a meeting photo can carry (a
//  whiteboard or slide's text), extracted with no network call and no
//  consent gate. `photoDescription`/`descriptionProviderID` are reserved for
//  an opt-in cloud image caption (a future, separate feature) and are left
//  unset by the capture path.
//

import Foundation
import SwiftData

@Model
final class MeetingPhoto {
    @Attribute(.unique) var id: UUID
    var recording: Recording?
    /// File name (not absolute path) within the protected photos directory.
    /// Resolved lazily via `PhotoFileStore`, mirroring `Recording.fileName`.
    var fileName: String
    /// Seconds from the start of the *recording* this photo belongs to — the
    /// same reference frame `Highlight.timestamp` uses.
    var capturedAt: TimeInterval
    var createdAt: Date
    /// On-device Vision OCR result, `nil` until extraction runs or when
    /// nothing was recognized.
    var recognizedText: String?
    /// Reserved for an opt-in cloud image caption; unset by the on-device
    /// capture path.
    var photoDescription: String?
    var descriptionProviderID: String?

    init(
        id: UUID = UUID(),
        recording: Recording? = nil,
        fileName: String,
        capturedAt: TimeInterval,
        createdAt: Date = Date(),
        recognizedText: String? = nil,
        photoDescription: String? = nil,
        descriptionProviderID: String? = nil
    ) {
        self.id = id
        self.recording = recording
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.createdAt = createdAt
        self.recognizedText = recognizedText
        self.photoDescription = photoDescription
        self.descriptionProviderID = descriptionProviderID
    }

    /// Absolute URL of the backing image file in the current container.
    var fileURL: URL {
        PhotoFileStore.resolveURL(fileName: fileName)
    }

    /// Whether this photo carries any usable context text for prompts
    /// (resume/wiki/chat) — either the on-device OCR result or a cloud
    /// caption, whichever is present.
    var contextText: String? {
        if let recognizedText, !recognizedText.isEmpty { return recognizedText }
        if let photoDescription, !photoDescription.isEmpty { return photoDescription }
        return nil
    }
}
