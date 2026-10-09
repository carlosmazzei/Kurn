//
//  DOCXExportRenderer.swift
//  KurnCore
//
//  A Word (.docx) document for an `ExportDocument`, written directly as
//  Office Open XML: six small parts in a stored ZIP (`ZipArchiveWriter`).
//  It opens in Word, Pages, Google Docs and LibreOffice.
//
//  Real paragraph styles (Title, Heading 1–6, Quote, Code) rather than
//  hard-formatted runs, so the document has a navigation outline in Word and
//  restyles in one place. Lists are indented paragraphs with a literal glyph
//  instead of Word numbering definitions — `numbering.xml` is the most
//  fragile part of the format, and a summary's lists do not need restarting
//  or renumbering.
//

import Foundation

public enum DOCXExportRenderer {
    public static func render(_ document: ExportDocument, pageSize: ExportPageSize = .a4) throws -> Data {
        var zip = ZipArchiveWriter()
        try zip.add(path: "[Content_Types].xml", text: contentTypes)
        try zip.add(path: "_rels/.rels", text: packageRelationships)
        try zip.add(path: "docProps/core.xml", text: coreProperties(for: document))
        try zip.add(path: "docProps/app.xml", text: appProperties)
        try zip.add(path: "word/_rels/document.xml.rels", text: documentRelationships)
        try zip.add(path: "word/styles.xml", text: styles(languageCode: document.labels.languageCode))
        try zip.add(path: "word/document.xml", text: documentXML(for: document, pageSize: pageSize))
        return zip.finalized()
    }

    // MARK: - Document body

    static func documentXML(for document: ExportDocument, pageSize: ExportPageSize) -> String {
        var body = paragraph(style: "Title", runs: [InlineRun(document.title)])
        var meta = document.dateLine
        if let duration = document.duration {
            meta += " · \(document.labels.duration): \(duration)"
        }
        body += paragraph(style: "Subtitle", runs: [InlineRun(meta)])
        if !document.properties.tags.isEmpty {
            body += paragraph(style: "Subtitle", runs: [InlineRun(document.properties.tags.map { "#\($0)" }.joined(separator: "  "))])
        }
        for block in document.richBlocks {
            body += render(block)
        }
        let size = pageSize.twips
        body += "<w:sectPr><w:pgSz w:w=\"\(size.width)\" w:h=\"\(size.height)\"/>"
        body += "<w:pgMar w:top=\"1440\" w:right=\"1300\" w:bottom=\"1440\" w:left=\"1300\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/>"
        body += "</w:sectPr>"
        return xmlDeclaration
            + "<w:document xmlns:w=\"\(wordNamespace)\"><w:body>\(body)</w:body></w:document>"
    }

    private static func render(_ block: ExportRichBlock) -> String {
        switch block {
        case .heading(let level, let runs):
            return paragraph(style: "Heading\(min(6, max(1, level - 1)))", runs: runs)
        case .paragraph(let runs):
            return paragraph(style: nil, runs: runs)
        case .listItem(let indent, let marker, let runs):
            // A hanging indent so wrapped lines align with the text, not the
            // glyph; each level adds a further 360 twips (a quarter inch).
            let left = 360 * (indent + 1)
            let properties = "<w:spacing w:after=\"60\"/><w:ind w:left=\"\(left)\" w:hanging=\"360\"/>"
            let glyph = InlineRun(PlainTextExportRenderer.listMarker(marker) + "\t")
            return paragraph(style: nil, extraProperties: properties, runs: [glyph] + runs)
        case .quote(let runs):
            return paragraph(style: "Quote", runs: runs)
        case .code(let code):
            return paragraph(style: "Code", runs: [InlineRun(code)])
        case .table(let headers, let rows):
            return table(headers: headers, rows: rows)
        case .rule:
            return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr></w:pPr></w:p>"
        }
    }

    static func paragraph(style: String?, extraProperties: String = "", runs: [InlineRun]) -> String {
        var properties = ""
        if let style {
            properties += "<w:pStyle w:val=\"\(style)\"/>"
        }
        properties += extraProperties
        let pPr = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
        return "<w:p>\(pPr)\(runs.map(run).joined())</w:p>"
    }

    /// One `<w:r>`; newlines and tabs inside the text become Word's own break
    /// and tab elements, which `<w:t>` cannot carry.
    static func run(_ run: InlineRun) -> String {
        var properties = ""
        if run.style.contains(.code) {
            properties += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
        }
        if run.style.contains(.bold) { properties += "<w:b/>" }
        if run.style.contains(.italic) { properties += "<w:i/>" }
        if run.style.contains(.strikethrough) { properties += "<w:strike/>" }
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"

        var content = ""
        var pending = ""
        func flushText() {
            if !pending.isEmpty {
                content += "<w:t xml:space=\"preserve\">\(escape(pending))</w:t>"
                pending = ""
            }
        }
        for char in run.text {
            if char == "\n" || char == "\r\n" {
                flushText()
                content += "<w:br/>"
            } else if char == "\t" {
                flushText()
                content += "<w:tab/>"
            } else {
                pending.append(char)
            }
        }
        flushText()
        return "<w:r>\(rPr)\(content)</w:r>"
    }

