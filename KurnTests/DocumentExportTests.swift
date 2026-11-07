import Foundation
import KurnCore
import Testing
@testable import Kurn

struct DocumentExportTests {
    @Test func richExportsRemoveOnlyMatchingLeadingH1AndMarkdownStaysVerbatim() throws {
        #expect(DocumentExport.body(title: " Report ", markdown: "\n  # report  \n\nBody") == "\n\nBody")
        for markdown in ["", " \n", "# Different\nBody", "## Report\nBody", "Body\n# Report"] {
            #expect(DocumentExport.body(title: "Report", markdown: markdown) == markdown)
        }
        for format in DocumentExport.formats {
            let markdown = "# Report\n\nBody"
            let url = try DocumentExport.file(title: "Report", markdown: markdown, format: format)
            defer { try? FileManager.default.removeItem(at: url) }
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            if format == .standard { #expect(text == markdown) }
            if format == .html { #expect(text.components(separatedBy: "<h1>Report</h1>").count == 2) }
            if format == .docx { #expect(text.components(separatedBy: ">Report</w:t>").count == 2) }
        }
    }

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
