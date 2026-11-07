import Foundation
import KurnCore

enum DocumentExport {
    static let formats: [MeetingExportFormat] = [.standard, .docx, .html]

    static func file(title: String, markdown: String, format: MeetingExportFormat) throws -> URL {
        if format == .standard {
            return try MeetingExport.temporaryFile(markdown: markdown, suggestedName: title)
        }
        let document = ExportDocument(title: title, dateLine: "", properties: .init(date: Date()), blocks: [.markdown(markdown)])
        let data = try format.data(for: document, pageSize: .a4)
        return try MeetingExport.temporaryFile(data: data, suggestedName: title, fileExtension: format.fileExtension)
    }
}
