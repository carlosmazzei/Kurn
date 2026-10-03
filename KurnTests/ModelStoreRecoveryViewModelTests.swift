//
//  ModelStoreRecoveryViewModelTests.swift
//  KurnTests
//
//  `ModelStoreRecoveryViewModel` against a throwaway Application Support
//  directory holding synthetic store files (never a real SwiftData store, the
//  same approach as `ModelStoreBackupManagerTests`): restore and fresh start
//  move the live store aside and ask the caller to reopen, a missing backup
//  surfaces an error instead, and the diagnostics export carries no content.
//

import Foundation
import Testing
@testable import Kurn

@MainActor
struct ModelStoreRecoveryViewModelTests {

    private final class Directory {
        let url: URL
        var reopenCount = 0

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ModelStoreRecoveryViewModelTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func writeLiveStore(_ content: String) throws {
            for suffix in [""] + ModelStoreProtection.sidecarSuffixes {
                try Data(content.utf8).write(to: url.appendingPathComponent(ModelStoreProtection.baseName + suffix))
            }
        }

        var liveContent: String? {
            let file = url.appendingPathComponent(ModelStoreProtection.baseName)
            return (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
        }

        @MainActor
        func viewModel() -> ModelStoreRecoveryViewModel {
            ModelStoreRecoveryViewModel(appSupportDirectory: url) { [weak self] in
                self?.reopenCount += 1
            }
        }
    }

    @Test func restoringABackupBringsItsFilesBackAndAsksToReopen() throws {
        let directory = try Directory()
        try directory.writeLiveStore("backed up")
        _ = try ModelStoreBackupManager(appSupportDirectory: directory.url).createBackupIfLiveStoreExists()
        try directory.writeLiveStore("broken")
        let viewModel = directory.viewModel()
        let generation = try #require(viewModel.backupGenerations.first)

        viewModel.restore(generation)

        #expect(directory.liveContent == "backed up")
        #expect(directory.reopenCount == 1)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isPerformingAction)
    }

    @Test func restoringAMissingGenerationReportsAnErrorAndDoesNotReopen() throws {
        let directory = try Directory()
        let viewModel = directory.viewModel()
        #expect(viewModel.backupGenerations.isEmpty)

        viewModel.restore(ModelStoreBackupGeneration(
            id: "missing", createdAt: Date(), schemaVersion: "3", appVersion: "1.0", appBuild: "1"
        ))

        #expect(viewModel.errorMessage != nil)
        #expect(directory.reopenCount == 0)
    }

    @Test func aFreshStartQuarantinesTheLiveStore() throws {
        let directory = try Directory()
        try directory.writeLiveStore("broken")
        let viewModel = directory.viewModel()

        viewModel.confirmedFreshStart()

        #expect(directory.liveContent == nil)
        #expect(directory.reopenCount == 1)
    }

    @Test func salvageWithoutALiveStoreIsUnavailable() throws {
        let directory = try Directory()
        let viewModel = directory.viewModel()

        viewModel.attemptSalvage()

        #expect(viewModel.salvageResult == .unavailable)
        #expect(viewModel.shareItem == nil)
    }

    @Test func salvageOfAFileThatIsNotSQLiteFails() throws {
        let directory = try Directory()
        try directory.writeLiveStore("not a database")
        let viewModel = directory.viewModel()

        viewModel.attemptSalvage()

        guard case .failed = viewModel.salvageResult else {
            Issue.record("expected a junk store to fail salvage")
            return
        }
        #expect(viewModel.shareItem == nil)
    }

    @Test func diagnosticsListTheReasonAndGenerationsOnly() throws {
        let directory = try Directory()
        let empty = directory.viewModel()
        empty.exportDiagnostics(failure: ModelStoreOpenFailure(reason: .storageFull))
        let emptyURL = try #require(empty.shareItem?.urls.first)
        let emptyText = try String(contentsOf: emptyURL, encoding: .utf8)
        #expect(emptyText.contains("Reason: storageFull"))
        #expect(emptyText.contains("(none)"))

        try directory.writeLiveStore("backed up")
        _ = try ModelStoreBackupManager(appSupportDirectory: directory.url).createBackupIfLiveStoreExists()
        let withBackup = directory.viewModel()
        withBackup.exportDiagnostics(failure: ModelStoreOpenFailure(reason: .corruptOrUnknown))
        let url = try #require(withBackup.shareItem?.urls.first)
        let text = try String(contentsOf: url, encoding: .utf8)
        let generation = try #require(withBackup.backupGenerations.first)
        #expect(text.contains("model_store_open.corruptOrUnknown"))
        #expect(text.contains(generation.id))
        #expect(!text.contains("backed up"))
    }
}
