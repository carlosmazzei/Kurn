//
//  RecordingQuarantine.swift
//  Kurn
//
//  Protected holding area for original audio the app cannot place: orphans
//  whose file name doesn't parse, orphans whose meeting row is gone, files
//  whose container can't be opened, recordings too short to reattach, and
//  legacy-migration collisions. These used to be deleted automatically; they
//  are the only copy of the user's audio, so instead they move — never copy,
//  never delete — into `Recordings/Quarantine/<uuid>/` alongside a small
//  metadata file recording when, how big, and why. Settings exposes recover /
//  export / confirmed-delete for each item.
//

import Foundation
import KurnCore
import SwiftData

/// Why a file was quarantined instead of placed. Stored as a raw string in the
/// per-item metadata so old items keep decoding when cases are added.
enum RecordingQuarantineReason: String, Codable, Sendable {
    /// The file name doesn't follow `{meetingID}_{...}.m4a`.
    case unparsableFileName = "unparsable_file_name"
    /// The name parsed but no `Meeting` row with that ID exists.
    case meetingNotFound = "meeting_not_found"
    /// The audio container could not be opened or finalized.
    case unreadableContainer = "unreadable_container"
    /// Readable, but shorter than the minimum a `Recording` row represents.
    case negligibleDuration = "negligible_duration"
    /// A legacy file in Documents collided with a different file already in
    /// the protected directory; neither can be proven redundant.
    case legacyCollision = "legacy_collision"
    /// Metadata sidecar was missing or unreadable when listing.
    case unknown = "unknown"

    var localizedDescription: String {
        switch self {
        case .unparsableFileName:
            return NSLocalizedString("quarantine.reason.unparsable", comment: "File name not recognized")
        case .meetingNotFound:
            return NSLocalizedString("quarantine.reason.meeting_not_found", comment: "Meeting no longer exists")
        case .unreadableContainer:
            return NSLocalizedString("quarantine.reason.unreadable", comment: "Audio file could not be read")
        case .negligibleDuration:
            return NSLocalizedString("quarantine.reason.too_short", comment: "Recording too short")
        case .legacyCollision:
            return NSLocalizedString("quarantine.reason.collision", comment: "Name collision during migration")
        case .unknown:
            return NSLocalizedString("quarantine.reason.unknown", comment: "Unknown reason")
        }
    }
}

/// One preserved original: the audio file plus its sidecar metadata.
struct QuarantinedRecording: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let byteSize: Int64
    let quarantinedAt: Date
    let reason: RecordingQuarantineReason

    var fileURL: URL {
        RecordingQuarantine.itemDirectory(id: id).appendingPathComponent(fileName)
    }
}

enum RecordingQuarantine {
    private struct Metadata: Codable {
        let fileName: String
        let byteSize: Int64
        let quarantinedAt: Date
        let reason: String
    }

    private static let metadataFileName = "metadata.json"

    static var rootURL: URL {
        AudioFileStore.recordingsDirectoryURL
            .appendingPathComponent(RecordingProtection.quarantineDirectoryName, isDirectory: true)
    }

    static func itemDirectory(id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Move `url` into a fresh protected quarantine slot and write its
    /// metadata sidecar. Returns whether the move succeeded; on any failure
    /// the original stays where it was — quarantine never deletes.
    @discardableResult
    static func quarantine(
        fileAt url: URL,
        reason: RecordingQuarantineReason,
        fileManager: FileManager = .default
    ) -> Bool {
        let id = UUID()
        let itemURL = itemDirectory(id: id)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let fileName = url.lastPathComponent
        do {
            try RecordingProtection.ensureProtectedDirectory(
                named: "\(RecordingProtection.quarantineDirectoryName)/\(id.uuidString)",
                in: AudioFileStore.recordingsDirectoryURL,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: url, to: itemURL.appendingPathComponent(fileName))
        } catch {
            // Leave the original in place: quarantine preserves, never loses.
            AppLog.recorder.atError.error(
                "quarantine: failed to preserve original reason=\(reason.rawValue, privacy: .public) code=\(error.publicLogCode, privacy: .public)"
            )
            CaptureReliability.quarantined(fileName: fileName, reason: reason, preserved: false)
            return false
        }
        RecordingProtection.apply(to: itemURL.appendingPathComponent(fileName))
        CaptureReliability.quarantined(fileName: fileName, reason: reason, preserved: true)

        // The audio is now safe. Metadata is best-effort on top: if the
        // sidecar can't be written, `items()` synthesizes attributes from the
        // file itself and reports the reason as unknown.
        let metadata = Metadata(
            fileName: fileName,
            byteSize: size,
            quarantinedAt: Date(),
            reason: reason.rawValue
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(metadata).write(
            to: itemURL.appendingPathComponent(metadataFileName),
            options: .atomic
        )
        AppLog.recorder.atNotice.notice(
            "quarantine: preserved original reason=\(reason.rawValue, privacy: .public) size=\(size, privacy: .public)"
        )
        return true
    }

    /// Every quarantined original, newest first. Items whose metadata sidecar
    /// is missing or unreadable are still listed — the audio is what matters —
    /// with attributes synthesized from the file itself.
    static func items(fileManager: FileManager = .default) -> [QuarantinedRecording] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [QuarantinedRecording] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            guard let audio = contents.first(where: { $0.lastPathComponent != metadataFileName }) else { continue }

            let metadataURL = directory.appendingPathComponent(metadataFileName)
            if let data = try? Data(contentsOf: metadataURL),
               let metadata = try? decoder.decode(Metadata.self, from: data) {
                result.append(QuarantinedRecording(
                    id: id,
                    fileName: metadata.fileName,
                    byteSize: metadata.byteSize,
                    quarantinedAt: metadata.quarantinedAt,
                    reason: RecordingQuarantineReason(rawValue: metadata.reason) ?? .unknown
                ))
            } else {
                let values = try? audio.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                result.append(QuarantinedRecording(
                    id: id,
                    fileName: audio.lastPathComponent,
                    byteSize: Int64(values?.fileSize ?? 0),
                    quarantinedAt: values?.creationDate ?? .distantPast,
                    reason: .unknown
                ))
            }
        }
        return result.sorted { $0.quarantinedAt > $1.quarantinedAt }
    }

