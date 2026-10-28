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
    func share() async -> [URL]? {
        let items = export.exportItems()
        guard !items.isEmpty, !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        let writeFile = writeFile
        let pageSize = pageSize
        let result = await Task.detached(priority: .userInitiated) {
            Result { try items.map { try writeFile($0, pageSize) } }
        }.value
        switch result {
        case .success(let urls):
            return urls
        case .failure(let failure):
            error = .audioError(failure.localizedDescription)
            return nil
        }
    }
}
