import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension RecordingsDirectorySuite {
@MainActor
struct RecordingReferenceFailureTests {
    enum Model: CaseIterable {
        case recording, photo, attachment

        var references: RecordingFileReferences {
            struct FetchFailed: Error {}
            switch self {
            case .recording: return RecordingFileReferences(recordings: { _ in throw FetchFailed() })
            case .photo: return RecordingFileReferences(photos: { _ in throw FetchFailed() })
            case .attachment: return RecordingFileReferences(attachments: { _ in throw FetchFailed() })
            }
        }

        func insertFile(context: ModelContext) throws -> URL {
            let name = "\(UUID().uuidString).dat"
            let directory: URL
            switch self {
            case .recording:
                directory = AudioFileStore.recordingsDirectoryURL
                context.insert(Recording(fileName: name, duration: 1))
            case .photo:
                directory = PhotoFileStore.photosDirectoryURL
                context.insert(MeetingPhoto(fileName: name, capturedAt: 0))
            case .attachment:
                directory = AttachmentFileStore.attachmentsDirectoryURL
                context.insert(MeetingAttachment(fileName: name, displayName: "private title"))
            }
            try context.save()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: url)
            return url
        }
    }

    @Test(arguments: Model.allCases, [false, true])
    func failedReferenceFetchPreservesFiles(model: Model, replay: Bool) throws {
        let context = ModelContext(TestModelContainer.make())
        let url = try model.insertFile(context: context)
        let operationID = UUID()
        defer {
            RecordingTrash.purge(operationID: operationID)
            RecordingOperationJournal.removeRecord(operationID)
            try? FileManager.default.removeItem(at: url)
        }
        #expect(RecordingTrash.trash(fileNames: [url.lastPathComponent], operationID: operationID))
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }

        if replay {
            let directory = try RecordingProtection.ensureProtectedDirectory(
                named: RecordingProtection.journalDirectoryName,
                in: AudioFileStore.recordingsDirectoryURL
            )
            let record = RecordingOperationJournal.Record(
                id: operationID, kind: .delete, fileNames: [url.lastPathComponent], startedAt: Date(), state: .trashed
            )
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("\(operationID.uuidString).json"))
            RecordingOperationJournal.replay(context: context, references: model.references)
            #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        } else {
            RecordingTrash.sweep(context: context, references: model.references)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            RecordingTrash.sweep(context: context)
            #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        }
        let events = capture.recorded.filter { $0.code == "reference_fetch_failed" }
        #expect(events.count == 1)
        #expect(events.first?.outcome == .failed)
        #expect(events.first?.stage == (replay ? "replay" : "sweep"))
        #expect(events.first?.operation == (replay ? "recording_journal" : "recording_trash"))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!encoded.contains(url.lastPathComponent))
        #expect(!encoded.contains("private title"))
    }
}
}
