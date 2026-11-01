//
//  MeetingAttachmentImporterTests.swift
//  KurnTests
//
//  Adding a PDF to a meeting: the copy lands in protected storage with its
//  text, the source is left alone, a refused file leaves no copy behind,
//  and a batch carries on past the file that fails. Extraction runs for real
//  against `PDFFixtures` documents except where a test needs an outcome a
//  fixture cannot produce on demand.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingAttachmentImporterTests {

    private func makeMeeting() throws -> (Meeting, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        let meeting = try MeetingLibrary(context: context).createMeeting(title: "Planning")
        return (meeting, context)
    }

    /// Names of the attachment files stored for `meeting`.
    private func storedFiles(for meeting: Meeting) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: AttachmentFileStore.attachmentsDirectoryURL.path)) ?? []
        return items.filter { $0.hasPrefix(meeting.id.uuidString) }
    }

    private func cleanUp(_ meeting: Meeting) {
        for name in storedFiles(for: meeting) { AttachmentFileStore.delete(fileName: name) }
    }

    @Test func importsAPDFWithItsTextAndLeavesTheSourceAlone() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Quarterly targets"], name: "Targets.pdf")
        defer { PDFFixtures.remove(source) }

        let attachment = try await MeetingAttachmentImporter(context: context).importPDF(from: source, into: meeting)

        #expect(attachment.displayName == "Targets.pdf")
        #expect(attachment.pageCount == 1)
        #expect(attachment.extractedText?.contains("Quarterly targets") == true)
        #expect(attachment.hasExtractedText)
        #expect(attachment.fileSize > 0)
        #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(meeting.attachments.map(\.id) == [attachment.id])
        #expect(try context.fetch(FetchDescriptor<MeetingAttachment>()).count == 1)
    }

    @Test func aDocumentWithoutTextIsStillAttached() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makePDF(pages: ["ignored"])
        defer { PDFFixtures.remove(source) }
        let importer = MeetingAttachmentImporter(context: context) { _ in
            .success(PDFTextExtraction(pageCount: 3, text: nil))
        }

        let attachment = try await importer.importPDF(from: source, into: meeting)

        #expect(attachment.pageCount == 3)
        #expect(!attachment.hasExtractedText)
        #expect(attachment.promptDocument.text.isEmpty)
    }

    @Test func truncatedTextIsStillAttached() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makePDF(pages: ["ignored"])
        defer { PDFFixtures.remove(source) }
        let importer = MeetingAttachmentImporter(context: context) { _ in
            .success(PDFTextExtraction(pageCount: 5_000, text: "First pages", isTruncated: true))
        }

        let attachment = try await importer.importPDF(from: source, into: meeting)

        #expect(attachment.pageCount == 5_000)
        #expect(attachment.extractedText == "First pages")
    }

    @Test func aPDFOverTheSizeLimitIsRefusedAndItsCopyRemoved() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Agenda"])
        defer { PDFFixtures.remove(source) }
        let importer = MeetingAttachmentImporter(context: context) { url in
            do throws(PDFTextExtractor.Failure) {
                return .success(try PDFTextExtractor.extract(from: url, maxFileBytes: 16))
            } catch {
                return .failure(error)
            }
        }

        do throws(AppError) {
            try await importer.importPDF(from: source, into: meeting)
            Issue.record("an oversized PDF must be refused")
        } catch {
            #expect(error.logCode == "attachment_import")
            #expect(error.privateContext == MeetingAttachmentImporter.message(for: .tooLarge))
        }
        #expect(storedFiles(for: meeting).isEmpty)
        #expect(meeting.attachments.isEmpty)
    }

    @Test func theReliabilityCodeSaysWhenTextIsMissingOrCut() {
        #expect(MeetingAttachmentImporter.code(for: PDFTextExtraction(pageCount: 1, text: nil)) == "no_text")
        #expect(MeetingAttachmentImporter.code(for: PDFTextExtraction(pageCount: 1, text: "a", isTruncated: true)) == "text_truncated")
        #expect(MeetingAttachmentImporter.code(for: PDFTextExtraction(pageCount: 1, text: "a")) == nil)
    }

    @Test func aLockedPDFIsRefusedAndItsCopyRemoved() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Secret"], password: "pw")
        defer { PDFFixtures.remove(source) }

        do throws(AppError) {
            try await MeetingAttachmentImporter(context: context).importPDF(from: source, into: meeting)
            Issue.record("a locked PDF must be refused")
        } catch {
            #expect(error.logCode == "attachment_import")
            #expect(error.privateContext == MeetingAttachmentImporter.message(for: .locked))
        }
        #expect(storedFiles(for: meeting).isEmpty)
        #expect(meeting.attachments.isEmpty)
    }

    @Test func aFileThatIsNotAPDFIsRefused() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makeNonPDF()
        defer { PDFFixtures.remove(source) }

        do throws(AppError) {
            try await MeetingAttachmentImporter(context: context).importPDF(from: source, into: meeting)
            Issue.record("a non-PDF must be refused")
        } catch {
            #expect(error.privateContext == MeetingAttachmentImporter.message(for: .unreadable))
        }
        #expect(storedFiles(for: meeting).isEmpty)
    }

    @Test func aMissingSourceFailsBeforeAnythingIsStored() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")

        do throws(AppError) {
            try await MeetingAttachmentImporter(context: context).importPDF(from: missing, into: meeting)
            Issue.record("a missing file must fail")
        } catch {
            #expect(error.logCode == AppError.protectedStorageUnavailable("").logCode)
        }
        #expect(storedFiles(for: meeting).isEmpty)
    }

    @Test func aBatchCarriesOnPastTheFileThatFails() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let first = try PDFFixtures.makePDF(pages: ["One"], name: "One.pdf")
        let broken = try PDFFixtures.makeNonPDF()
        let last = try PDFFixtures.makePDF(pages: ["Two"], name: "Two.pdf")
        defer { [first, broken, last].forEach(PDFFixtures.remove) }

        let report = await MeetingAttachmentImporter(context: context)
            .importPDFs(from: [first, broken, last], into: meeting)

        #expect(report.importedCount == 2)
        #expect(report.firstFailure?.logCode == "attachment_import")
        #expect(Set(meeting.attachments.map(\.displayName)) == ["One.pdf", "Two.pdf"])
        #expect(storedFiles(for: meeting).count == 2)
    }

    @Test func aCancelledImportRemovesItsCopy() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Agenda"])
        defer { PDFFixtures.remove(source) }
        let importer = MeetingAttachmentImporter(context: context)

        // Cancelled before it runs: the test holds the main actor, so the
        // task body only starts once this function suspends on its value.
        let task = Task { () -> AppError? in
            do throws(AppError) {
                try await importer.importPDF(from: source, into: meeting)
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let failure = await task.value

        #expect(failure?.logCode == "attachment_import")
        #expect(storedFiles(for: meeting).isEmpty)
        #expect(meeting.attachments.isEmpty)
    }

    @Test func aSaveFailureRemovesTheCopyAndReportsIt() async throws {
        let (meeting, context) = try makeMeeting()
        defer { cleanUp(meeting) }
        let source = try PDFFixtures.makePDF(pages: ["Agenda"])
        defer { PDFFixtures.remove(source) }
        let failing = MeetingLibrary(context: context, persist: { _ in .persistenceFailed("disk") })

        do throws(AppError) {
            try await MeetingAttachmentImporter(library: failing).importPDF(from: source, into: meeting)
            Issue.record("a failed save must not report success")
        } catch {
            #expect(error.logCode == AppError.persistenceFailed("").logCode)
        }
        #expect(storedFiles(for: meeting).isEmpty)
        #expect(meeting.attachments.isEmpty)
    }

    @Test func importingIntoANewMeetingKeepsItWhenAFileWentIn() async throws {
        let context = ModelContext(TestModelContainer.make())
        let good = try PDFFixtures.makePDF(pages: ["Plan"], name: "Plan.pdf")
        let broken = try PDFFixtures.makeNonPDF()
        defer { [good, broken].forEach(PDFFixtures.remove) }

        let (meeting, report) = await MeetingAttachmentImporter(context: context)
            .importPDFsIntoNewMeeting(from: [good, broken])

        let created = try #require(meeting)
        defer { cleanUp(created) }
        #expect(created.title == "Plan")
        #expect(report.importedCount == 1)
        #expect(report.firstFailure != nil)
        #expect(try context.fetchCount(FetchDescriptor<Meeting>()) == 1)
    }

    @Test func displayNameIsTheFileNameWithAFallback() {
        #expect(MeetingAttachmentImporter.displayName(for: URL(fileURLWithPath: "/tmp/Agenda Q3.pdf")) == "Agenda Q3.pdf")
        #expect(!MeetingAttachmentImporter.displayName(for: URL(fileURLWithPath: "/")).isEmpty)
        #expect(MeetingAttachmentImporter.displayName(for: URL(fileURLWithPath: "/")) != "/")
    }

    @Test func eachRefusalHasItsOwnMessage() {
        let unreadable = MeetingAttachmentImporter.message(for: .unreadable)
        let locked = MeetingAttachmentImporter.message(for: .locked)
        let tooLarge = MeetingAttachmentImporter.message(for: .tooLarge)
        #expect(!unreadable.isEmpty)
        #expect(Set([unreadable, locked, tooLarge]).count == 3)
    }

    @Test func attachedTextFollowsTheTranscriptInTheMeetingsContext() throws {
        let (meeting, context) = try makeMeeting()
        let recording = Recording(meeting: meeting, fileName: "\(UUID().uuidString).m4a", duration: 10)
        context.insert(recording)
        let segments = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 3, text: "Let's review the budget.")]
        let transcript = Transcript(recording: recording, segments: segments)
        context.insert(transcript)
        context.insert(MeetingAttachment(meeting: meeting, fileName: "a.pdf", displayName: "Budget.pdf", extractedText: "Total: 1.2M"))
        try context.save()

        let text = meeting.assembledContextText()

        #expect(text.hasPrefix(meeting.assembledTranscriptText()))
        #expect(text.contains(AttachmentPromptContext.header))
        #expect(text.hasSuffix("=== 📄 Document: Budget.pdf ===\nTotal: 1.2M"))
    }

    @Test func attachmentsAloneDoNotMakeAContext() throws {
        let (meeting, context) = try makeMeeting()
        context.insert(MeetingAttachment(meeting: meeting, fileName: "a.pdf", displayName: "Budget.pdf", extractedText: "Total"))
        try context.save()

        #expect(meeting.assembledContextText().isEmpty)
    }
}
