//
//  IncomingFileInboxTests.swift
//  KurnTests
//
//  PDFs shared into the app wait in `IncomingFileInbox` until the user picks
//  a meeting. Only local PDFs are queued, each once; finishing deletes the
//  copies iOS placed in the Inbox and nothing outside it; and stale copies a
//  killed process left behind are swept. Every test uses an Inbox directory
//  of its own.
//

import Foundation
import Testing
@testable import Kurn

@MainActor
struct IncomingFileInboxTests {

    private func makeInboxDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingFileInboxTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("%PDF".utf8).write(to: url)
        return url
    }

    @Test func acceptsOnlyLocalPDFs() {
        #expect(IncomingFileInbox.accepts(URL(fileURLWithPath: "/tmp/agenda.pdf")))
        #expect(IncomingFileInbox.accepts(URL(fileURLWithPath: "/tmp/AGENDA.PDF")))
        #expect(!IncomingFileInbox.accepts(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(!IncomingFileInbox.accepts(URL(string: "https://example.com/agenda.pdf")!))
    }

    @Test func receiveQueuesEachPDFOnceInArrivalOrder() throws {
        let inbox = IncomingFileInbox(inboxDirectory: try makeInboxDirectory())
        let first = URL(fileURLWithPath: "/tmp/a.pdf")
        let second = URL(fileURLWithPath: "/tmp/b.pdf")

        #expect(!inbox.hasPendingFiles)
        #expect(inbox.receive(first))
        #expect(inbox.receive(second))
        #expect(inbox.receive(first))
        #expect(!inbox.receive(URL(fileURLWithPath: "/tmp/c.docx")))

        #expect(inbox.pendingFiles == [first, second])
        #expect(inbox.hasPendingFiles)
    }

    @Test func finishDeletesInboxCopiesButNeverFilesOutsideIt() throws {
        let inboxDirectory = try makeInboxDirectory()
        defer { try? FileManager.default.removeItem(at: inboxDirectory.deletingLastPathComponent()) }
        let outside = inboxDirectory.deletingLastPathComponent()
        let shared = try makeFile(named: "shared.pdf", in: inboxDirectory)
        let usersOwn = try makeFile(named: "own.pdf", in: outside)
        let inbox = IncomingFileInbox(inboxDirectory: inboxDirectory)
        inbox.receive(shared)
        inbox.receive(usersOwn)

        inbox.finish()

        #expect(!inbox.hasPendingFiles)
        #expect(!FileManager.default.fileExists(atPath: shared.path))
        #expect(FileManager.default.fileExists(atPath: usersOwn.path))
    }

    @Test func sweepRemovesStaleCopiesAndKeepsRecentAndPendingOnes() throws {
        let inboxDirectory = try makeInboxDirectory()
        defer { try? FileManager.default.removeItem(at: inboxDirectory.deletingLastPathComponent()) }
        let stale = try makeFile(named: "stale.pdf", in: inboxDirectory)
        let recent = try makeFile(named: "recent.pdf", in: inboxDirectory)
        let pending = try makeFile(named: "pending.pdf", in: inboxDirectory)
        let old = Date(timeIntervalSinceNow: -3 * 24 * 60 * 60)
        for url in [stale, pending] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let inbox = IncomingFileInbox(inboxDirectory: inboxDirectory)
        inbox.receive(pending)

        inbox.sweepStaleCopies()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: pending.path))
    }

    @Test func sweepWithoutAnInboxDirectoryIsHarmless() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        IncomingFileInbox(inboxDirectory: missing).sweepStaleCopies()
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
