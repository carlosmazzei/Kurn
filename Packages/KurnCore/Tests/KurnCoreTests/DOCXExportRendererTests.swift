//
//  DOCXExportRendererTests.swift
//  KurnCoreTests
//
//  The Word export is a ZIP of XML parts. These tests read the archive back
//  with a minimal stored-entry reader, check every part is well-formed XML,
//  and check the body carries real styles rather than Markdown syntax.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import KurnCore

struct DOCXExportRendererTests {

    private func sample() -> ExportDocument {
        ExportDocument(
            title: "Q&A <review>",
            dateLine: "Today",
            duration: "1:00",
            properties: ExportDocument.Properties(date: Date(timeIntervalSince1970: 0), tags: ["weekly"]),
            blocks: [
                .heading(level: 2, text: "Summary"),
                .markdown("We **won** _big_.\n\n- [x] Ship\n  - nested `code`\n\n> quoted\n\n```\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---"),
                .utterance(ExportDocument.Utterance(timestamp: "0:05", speaker: "Ana", text: "Bell\u{07} line\nnext\tcol"))
            ]
        )
    }

    @Test func packageHasEveryRequiredPart() throws {
        let entries = try ZipTestReader.entries(in: DOCXExportRenderer.render(sample()))
        #expect(entries.map(\.name) == [
            "[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "docProps/app.xml",
            "word/_rels/document.xml.rels", "word/styles.xml", "word/document.xml"
        ])
    }

    @Test func everyPartIsWellFormedXML() throws {
        for entry in try ZipTestReader.entries(in: DOCXExportRenderer.render(sample())) {
            let parser = XMLParser(data: entry.contents)
            #expect(parser.parse(), "\(entry.name) is not well-formed")
        }
    }

    @Test func bodyUsesStylesNotMarkdownSyntax() throws {
        let body = try documentXML()
        #expect(body.contains("<w:pStyle w:val=\"Title\"/>"))
        #expect(body.contains("Q&amp;A &lt;review&gt;"))
        #expect(body.contains("<w:pStyle w:val=\"Heading1\"/>"))
        #expect(body.contains("<w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">won</w:t>"))
        #expect(body.contains("<w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\">big</w:t>"))
        #expect(body.contains("☑"))
        #expect(body.contains("w:left=\"720\""))
        #expect(body.contains("Courier New"))
        #expect(body.contains("<w:pStyle w:val=\"Quote\"/>"))
        #expect(body.contains("<w:pStyle w:val=\"Code\"/>"))
        #expect(body.contains("<w:tbl>"))
        #expect(body.contains("<w:tblHeader/>"))
        #expect(body.contains("<w:pBdr>"))
        #expect(!body.contains("**"))
    }

    @Test func transcriptTextIsSanitizedForXML() throws {
        let body = try documentXML()
        // The BEL control character cannot exist in XML 1.0 and is dropped.
        #expect(!body.contains("\u{07}"))
        #expect(body.contains("Bell line</w:t><w:br/><w:t xml:space=\"preserve\">next</w:t><w:tab/>"))
    }

    @Test func pageSizeAndCoreProperties() throws {
        let entries = try ZipTestReader.entries(in: DOCXExportRenderer.render(sample(), pageSize: .letter))
        let body = try #require(entries.first { $0.name == "word/document.xml" }).text
        #expect(body.contains("<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"))
        let core = try #require(entries.first { $0.name == "docProps/core.xml" }).text
        #expect(core.contains("<dc:title>Q&amp;A &lt;review&gt;</dc:title>"))
        #expect(core.contains("<cp:keywords>weekly</cp:keywords>"))
        #expect(core.contains("1970-01-01T00:00:00Z"))
    }

    @Test func outputIsDeterministic() throws {
        #expect(try DOCXExportRenderer.render(sample()) == DOCXExportRenderer.render(sample()))
    }

    private func documentXML() throws -> String {
        let entries = try ZipTestReader.entries(in: DOCXExportRenderer.render(sample()))
        return try #require(entries.first { $0.name == "word/document.xml" }).text
    }
}

// MARK: - ZIP

struct ZipArchiveWriterTests {

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func entriesRoundTrip() throws {
        var writer = ZipArchiveWriter()
        try writer.add(path: "a.txt", text: "hello")
        try writer.add(path: "dir/b.bin", contents: Data([0, 1, 2, 255]))
        try writer.add(path: "empty", contents: Data())
        let entries = try ZipTestReader.entries(in: writer.finalized())
        #expect(entries.map(\.name) == ["a.txt", "dir/b.bin", "empty"])
        #expect(entries[0].text == "hello")
        #expect(entries[1].contents == Data([0, 1, 2, 255]))
        #expect(entries[2].contents.isEmpty)
    }

    @Test func emptyArchiveIsJustTheEndRecord() {
        let data = ZipArchiveWriter().finalized()
        #expect(data.count == 22)
        #expect(Array(data.prefix(4)) == [0x50, 0x4B, 0x05, 0x06])
    }
}

/// Reads a stored-only ZIP through its central directory, verifying each
/// entry's CRC and that local and central headers agree — the checks a real
/// unzip performs before it trusts an entry.
enum ZipTestReader {
    struct Entry {
        let name: String
        let contents: Data
        var text: String { String(decoding: contents, as: UTF8.self) }
    }

    struct Malformed: Error {}

    static func entries(in data: Data) throws -> [Entry] {
        let bytes = Array(data)
        guard bytes.count >= 22 else { throw Malformed() }
        let end = bytes.count - 22
        guard u32(bytes, end) == 0x0605_4B50 else { throw Malformed() }
        let count = Int(u16(bytes, end + 10))
        var cursor = Int(u32(bytes, end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard u32(bytes, cursor) == 0x0201_4B50, u16(bytes, cursor + 10) == 0 else { throw Malformed() }
            let crc = u32(bytes, cursor + 16)
            let size = Int(u32(bytes, cursor + 20))
            let nameLength = Int(u16(bytes, cursor + 28))
            let offset = Int(u32(bytes, cursor + 42))
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            guard u32(bytes, offset) == 0x0403_4B50, Int(u16(bytes, offset + 26)) == nameLength else { throw Malformed() }
            let start = offset + 30 + nameLength + Int(u16(bytes, offset + 28))
            let contents = Data(bytes[start..<(start + size)])
            guard CRC32.checksum(contents) == crc, u32(bytes, offset + 14) == crc else { throw Malformed() }
            entries.append(Entry(name: name, contents: contents))
            cursor += 46 + nameLength
        }
        return entries
    }

    private static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(u16(bytes, index)) | UInt32(u16(bytes, index + 2)) << 16
    }
}