    /// Total bytes preserved, for the Settings storage breakdown.
    static func totalBytes() -> Int64 {
        items().reduce(0) { $0 + $1.byteSize }
    }

    /// Confirmed, user-initiated deletion of one item. The only path that
    /// removes quarantined audio.
    static func delete(_ item: QuarantinedRecording, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: itemDirectory(id: item.id))
    }

    /// Copy the audio into a temp export slot for the share sheet.
    /// `ActivityView` deletes a shared file's parent directory on completion,
    /// so the quarantined original itself must never be handed to it.
    static func exportURL(for item: QuarantinedRecording) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(item.fileName)
        try FileManager.default.copyItem(at: item.fileURL, to: destination)
        return destination
    }

    /// Move the audio back into the protected recordings directory and attach
    /// it to its meeting (recreated if the row is gone). On any failure the
    /// file returns to quarantine, so the operation is preserve-or-recover,
    /// never lose.
    @MainActor
    static func recover(_ item: QuarantinedRecording, context: ModelContext) -> AppError? {
        let fm = FileManager.default
        let recordingsURL: URL
        do {
            recordingsURL = try AudioFileStore.ensureRecordingsDirectory()
        } catch let error as AppError {
            return error
        } catch {
            return .protectedStorageUnavailable(error.localizedDescription)
        }

        let meeting = resolveMeeting(for: item, context: context)
        var fileName = item.fileName
        if fm.fileExists(atPath: recordingsURL.appendingPathComponent(fileName).path) {
            fileName = AudioFileStore.fileName(meetingID: meeting.id, recordingID: UUID())
        }
        let destination = recordingsURL.appendingPathComponent(fileName)

        do {
            try fm.moveItem(at: item.fileURL, to: destination)
        } catch {
            return .protectedStorageUnavailable(error.localizedDescription)
        }
        RecordingProtection.apply(to: destination)

        func rollBack() {
            try? fm.moveItem(at: destination, to: item.fileURL)
        }

        let metadata: FinalizedRecordingFile
        do {
            metadata = try RecordingFileFinalizer().finalize(fileName: fileName)
        } catch {
            rollBack()
            return .audioError(NSLocalizedString(
                "quarantine.recover_unreadable",
                comment: "The quarantined audio could not be read"
            ))
        }

        if meeting.modelContext == nil {
            context.insert(meeting)
        }
        let recording = Recording(
            meeting: meeting,
            fileName: fileName,
            duration: metadata.duration,
            fileSize: metadata.fileSize
        )
        context.insert(recording)
        do {
            try context.save()
        } catch {
            context.delete(recording)
            rollBack()
            return .persistenceFailed(error.localizedDescription)
        }
        delete(item)
        return nil
    }

    @MainActor
    private static func resolveMeeting(for item: QuarantinedRecording, context: ModelContext) -> Meeting {
        if let meetingID = meetingID(from: item.fileName) {
            var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
            descriptor.fetchLimit = 1
            if let meeting = try? context.fetch(descriptor).first {
                return meeting
            }
        }
        return Meeting(
            title: NSLocalizedString("quarantine.recovered_meeting_title", comment: "Recovered recording"),
            createdAt: item.quarantinedAt == .distantPast ? Date() : item.quarantinedAt
        )
    }

    /// Parses the `{meetingID}_{...}.m4a` convention from `AudioFileStore.fileName`.
    private static func meetingID(from fileName: String) -> UUID? {
        guard let underscoreIndex = fileName.firstIndex(of: "_") else { return nil }
        return UUID(uuidString: String(fileName[..<underscoreIndex]))
    }
}