    private static func table(headers: [[InlineRun]], rows: [[[InlineRun]]]) -> String {
        let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\""
        var out = "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            out += "<w:\(edge) \(border)/>"
        }
        out += "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr>"
        out += "<w:tblGrid>" + String(repeating: "<w:gridCol/>", count: max(1, headers.count)) + "</w:tblGrid>"
        let bold = headers.map { cell in cell.map { InlineRun($0.text, style: $0.style.union(.bold)) } }
        out += tableRow(bold, isHeader: true)
        for row in rows {
            out += tableRow(row, isHeader: false)
        }
        // Word expects a paragraph between a table and whatever follows it.
        return out + "</w:tbl><w:p/>"
    }

    private static func tableRow(_ cells: [[InlineRun]], isHeader: Bool) -> String {
        let rowProperties = isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : ""
        let content = cells.map { cell in
            "<w:tc>\(paragraph(style: nil, extraProperties: "<w:spacing w:after=\"0\"/>", runs: cell))</w:tc>"
        }.joined()
        return "<w:tr>\(rowProperties)\(content)</w:tr>"
    }

    // MARK: - XML text

    /// Escapes markup characters and drops what XML 1.0 cannot carry at all —
    /// C0 control characters other than tab, newline and carriage return. A
    /// stray one in a transcript would otherwise make Word refuse the file.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                let value = scalar.value
                if value < 0x20 || value == 0xFFFE || value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Package parts

    static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeRelationshipType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static let contentTypes = xmlDeclaration + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
    </Types>
    """

    static let packageRelationships = xmlDeclaration
        + "<Relationships xmlns=\"\(relationshipNamespace)\">"
        + "<Relationship Id=\"rId1\" Type=\"\(officeRelationshipType)/officeDocument\" Target=\"word/document.xml\"/>"
        + "<Relationship Id=\"rId2\" Type=\"\(relationshipNamespace)/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        + "<Relationship Id=\"rId3\" Type=\"\(officeRelationshipType)/extended-properties\" Target=\"docProps/app.xml\"/>"
        + "</Relationships>"

    static let documentRelationships = xmlDeclaration
        + "<Relationships xmlns=\"\(relationshipNamespace)\">"
        + "<Relationship Id=\"rId1\" Type=\"\(officeRelationshipType)/styles\" Target=\"styles.xml\"/>"
        + "</Relationships>"

    static let appProperties = xmlDeclaration
        + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">"
        + "<Application>Kurn</Application></Properties>"

    /// Title, keywords (the meeting's tags) and creation date, which is what
    /// Finder, Files and Word's own document info show.
    static func coreProperties(for document: ExportDocument) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var out = xmlDeclaration
        out += "<cp:coreProperties"
        out += " xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\""
        out += " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
        out += " xmlns:dcterms=\"http://purl.org/dc/terms/\""
        out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        out += "<dc:title>\(escape(document.title))</dc:title>"
        if !document.properties.tags.isEmpty {
            out += "<cp:keywords>\(escape(document.properties.tags.joined(separator: ", ")))</cp:keywords>"
        }
        let created = formatter.string(from: document.properties.date)
        out += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(created)</dcterms:created>"
        out += "</cp:coreProperties>"
        return out
    }

    /// `languageCode` becomes the document's default proofing language, so
    /// Word spell-checks a Portuguese export as Portuguese.
    static func styles(languageCode: String) -> String {
        let language = escape(languageCode)
        var out = xmlDeclaration + "<w:styles xmlns:w=\"\(wordNamespace)\">"
        out += "<w:docDefaults><w:rPrDefault><w:rPr>"
        out += "<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"Calibri\" w:cs=\"Calibri\"/>"
        out += "<w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/>"
        out += "<w:lang w:val=\"\(language)\" w:eastAsia=\"\(language)\" w:bidi=\"\(language)\"/></w:rPr></w:rPrDefault>"
        out += "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault>"
        out += "</w:docDefaults>"
        out += "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        out += paragraphStyle(
            id: "Title", name: "Title",
            paragraph: "<w:spacing w:after=\"60\"/>",
            run: "<w:b/><w:sz w:val=\"48\"/><w:szCs w:val=\"48\"/>"
        )
        out += paragraphStyle(
            id: "Subtitle", name: "Subtitle",
            paragraph: "<w:spacing w:after=\"60\"/>",
            run: "<w:color w:val=\"666666\"/>"
        )
        let headingSizes = [32, 28, 24, 22, 22, 22]
        for (index, size) in headingSizes.enumerated() {
            let level = index + 1
            let italic = level >= 5 ? "<w:i/>" : ""
            out += paragraphStyle(
                id: "Heading\(level)", name: "heading \(level)",
                paragraph: "<w:keepNext/><w:spacing w:before=\"\(level == 1 ? 360 : 240)\" w:after=\"80\"/><w:outlineLvl w:val=\"\(index)\"/>",
                run: "<w:b/>\(italic)<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/>"
            )
        }
        out += paragraphStyle(
            id: "Quote", name: "Quote",
            paragraph: "<w:pBdr><w:left w:val=\"single\" w:sz=\"12\" w:space=\"8\" w:color=\"BFBFBF\"/></w:pBdr><w:ind w:left=\"360\"/>",
            run: "<w:i/><w:color w:val=\"555555\"/>"
        )
        out += paragraphStyle(
            id: "Code", name: "Code",
            paragraph: "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/><w:spacing w:after=\"120\" w:line=\"240\" w:lineRule=\"auto\"/>",
            run: "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/><w:sz w:val=\"19\"/><w:szCs w:val=\"19\"/>"
        )
        out += "</w:styles>"
        return out
    }

    private static func paragraphStyle(id: String, name: String, paragraph: String, run: String) -> String {
        "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/>"
            + "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
            + "<w:pPr>\(paragraph)</w:pPr><w:rPr>\(run)</w:rPr></w:style>"
    }
}
