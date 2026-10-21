import AVFoundation
import Foundation

struct FinalizedRecordingFile: Equatable, Sendable {
    let duration: TimeInterval
    let fileSize: Int64
}

enum RecordingFileFinalizationError: Error, Equatable, Sendable {
    case missing
    case empty
    case unreadable
    case invalidDuration
    case protectionFailed

    var recoveryReason: CaptureRecoveryReason {
        switch self {
        case .missing: .fileMissing
        case .empty: .emptyFile
        case .unreadable: .unreadableFile
        case .invalidDuration: .invalidDuration
        case .protectionFailed: .protectionFailed
        }
    }
}

protocol RecordingFileFinalizing {
    func finalize(fileName: String) throws -> FinalizedRecordingFile
}

struct RecordingFileFinalizer: RecordingFileFinalizing {
    private let protect: (URL) throws -> Void
    private let discardJournal: (String) -> Void

    /// `discardJournal` drops the recording's `CaptureJournal` once the file
    /// itself is accepted: a readable, protected `.m4a` is the authoritative
    /// copy, so the crash-safe one has done its job. It is never called on a
    /// failure, which is when the journal is the only decodable copy.
    init(
        protect: @escaping (URL) throws -> Void = { try RecordingProtection.applyAndVerify(to: $0) },
        discardJournal: @escaping (String) -> Void = { CaptureJournal.delete(for: $0) }
    ) {
        self.protect = protect
        self.discardJournal = discardJournal
    }

    func finalize(fileName: String) throws -> FinalizedRecordingFile {
        let url = AudioFileStore.resolveURL(fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RecordingFileFinalizationError.missing
        }
        let size = AudioFileStore.byteSize(fileName: fileName)
        guard size > 0 else {
            throw RecordingFileFinalizationError.empty
        }
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else {
            throw RecordingFileFinalizationError.unreadable
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else {
            throw RecordingFileFinalizationError.invalidDuration
        }
        do {
            try protect(url)
        } catch {
            throw RecordingFileFinalizationError.protectionFailed
        }
        discardJournal(fileName)
        return FinalizedRecordingFile(duration: duration, fileSize: size)
    }
}
