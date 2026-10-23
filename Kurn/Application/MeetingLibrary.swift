//
//  MeetingLibrary.swift
//  Kurn
//
//  The library's user-initiated mutations: creating and deleting meetings,
//  recordings, photos, attachments and summaries, and managing tags, folders, smart folders
//  and generated documents.
//
//  These used to be spread across eight Views, each inserting or deleting
//  straight into its `ModelContext`, and a `MeetingsViewModel` that Views and
//  `RecordingLauncher` built ad hoc for the parts that also clean up files.
//  The rules therefore lived in the UI — tag names deduplicated
//  case-insensitively in three separate places, a meeting deletion journaled
//  in one path — and a lower layer (`RecordingLauncher`) depended on a view
//  model. This is the one owner of those rules, below both.
//
//  Every mutation saves before returning and throws the already-logged
//  `AppError` from `saveOrError()` when the commit fails, so a caller can
//  surface it with `.errorAlert`. Anything that removes a file goes through
//  `RecordingOperationJournal.performDelete` (trash → commit → purge), so a
//  failed save or a process death never loses audio the store still points at.
//
//  Transcription, recording, chat and wiki persistence stay with their own
//  coordinators: those are pipeline outputs, not library management.
//

import Foundation
import KurnCore
import SwiftData

@MainActor
struct MeetingLibrary {
    let context: ModelContext
    /// Commits the context. Production saves it; a test substitutes a failing
    /// commit to reach the rollback paths, which a real store will not fail on
    /// demand.
    private let persist: @MainActor (ModelContext) -> AppError?

    init(
        context: ModelContext,
        persist: @escaping @MainActor (ModelContext) -> AppError? = { $0.saveOrError() }
    ) {
        self.context = context
        self.persist = persist
    }

    // MARK: - Meetings

    /// Inserts and saves a new meeting. A blank title becomes the localized
    /// dated default. When the save fails the insert is undone, so no caller
    /// can go on to record into a meeting the store never committed.
    @discardableResult
    func createMeeting(
        title: String,
        notes: String = "",
        language: MeetingLanguage = .autoDetect
    ) throws(AppError) -> Meeting {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty
            ? String(format: NSLocalizedString("meeting.default_title", comment: "Default title"),
                     Date().titleStamp)
            : trimmed
        let meeting = Meeting(title: finalTitle, notes: notes, language: language)
        context.insert(meeting)
        if let failure = persist(context) {
            context.delete(meeting)
            throw failure
        }
        return meeting
    }

    /// Deletes a meeting (its recordings, transcripts, summaries, chats,
    /// photos and attachments cascade with it) and every audio, photo and
    /// attachment file it owns.
    ///
    /// Runs as a journaled trash → model commit → purge operation: intent is
    /// durable before any file moves, a `save()` failure restores the files
    /// immediately, and a process death at any boundary is replayed or rolled
    /// back from the journal record on the next launch. See
    /// `RecordingOperationJournal`'s header comment.
    func deleteMeeting(_ meeting: Meeting) throws(AppError) {
        try requireNoCaptureInProgress(meeting.recordings)
        let fileNames = meeting.recordings.map(\.fileName)
            + meeting.recordings.flatMap { $0.photos.map(\.fileName) }
            + meeting.attachments.map(\.fileName)
        try journaledDelete(fileNames: fileNames) { context.delete(meeting) }
    }

    /// Deletes one recording segment, its audio and the photos taken during
    /// it, through the same journaled path as `deleteMeeting`.
    func deleteRecording(_ recording: Recording) throws(AppError) {
        try requireNoCaptureInProgress([recording])
        let fileNames = [recording.fileName] + recording.photos.map(\.fileName)
        try journaledDelete(fileNames: fileNames) { context.delete(recording) }
    }

    /// Refuses to delete a recording the live recorder is still writing. A
    /// minimized recorder leaves the meeting reachable mid-capture, and
    /// deleting the row under it would leave the recorder finalizing into a
    /// deleted model and its audio file without an owner.
    private func requireNoCaptureInProgress(_ recordings: [Recording]) throws(AppError) {
        guard recordings.contains(where: \.isCaptureInProgress) else { return }
        throw AppError.audioError(NSLocalizedString(
            "library.delete_while_recording",
            comment: "A meeting or recording cannot be deleted while it is being recorded"
        ))
    }

    /// Deletes one photo and its file. A photo is meeting-derived content like
    /// any other, so it gets the same crash-safety guarantee as a recording.
    func deletePhoto(_ photo: MeetingPhoto) throws(AppError) {
        try journaledDelete(fileNames: [photo.fileName]) { context.delete(photo) }
    }

    // MARK: - Attachments

