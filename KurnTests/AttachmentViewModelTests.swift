//
//  AttachmentViewModelTests.swift
//  KurnTests
//
//  The two screens that attach PDFs keep no logic of their own, so their
//  behaviour is pinned here: the meeting's Documents section
//  (`MeetingAttachmentsViewModel`) and the sheet a shared PDF opens on
//  (`AttachToMeetingViewModel`). Imports run against real PDFs
//  (`PDFFixtures`) through the real importer, with a scripted extractor only
//  where an outcome must be forced.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct AttachmentViewModelTests {

    private struct PickerFailure: Error {}

    private func makeMeeting(title: String = "Planning") throws -> (Meeting, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        let meeting = try MeetingLibrary(context: context).createMeeting(title: title)
        return (meeting, context)
    }

    private func removeStoredFiles(of meeting: Meeting) {
        meeting.attachments.forEach { AttachmentFileStore.delete(fileName: $0.fileName) }
    }

    // MARK: - MeetingAttachmentsViewModel

    @Test func requestImportOpensThePicker() {
        let viewModel = MeetingAttachmentsViewModel()
        viewModel.requestImport()
        #expect(viewModel.isShowingImporter)
    }

    @Test func pickedPDFsAreImportedIntoTheMeeting() async throws {
        let (meeting, context) = try makeMeeting()
        defer { removeStoredFiles(of: meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Agenda"], name: "Agenda.pdf")
        defer { PDFFixtures.remove(source) }
        let viewModel = MeetingAttachmentsViewModel()

        await viewModel.importPicked(.success([source]), into: meeting, context: context)

        #expect(meeting.attachments.map(\.displayName) == ["Agenda.pdf"])
        #expect(!viewModel.isImporting)
        #expect(viewModel.error == nil)
    }

    @Test func aFailedImportIsSurfaced() async throws {
        let (meeting, context) = try makeMeeting()
        let source = try PDFFixtures.makeNonPDF()
        defer { PDFFixtures.remove(source) }
        let viewModel = MeetingAttachmentsViewModel()

        await viewModel.importPicked(.success([source]), into: meeting, context: context)

        #expect(viewModel.error?.logCode == "attachment_import")
        #expect(meeting.attachments.isEmpty)
    }

    @Test func aPickerFailureIsSurfacedAndAnEmptyPickIsIgnored() async throws {
        let (meeting, context) = try makeMeeting()
        let viewModel = MeetingAttachmentsViewModel()

        await viewModel.importPicked(.success([]), into: meeting, context: context)
        #expect(viewModel.error == nil)

        await viewModel.importPicked(.failure(PickerFailure()), into: meeting, context: context)
        #expect(viewModel.error?.logCode == "attachment_import")
    }

    @Test func deletingThePreviewedAttachmentClosesThePreview() async throws {
        let (meeting, context) = try makeMeeting()
        defer { removeStoredFiles(of: meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Agenda"])
        defer { PDFFixtures.remove(source) }
        let attachment = try await MeetingAttachmentImporter(context: context).importPDF(from: source, into: meeting)
        let viewModel = MeetingAttachmentsViewModel()
        viewModel.preview(attachment)
        #expect(viewModel.previewURL == attachment.fileURL)

        viewModel.delete(attachment, context: context)

        #expect(viewModel.previewURL == nil)
        #expect(meeting.attachments.isEmpty)
        #expect(viewModel.error == nil)
    }

    @Test func aFailedDeleteIsSurfaced() async throws {
        let (meeting, context) = try makeMeeting()
        defer { removeStoredFiles(of: meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Agenda"])
        defer { PDFFixtures.remove(source) }
        let attachment = try await MeetingAttachmentImporter(context: context).importPDF(from: source, into: meeting)
        let fileName = attachment.fileName
        defer { AttachmentFileStore.delete(fileName: fileName) }
        let viewModel = MeetingAttachmentsViewModel(makeLibrary: { context in
            MeetingLibrary(context: context, persist: { _ in .persistenceFailed("disk") })
        })

        viewModel.delete(attachment, context: context)

        #expect(viewModel.error?.logCode == AppError.persistenceFailed("").logCode)
        #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
    }

    // MARK: - AttachToMeetingViewModel

    @Test func searchMatchesLikeTheMeetingsList() throws {
        let context = ModelContext(TestModelContainer.make())
        let library = MeetingLibrary(context: context)
        let budget = try library.createMeeting(title: "Budget review")
        let hiring = try library.createMeeting(title: "Hiring sync", notes: "budget for two roles")
        let standup = try library.createMeeting(title: "Standup")
        let viewModel = AttachToMeetingViewModel(files: [], modelContext: context)
        let all = [budget, hiring, standup]

        #expect(viewModel.matchingMeetings(all).map(\.title) == all.map(\.title))
        viewModel.searchText = "  budget "
        #expect(viewModel.matchingMeetings(all).map(\.title) == ["Budget review", "Hiring sync"])
    }

    @Test func attachingToAMeetingFinishesWithItsTitle() async throws {
        let (meeting, context) = try makeMeeting(title: "Q3 planning")
        defer { removeStoredFiles(of: meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Targets"], name: "Targets.pdf")
        defer { PDFFixtures.remove(source) }
        let viewModel = AttachToMeetingViewModel(files: [source], modelContext: context)
        #expect(!viewModel.isFinished)

        await viewModel.attach(to: meeting)

        #expect(viewModel.isFinished)
        #expect(viewModel.attachedMeetingTitle == "Q3 planning")
        #expect(viewModel.error == nil)
        #expect(meeting.attachments.count == 1)
    }

    @Test func aShareThatFailsEntirelyDoesNotFinish() async throws {
        let (meeting, context) = try makeMeeting()
        let source = try PDFFixtures.makeNonPDF()
        defer { PDFFixtures.remove(source) }
        let viewModel = AttachToMeetingViewModel(files: [source], modelContext: context)

        await viewModel.attach(to: meeting)

        #expect(!viewModel.isFinished)
        #expect(viewModel.error?.logCode == "attachment_import")
    }

    @Test func attachingToANewMeetingNamesItAfterTheFile() async throws {
        let context = ModelContext(TestModelContainer.make())
        let source = try PDFFixtures.makePDF(pages: ["Roadmap"], name: "Roadmap 2027.pdf")
        defer { PDFFixtures.remove(source) }
        let viewModel = AttachToMeetingViewModel(files: [source], modelContext: context)

        await viewModel.attachToNewMeeting()

        let meeting = try #require(try context.fetch(FetchDescriptor<Meeting>()).first)
        defer { removeStoredFiles(of: meeting) }
        #expect(meeting.title == "Roadmap 2027")
        #expect(viewModel.attachedMeetingTitle == "Roadmap 2027")
        #expect(meeting.attachments.count == 1)
    }

    @Test func aNewMeetingIsRemovedWhenNothingWentIn() async throws {
        let context = ModelContext(TestModelContainer.make())
        let source = try PDFFixtures.makeNonPDF()
        defer { PDFFixtures.remove(source) }
        let viewModel = AttachToMeetingViewModel(files: [source], modelContext: context)

        await viewModel.attachToNewMeeting()

        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 0)
        #expect(!viewModel.isFinished)
        #expect(viewModel.error?.logCode == "attachment_import")
    }

    @Test func aNewMeetingThatCannotBeSavedIsReported() async throws {
        let context = ModelContext(TestModelContainer.make())
        let failing = MeetingLibrary(context: context, persist: { _ in .persistenceFailed("disk") })
        let viewModel = AttachToMeetingViewModel(
            files: [URL(fileURLWithPath: "/tmp/agenda.pdf")],
            importer: MeetingAttachmentImporter(library: failing)
        )

        await viewModel.attachToNewMeeting()

        #expect(viewModel.error?.logCode == AppError.persistenceFailed("").logCode)
        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 0)
        #expect(!viewModel.isFinished)
    }

    // MARK: - Presentation

    @Test func detailsTextShowsPagesAndSize() {
        let one = MeetingAttachment(fileName: "a.pdf", displayName: "A", fileSize: 2_048, pageCount: 1)
        let many = MeetingAttachment(fileName: "b.pdf", displayName: "B", fileSize: 0, pageCount: 12)
        #expect(one.detailsText.hasPrefix(NSLocalizedString("detail.attachments.one_page", comment: "")))
        #expect(one.detailsText.contains(" · "))
        #expect(many.detailsText.hasPrefix(String(
            format: NSLocalizedString("detail.attachments.pages", comment: ""), 12
        )))
    }
}
