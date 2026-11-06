//
//  MeetingBulkExportViewModelTests.swift
//  KurnTests
//
//  The bulk export screen's state: sharing writes one file per planned item
//  off the main actor, a failure becomes the screen's error, nothing is
//  written when nothing is exportable, and Copy All reaches the pasteboard.
//  File writing and the pasteboard are injected, so no file or pasteboard is
//  touched.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingBulkExportViewModelTests {

    private struct WriteFailure: Error {}

    /// What the injected pasteboard received; a class so the closure can
    /// record into it without capturing a mutable local.
    @MainActor
    private final class Pasteboard {
        var copied: [String] = []
    }

    private let container: ModelContainer
    private let context: ModelContext

    init() {
        container = TestModelContainer.make()
        context = container.mainContext
        context.autosaveEnabled = false
    }

    private func summarizedMeeting(_ title: String) -> Meeting {
        let meeting = Meeting(title: title)
        context.insert(meeting)
        context.insert(Summary(
            meeting: meeting,
            sections: [SummarySection(title: "Recap", body: "\(title) recap")],
            provider: .openAI
        ))
        return meeting
    }

    @Test func shareWritesOneFilePerPlannedItem() async {
        let meetings = [summarizedMeeting("Kickoff"), summarizedMeeting("Retro")]
        let model = MeetingBulkExportViewModel(
            meetings: meetings,
            writeFile: { item, _ in URL(fileURLWithPath: "/tmp/\(item.suggestedName).md") }
        )
        #expect(model.canShare)

        let urls = await model.share()
        #expect(urls?.count == 2)
        #expect(!model.isExporting)
        #expect(model.error == nil)
    }

    @Test func singleFileGroupingWritesOneFile() async {
        let model = MeetingBulkExportViewModel(
            meetings: [summarizedMeeting("Kickoff"), summarizedMeeting("Retro")],
            writeFile: { item, _ in URL(fileURLWithPath: "/tmp/\(item.suggestedName).pdf") }
        )
        model.export.grouping = .singleFile
        model.export.format = .pdf
        #expect(await model.share()?.count == 1)
    }

    @Test func aWriteFailureBecomesTheScreenError() async {
        let model = MeetingBulkExportViewModel(
            meetings: [summarizedMeeting("Kickoff")],
            writeFile: { _, _ in throw WriteFailure() }
        )
        #expect(await model.share() == nil)
        #expect(model.error != nil)
        #expect(!model.isExporting)
    }

    @Test func aPartialWriteFailureRemovesTheWrittenFilesAndRecordsFailure() async throws {
        let meetings = [summarizedMeeting("First"), summarizedMeeting("Second")]
        let firstName = try #require(MeetingBulkExport(meetings: meetings).exportItems().first?.suggestedName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let capture = ReliabilityEventCapture()
        let model = MeetingBulkExportViewModel(meetings: meetings, writeFile: { item, _ in
            guard item.suggestedName == firstName else { throw WriteFailure() }
            try Data("fixture".utf8).write(to: url)
            return url
        })
        #expect(await model.share(recordEvent: capture.record) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.error != nil)
        #expect(!model.isExporting)
        #expect(capture.recorded.map(\.outcome) == [.failed])
        #expect(capture.recorded.first?.code == "write_failed")
    }

    @Test func cancellationDuringAWriteRemovesItsFileAndStopsTheBatch() async throws {
        let meetings = [summarizedMeeting("First"), summarizedMeeting("Second")]
        let firstName = try #require(MeetingBulkExport(meetings: meetings).exportItems().first?.suggestedName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = BlockingWorkGate()
        let capture = ReliabilityEventCapture()
        let model = MeetingBulkExportViewModel(meetings: meetings, writeFile: { item, _ in
            #expect(item.suggestedName == firstName)
            try Data("fixture".utf8).write(to: url)
            if item.suggestedName == firstName { gate.block() }
            #expect(Task.isCancelled)
            return url
        })
        let work = Task { await model.share(recordEvent: capture.record) }
        gate.cancelWhenStarted(work)
        #expect(await work.value == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.error == nil)
        #expect(!model.isExporting)
        #expect(capture.recorded.map(\.outcome) == [.cancelled])
    }

    @Test func cancellationBeforeSharingWritesNothing() async {
        let capture = ReliabilityEventCapture()
        let model = MeetingBulkExportViewModel(meetings: [summarizedMeeting("First")], writeFile: { _, _ in
            Issue.record("cancelled exports must not write")
            throw WriteFailure()
        })
        let work = Task { await model.share(recordEvent: capture.record) }
        work.cancel()
        #expect(await work.value == nil)
        #expect(model.error == nil)
        #expect(capture.recorded.map(\.outcome) == [.cancelled])
    }

    @Test func aCleanupFailureIsRecordedSeparatelyFromTheWriteFailure() async throws {
        let meetings = [summarizedMeeting("First"), summarizedMeeting("Second")]
        let firstName = try #require(MeetingBulkExport(meetings: meetings).exportItems().first?.suggestedName)
        let url = URL(fileURLWithPath: "/fixture/export.md")
        let fileSystem = FakeFileSystem()
        fileSystem.failRemoval(of: url)
        let capture = ReliabilityEventCapture()
        let model = MeetingBulkExportViewModel(meetings: meetings, writeFile: { item, _ in
            guard item.suggestedName == firstName else { throw WriteFailure() }
            return url
        })
        #expect(await model.share(fileSystem: fileSystem, recordEvent: capture.record) == nil)
        #expect(fileSystem.removalAttempts == [url])
        #expect(capture.recorded.map(\.code) == ["cleanup_failed", "write_failed"])
        #expect(Set(capture.recorded.map(\.operationID)).count == 1)
    }

    @Test func nothingExportableWritesNothing() async {
        let empty = Meeting(title: "Empty")
        context.insert(empty)
        let model = MeetingBulkExportViewModel(
            meetings: [empty],
            writeFile: { _, _ in
                Issue.record("nothing should be written")
                return URL(fileURLWithPath: "/tmp/x")
            }
        )
        #expect(!model.canShare)
        #expect(await model.share() == nil)
        #expect(model.error == nil)
    }

    @Test func copyAllPutsEveryMeetingOnThePasteboardAndConfirms() {
        let pasteboard = Pasteboard()
        let model = MeetingBulkExportViewModel(
            meetings: [summarizedMeeting("Kickoff"), summarizedMeeting("Retro")],
            copyToPasteboard: { pasteboard.copied.append($0) },
            copyConfirmation: .seconds(60)
        )
        model.copyAll()
        #expect(pasteboard.copied.count == 1)
        #expect(pasteboard.copied.first?.contains("Kickoff recap") == true)
        #expect(pasteboard.copied.first?.contains("Retro recap") == true)
        #expect(model.didCopy)
    }

    @Test func copyAllWithNothingExportableCopiesNothing() {
        let empty = Meeting(title: "Empty")
        context.insert(empty)
        let pasteboard = Pasteboard()
        let model = MeetingBulkExportViewModel(meetings: [empty], copyToPasteboard: { pasteboard.copied.append($0) })
        model.copyAll()
        #expect(pasteboard.copied.isEmpty)
        #expect(!model.didCopy)
    }

    @Test func theCopyConfirmationClearsItself() async throws {
        let model = MeetingBulkExportViewModel(
            meetings: [summarizedMeeting("Kickoff")],
            copyToPasteboard: { _ in },
            copyConfirmation: .milliseconds(10)
        )
        model.copyAll()
        #expect(model.didCopy)
        for _ in 0..<100 where model.didCopy {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.didCopy)
    }
}
