import Foundation
import KurnCore
import Testing
@testable import Kurn

struct DocumentExportTests {
    @Test func exportsMarkdownHTMLAndDOCXWithSharedRenderers() throws {
        for format in DocumentExport.formats {
            let url = try DocumentExport.file(title: "Report", markdown: "# Report\n\n**Bold** text", format: format)
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try Data(contentsOf: url)
            #expect(url.pathExtension == format.fileExtension)
            #expect(!data.isEmpty)
            if format == .standard { #expect(String(decoding: data, as: UTF8.self) == "# Report\n\n**Bold** text") }
            if format == .html { #expect(String(decoding: data, as: UTF8.self).contains("<strong>Bold</strong>")) }
            if format == .docx { #expect(Array(data.prefix(2)) == [0x50, 0x4b]) }
        }
    }
}