    /// Records a document already copied into `AttachmentFileStore` as an
    /// attachment of `meeting`. When the save fails the insert is undone and
    /// the copied file removed, so neither an orphaned file nor a row
    /// pointing at nothing survives.
    @discardableResult
    func addAttachment(
        to meeting: Meeting,
        fileName: String,
        displayName: String,
        pageCount: Int,
        extractedText: String?
    ) throws(AppError) -> MeetingAttachment {
        let attachment = MeetingAttachment(
            meeting: meeting,
            fileName: fileName,
            displayName: displayName,
            fileSize: AttachmentFileStore.byteSize(fileName: fileName),
            pageCount: pageCount,
            extractedText: extractedText
        )
        context.insert(attachment)
        if let failure = persist(context) {
            context.delete(attachment)
            AttachmentFileStore.delete(fileName: fileName)
            throw failure
        }
        return attachment
    }

    /// Deletes one attachment and its file, through the same journaled path
    /// as a photo.
    func deleteAttachment(_ attachment: MeetingAttachment) throws(AppError) {
        try journaledDelete(fileNames: [attachment.fileName]) { context.delete(attachment) }
    }

    /// Deletes one of a meeting's summaries; the others are left alone.
    func deleteSummary(_ summary: Summary) throws(AppError) {
        context.delete(summary)
        try save()
    }

    // MARK: - Tags

    /// The existing tag whose name matches `name` case-insensitively, if any.
    /// Tag names are unique in that sense everywhere a user can create one.
    func existingTag(named name: String) -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        return tags.first { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Creates a tag, unless the name is blank or one with the same name
    /// already exists. Returns the new tag, or `nil` when nothing was created.
    @discardableResult
    func createTag(named name: String) throws(AppError) -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, existingTag(named: trimmed) == nil else { return nil }
        let tag = Tag(name: trimmed)
        context.insert(tag)
        try save()
        return tag
    }

    /// Attaches the tag named `name` to `meeting`, reusing an existing tag of
    /// that name or creating one. A no-op for a blank name or a tag the
    /// meeting already carries.
    func attachTag(named name: String, to meeting: Meeting) throws(AppError) {
        guard attach(named: name, to: meeting) else { return }
        try save()
    }

    /// Applies an auto-tagging suggestion: existing tags by id, then new names
    /// (reused when a tag of that name already exists), skipping any the
    /// meeting already carries. Saves once for the whole suggestion.
    func applyTags(ids: [UUID], newNames: [String], to meeting: Meeting) throws(AppError) {
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let byID = Dictionary(tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ids {
            if let tag = byID[id], !meeting.tags.contains(where: { $0.id == id }) {
                meeting.tags.append(tag)
            }
        }
        for name in newNames {
            attach(named: name, to: meeting)
        }
        try save()
    }

    /// Deletes a tag. The relationship is `.nullify`, so its meetings only
    /// lose the tag.
    func deleteTag(_ tag: Tag) throws(AppError) {
        context.delete(tag)
        try save()
    }

    /// Moves every meeting tagged `source` onto `target`, then deletes
    /// `source`.
    func mergeTag(_ source: Tag, into target: Tag) throws(AppError) {
        for meeting in source.meetings where !meeting.tags.contains(where: { $0.id == target.id }) {
            meeting.tags.append(target)
        }
        context.delete(source)
        try save()
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(
        name: String,
        iconName: String,
        colorHex: String,
        parent: Folder?
    ) throws(AppError) -> Folder {
        let folder = Folder(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            iconName: iconName,
            colorHex: colorHex,
            parent: parent
        )
        context.insert(folder)
        try save()
        return folder
    }

    /// Deletes a folder. Both relationships are `.nullify`, so its meetings
    /// and subfolders are detached, never deleted.
    func deleteFolder(_ folder: Folder) throws(AppError) {
        context.delete(folder)
        try save()
    }

    @discardableResult
    func createSmartFolder(name: String, filter: MeetingFilter) throws(AppError) -> SmartFolder {
        let smartFolder = SmartFolder(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            filter: filter
        )
        context.insert(smartFolder)
        try save()
        return smartFolder
    }

    // MARK: - Documents

    /// Deletes a generated document. Documents snapshot their sources, so
    /// nothing else is affected.
    func deleteDocument(_ document: GeneratedDocument) throws(AppError) {
        context.delete(document)
        try save()
    }

    // MARK: - Helpers

    /// Attaches (creating if needed) the tag named `name` without saving.
    /// Returns whether the meeting changed.
    @discardableResult
    private func attach(named name: String, to meeting: Meeting) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let existing = existingTag(named: trimmed) {
            guard !meeting.tags.contains(where: { $0.id == existing.id }) else { return false }
            meeting.tags.append(existing)
        } else {
            let tag = Tag(name: trimmed)
            context.insert(tag)
            meeting.tags.append(tag)
        }
        return true
    }

    private func save() throws(AppError) {
        if let failure = persist(context) { throw failure }
    }

    private func journaledDelete(fileNames: [String], mutation: () -> Void) throws(AppError) {
        let failure = RecordingOperationJournal.performDelete(fileNames: fileNames) {
            mutation()
            return persist(context)
        }
        if let failure { throw failure }
    }
}
