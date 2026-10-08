//
//  PDFExportRenderer.swift
//  Kurn
//
//  A paginated PDF for an `ExportDocument`, typeset with Core Text straight
//  into a Core Graphics PDF context. Neither framework is tied to the main
//  actor (unlike UIKit's renderers and TextKit), so the share sheet renders a
//  long meeting's PDF in the background instead of freezing the screen.
//
//  Core Text does the hard part: line breaking, font fallback for scripts the
//  base font lacks (CJK, Cyrillic, emoji) and pagination, one `CTFrame` per
//  page. What it does not draw — strikethrough, code backgrounds — is carried
//  by font and colour instead.
//

import CoreGraphics
import CoreText
import Foundation
import KurnCore

enum PDFExportRenderer {
    static let margin: CGFloat = 56
    /// A runaway document stops here rather than allocating without bound.
    static let maxPages = 5_000

    static func render(_ document: ExportDocument, pageSize: ExportPageSize) -> Data {
        let size = pageSize.points
        var mediaBox = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let output = NSMutableData()
        let info: [CFString: Any] = [
            kCGPDFContextTitle: document.title,
            kCGPDFContextCreator: "Kurn"
        ]
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary)
        else { return Data() }

        let frames = pages(for: attributedText(for: document), in: mediaBox)
        for (index, frame) in frames.enumerated() {
            context.beginPDFPage(nil)
            // A PDF context's origin is bottom-left, which is Core Text's own
            // convention: frames draw without a flip.
            CTFrameDraw(frame, context)
            drawFooter("\(index + 1) / \(frames.count)", in: context, mediaBox: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// One frame per page. An empty document still gets a page; a frame that
    /// fits nothing ends the loop rather than spinning on it.
    static func pages(for text: NSAttributedString, in mediaBox: CGRect) -> [CTFrame] {
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let path = CGPath(rect: mediaBox.insetBy(dx: margin, dy: margin), transform: nil)
        var frames: [CTFrame] = []
        var location = 0
        repeat {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            frames.append(frame)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < text.length && frames.count < maxPages
        return frames
    }

    private static func drawFooter(_ text: String, in context: CGContext, mediaBox: CGRect) {
        let attributes = Style.attributes(font: Style.font(size: 9), color: Style.secondaryColor)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: mediaBox.midX - CGFloat(width) / 2, y: margin / 2)
        CTLineDraw(line, context)
    }

    // MARK: - Typesetting

    static func attributedText(for document: ExportDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        append([InlineRun(document.title)], to: out, font: Style.font(size: 24, bold: true), paragraph: Style.paragraph(after: 4))
        var meta = document.dateLine
        if let duration = document.duration {
            meta += " · \(ExportDocument.durationLabel): \(duration)"
        }
        if !document.properties.tags.isEmpty {
            meta += "\n" + document.properties.tags.map { "#\($0)" }.joined(separator: "  ")
        }
        append([InlineRun(meta)], to: out, font: Style.font(size: 10), color: Style.secondaryColor, paragraph: Style.paragraph(after: 14))
        for block in document.richBlocks {
            append(block, to: out)
        }
        return out
    }

    private static func append(_ block: ExportRichBlock, to out: NSMutableAttributedString) {
        switch block {
        case .heading(let level, let runs):
            let size: CGFloat = level <= 2 ? 17 : (level == 3 ? 14 : 12)
            append(runs, to: out, font: Style.font(size: size, bold: true), paragraph: Style.paragraph(before: level <= 2 ? 16 : 10, after: 4))
        case .paragraph(let runs):
            append(runs, to: out, font: Style.font(size: Style.bodySize), paragraph: Style.paragraph(after: 6))
        case .listItem(let indent, let marker, let runs):
            let head = Style.listIndent * CGFloat(indent + 1)
            let glyph = InlineRun(PlainTextExportRenderer.listMarker(marker) + "\t")
            append(
                [glyph] + runs, to: out, font: Style.font(size: Style.bodySize),
                paragraph: Style.paragraph(after: 3, headIndent: head, firstLineHeadIndent: head - Style.listIndent)
            )
        case .quote(let runs):
            append(
                runs, to: out, font: Style.font(size: Style.bodySize, italic: true), color: Style.secondaryColor,
                paragraph: Style.paragraph(after: 6, headIndent: Style.listIndent, firstLineHeadIndent: Style.listIndent)
            )
        case .code(let code):
            append(
                [InlineRun(code, style: .code)], to: out, font: Style.font(size: Style.bodySize),
                paragraph: Style.paragraph(after: 6, headIndent: Style.listIndent, firstLineHeadIndent: Style.listIndent)
            )
        case .table(let headers, let rows):
            let header = headers.map { cell in cell.map { InlineRun($0.text, style: $0.style.union(.bold)) } }
            for row in [header] + rows {
                let joined = row.enumerated().flatMap { index, cell in
                    index == 0 ? cell : [InlineRun("  |  ")] + cell
                }
                append(joined, to: out, font: Style.font(size: Style.bodySize - 1), paragraph: Style.paragraph(after: 2))
            }
            append([InlineRun("")], to: out, font: Style.font(size: 4), paragraph: Style.paragraph(after: 4))
        case .rule:
            append(
                [InlineRun("———")], to: out, font: Style.font(size: Style.bodySize), color: Style.secondaryColor,
                paragraph: Style.paragraph(before: 4, after: 8)
            )
        }
    }

    /// Appends one paragraph: each run in `font` adjusted for its inline
    /// style, then a newline carrying the same paragraph style.
    private static func append(
        _ runs: [InlineRun],
        to out: NSMutableAttributedString,
        font: CTFont,
        color: CGColor = Style.textColor,
        paragraph: CTParagraphStyle
    ) {
        for run in runs {
            var runFont = font
            var runColor = color
            let size = CTFontGetSize(font)
            if run.style.contains(.code) {
                runFont = Style.monospacedFont(size: size)
            } else if run.style.contains(.bold) || run.style.contains(.italic) {
                let traits = CTFontGetSymbolicTraits(font)
                runFont = Style.font(
                    size: size,
                    bold: run.style.contains(.bold) || traits.contains(.traitBold),
                    italic: run.style.contains(.italic) || traits.contains(.traitItalic)
                )
            }
            if run.style.contains(.strikethrough) {
                runColor = Style.secondaryColor
            }
            var attributes = Style.attributes(font: runFont, color: runColor)
            attributes[Style.paragraphKey] = paragraph
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        var attributes = Style.attributes(font: font, color: color)
        attributes[Style.paragraphKey] = paragraph
        out.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    // MARK: - Style

    enum Style {
        static let bodySize: CGFloat = 11
        static let listIndent: CGFloat = 16
        static var textColor: CGColor { CGColor(gray: 0.1, alpha: 1) }
        static var secondaryColor: CGColor { CGColor(gray: 0.42, alpha: 1) }

        static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)

        static func attributes(font: CTFont, color: CGColor) -> [NSAttributedString.Key: Any] {
            [fontKey: font, colorKey: color]
        }

        /// The system UI font, so Latin text matches the app; Core Text
        /// falls back per character for scripts it lacks.
        static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
            let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            guard italic else { return base }
            return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) ?? base
        }

        static func monospacedFont(size: CGFloat) -> CTFont {
            CTFontCreateWithName("Menlo-Regular" as CFString, size * 0.92, nil)
        }

        static func paragraph(
            before: CGFloat = 0,
            after: CGFloat,
            headIndent: CGFloat = 0,
            firstLineHeadIndent: CGFloat = 0
        ) -> CTParagraphStyle {
            let values: [CGFloat] = [before, after, headIndent, firstLineHeadIndent, 1.15]
            let tabStop = CTTextTabCreate(.left, Double(headIndent), nil)
            let tabStops = [tabStop] as CFArray
            return values.withUnsafeBufferPointer { buffer in
                withUnsafePointer(to: tabStops) { tabs in
                    let size = MemoryLayout<CGFloat>.size
                    // `buffer` is non-empty: five values above.
                    let base = buffer.baseAddress!
                    let settings = [
                        CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: size, value: base),
                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: base + 1),
                        CTParagraphStyleSetting(spec: .headIndent, valueSize: size, value: base + 2),
                        CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: size, value: base + 3),
                        CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: size, value: base + 4),
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tabs)
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }
}
