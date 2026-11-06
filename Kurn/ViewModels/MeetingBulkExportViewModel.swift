//
//  MeetingBulkExportViewModel.swift
//  Kurn
//
//  Screen state behind `MeetingBulkExportView`: the export plan
//  (`MeetingBulkExport`) the controls edit, writing the files off the main
//  actor, Copy All and the failure to show. File writing and the pasteboard
//  are constructor seams so tests reach every path without either.
//

import Foundation
import KurnCore
import Observation

@MainActor
@Observable
final class MeetingBulkExportViewModel {
    typealias FileWriter = @Sendable (MeetingExportItem, ExportPageSize) throws -> URL

    /// The plan the toggles and pickers edit.
    var export: MeetingBulkExport
    private(set) var isExporting = false
    /// True for a moment after Copy All, so the button can confirm it.
    private(set) var didCopy = false
    var error: AppError?

    @ObservationIgnored private let writeFile: FileWriter
    @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Void
    @ObservationIgnored private let pageSize: ExportPageSize
    @ObservationIgnored private let copyConfirmation: Duration

    init(
        meetings: [Meeting],
        writeFile: @escaping FileWriter = { try $0.writeTemporaryFile(pageSize: $1) },
        copyToPasteboard: @escaping @MainActor (String) -> Void = { MeetingPasteboard.copy($0) },
        pageSize: ExportPageSize = .preferred(forRegion: Locale.current.region?.identifier),
        copyConfirmation: Duration = .seconds(1.5)
    ) {
        export = MeetingBulkExport(meetings: meetings)
        self.writeFile = writeFile
        self.copyToPasteboard = copyToPasteboard
        self.pageSize = pageSize
        self.copyConfirmation = copyConfirmation
    }

    var canShare: Bool { export.canExport && !isExporting }

    /// Everything exportable on the clipboard, grouped by meeting.
    func copyAll() {
        let text = export.clipboardText()
        guard !text.isEmpty else { return }
        copyToPasteboard(text)
        didCopy = true
        Task { [copyConfirmation] in
            try? await Task.sleep(for: copyConfirmation)
            self.didCopy = false
        }
    }

    /// Builds the documents here, on the main actor where the meetings live,
    /// then renders and writes the files in the background. Returns the
    /// files to hand the share sheet, or `nil` when there was nothing to
    /// write, an export is already running, or writing failed (`error` says
    /// why).
    func share(
        fileSystem: any FileSystem = SystemFileSystem(),
        recordEvent: @escaping @Sendable (ReliabilityEvent) -> Void = ReliabilityLog.record
    ) async -> [URL]? {
        let items = export.exportItems()
        guard !items.isEmpty, !isExporting else { return nil }
        isExporting = true
        error = nil
        defer { isExporting = false }
        let writeFile = writeFile
        let pageSize = pageSize
        let operationID = OperationID()
        if Task.isCancelled {
            recordEvent(ReliabilityEvent(
                operationID: operationID, operation: "bulk_export", outcome: .cancelled, code: "cancelled"
            ))
            return nil
        }
        let work = Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            return Result {
                do {
                    for item in items {
                        try Task.checkCancellation()
                        urls.append(try writeFile(item, pageSize))
                    }
                    try Task.checkCancellation()
                    return urls
                } catch {
                    Self.removeExports(urls, fileSystem: fileSystem, operationID: operationID, recordEvent: recordEvent)
                    throw error
                }
            }
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        switch result {
        case .success(let urls):
            if Task.isCancelled {
                Self.removeExports(urls, fileSystem: fileSystem, operationID: operationID, recordEvent: recordEvent)
                recordEvent(ReliabilityEvent(
                    operationID: operationID, operation: "bulk_export", outcome: .cancelled, code: "cancelled"
                ))
                return nil
            }
            return urls
        case .failure(let failure):
            let cancelled = Task.isCancelled || failure is CancellationError
            recordEvent(ReliabilityEvent(
                operationID: operationID, operation: "bulk_export", stage: "write",
                outcome: cancelled ? .cancelled : .failed, code: cancelled ? "cancelled" : "write_failed"
            ))
            if !cancelled { error = .audioError(failure.localizedDescription) }
            return nil
        }
    }

    private nonisolated static func removeExports(
        _ urls: [URL],
        fileSystem: any FileSystem,
        operationID: OperationID,
        recordEvent: @Sendable (ReliabilityEvent) -> Void
    ) {
        for url in urls {
            do {
                try fileSystem.removeItem(at: url)
            } catch {
                recordEvent(ReliabilityEvent(
                    operationID: operationID, operation: "bulk_export", stage: "rollback",
                    outcome: .failed, code: "cleanup_failed"
                ))
            }
        }
    }
}
