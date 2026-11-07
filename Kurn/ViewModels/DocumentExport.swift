import Foundation
import KurnCore

enum DocumentExport {
    static let formats: [MeetingExportFormat] = [.standard, .docx, .html]

    static func file(title: String, markdown: String, format: MeetingExportFormat) throws -> URL {
        if format == .standard {
            return try MeetingExport.temporaryFile(markdown: markdown, suggestedName: title)
        }
        let document = ExportDocument(title: title, dateLine: "", properties: .init(date: Date()), blocks: [.markdown(body(title: title, markdown: markdown))])
        let data = try format.data(for: document, pageSize: .a4)
        return try MeetingExport.temporaryFile(data: data, suggestedName: title, fileExtension: format.fileExtension)
    }

    static func body(title: String, markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return markdown }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("# ") else { return markdown }
        let heading = first.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        guard heading.caseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { return markdown }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }
}
