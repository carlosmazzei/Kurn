//
//  PhotoFileStoreTests.swift
//  KurnTests
//
//  Meeting photos on disk: deterministic names, the protected directory, a
//  write that round-trips, sizes, and deletes that tolerate a missing file.
//  Every test works on files it created itself, because the photos
//  directory is shared with the rest of the test host.
//

import Foundation
import Testing
@testable import Kurn

struct PhotoFileStoreTests {

    @Test func fileNameIsRecordingThenPhotoID() {
        let recording = UUID()
        let photo = UUID()
        #expect(PhotoFileStore.fileName(recordingID: recording, photoID: photo)
                == "\(recording.uuidString)_\(photo.uuidString).jpg")
        #expect(PhotoFileStore.fileName(recordingID: recording) != PhotoFileStore.fileName(recordingID: recording))
    }

    @Test func photosLiveInTheProtectedRecordingsSubdirectory() {
        let directory = PhotoFileStore.photosDirectoryURL
        #expect(directory.lastPathComponent == RecordingProtection.photosDirectoryName)
        #expect(directory.deletingLastPathComponent().standardizedFileURL.path
                == AudioFileStore.recordingsDirectoryURL.standardizedFileURL.path)
        #expect(PhotoFileStore.resolveURL(fileName: "a.jpg") == directory.appendingPathComponent("a.jpg"))
    }

    @Test func writeMeasureAndDeleteRoundTrip() throws {
        let data = Data(repeating: 0xFF, count: 1_234)
        let name = try PhotoFileStore.write(data, recordingID: UUID())
        defer { PhotoFileStore.delete(fileName: name) }

        let url = PhotoFileStore.resolveURL(fileName: name)
        #expect(try Data(contentsOf: url) == data)
        #expect(PhotoFileStore.byteSize(fileName: name) == 1_234)
        #expect(PhotoFileStore.totalPhotoBytes() >= 1_234)

        PhotoFileStore.delete(fileName: name)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(PhotoFileStore.byteSize(fileName: name) == 0)
    }

    @Test func deletingAMissingPhotoIsHarmless() {
        PhotoFileStore.delete(fileName: "\(UUID().uuidString).jpg")
        #expect(PhotoFileStore.byteSize(fileName: "\(UUID().uuidString).jpg") == 0)
    }

    @Test func ensuringTheDirectoryIsIdempotent() throws {
        let first = try PhotoFileStore.ensurePhotosDirectory()
        let second = try PhotoFileStore.ensurePhotosDirectory()
        #expect(first.standardizedFileURL.path == second.standardizedFileURL.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
