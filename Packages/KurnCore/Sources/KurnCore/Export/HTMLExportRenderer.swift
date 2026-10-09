//
//  HTMLExportRenderer.swift
//  KurnCore
//
//  A single self-contained HTML page for an `ExportDocument`: inline styles,
//  no script, no external resource and no link — it opens in any browser,
//  pastes into Google Docs or a wiki with its formatting, and prints cleanly.
//  Every piece of text is escaped; LLM-written links keep only their text
//  (see `InlineMarkdown`).
//

import Foundation

public enum HTMLExportRenderer {
    public static func render(_ document: ExportDocument) -> String {
        var body = "<header>\n<h1>\(escape(document.title))</h1>\n"
        var meta = escape(document.dateLine)
        if let duration = document.duration {
            meta += " · \(escape(document.labels.duration)): \(escape(duration))"
        }
        body += "<p class=\"meta\">\(meta)</p>\n"
        if !document.properties.tags.isEmpty {
            let tags = document.properties.tags.map { "<span class=\"tag\">\(escape($0))</span>" }
            body += "<p class=\"tags\">\(tags.joined(separator: " "))</p>\n"
        }
        body += "</header>\n"
        body += renderBlocks(document.richBlocks)

        return """
        <!DOCTYPE html>
        <html lang="\(escape(document.labels.languageCode))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Kurn">
        <meta name="date" content="\(MarkdownExportRenderer.isoDate(document.properties.date))">
        <title>\(escape(document.title))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>

        """
    }

    static let stylesheet = """
    :root { color-scheme: light dark; }
    body { font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; margin: 0; }
    main { max-width: 46rem; margin: 0 auto; padding: 2rem 1.25rem 4rem; }
    h1 { font-size: 1.9rem; line-height: 1.2; margin: 0 0 .35rem; }
    h2 { font-size: 1.35rem; margin: 2rem 0 .6rem; padding-bottom: .25rem; border-bottom: 1px solid rgba(127,127,127,.3); }
    h3 { font-size: 1.1rem; margin: 1.4rem 0 .4rem; }
    h4, h5, h6 { font-size: 1rem; margin: 1.1rem 0 .3rem; }
    p { margin: .5rem 0; }
    .meta { color: #6b6b6b; margin: 0; }
    .tags { margin: .4rem 0 0; }
    .tag { display: inline-block; font-size: .8rem; padding: .05rem .5rem; border-radius: 1rem; background: rgba(127,127,127,.15); }
    ul.items { list-style: none; padding: 0; margin: .5rem 0; }
    ul.items li { display: flex; gap: .5rem; margin: .2rem 0; }
    ul.items .marker { flex: none; min-width: 1.1rem; }
    blockquote { margin: .6rem 0; padding: .1rem 0 .1rem 1rem; border-left: 3px solid rgba(127,127,127,.4); color: #555; }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .9em; }
    code { background: rgba(127,127,127,.15); padding: .05rem .3rem; border-radius: .25rem; }
    pre { background: rgba(127,127,127,.12); padding: .75rem 1rem; border-radius: .4rem; overflow-x: auto; white-space: pre-wrap; }
    table { border-collapse: collapse; margin: .75rem 0; }
    th, td { border: 1px solid rgba(127,127,127,.4); padding: .3rem .6rem; text-align: left; vertical-align: top; }
    hr { border: 0; border-top: 1px solid rgba(127,127,127,.3); margin: 1.5rem 0; }
    @media (prefers-color-scheme: dark) {
      body { background: #121212; color: #e8e8e8; }
      .meta { color: #a0a0a0; }
      blockquote { color: #bbb; }
    }
    @media print {
      body { background: #fff; color: #000; }
      main { max-width: none; padding: 0; }
      h2, h3 { break-after: avoid; }
    }
    """

    // MARK: - Blocks

    static func renderBlocks(_ blocks: [ExportRichBlock]) -> String {
        var out = ""
        var openList = false
        for block in blocks {
            if case .listItem(let indent, let marker, let runs) = block {
                if !openList {
                    out += "<ul class=\"items\">\n"
                    openList = true
                }
                let style = indent > 0 ? " style=\"margin-left: \(Double(indent) * 1.5)rem\"" : ""
                let glyph = escape(PlainTextExportRenderer.listMarker(marker))
                out += "<li\(style)><span class=\"marker\" aria-hidden=\"true\">\(glyph)</span><span>\(inline(runs))</span></li>\n"
                continue
            }
            if openList {
                out += "</ul>\n"
                openList = false
            }
            out += render(block)
        }
        if openList {
            out += "</ul>\n"
        }
        return out
    }

    private static func render(_ block: ExportRichBlock) -> String {
        switch block {
        case .heading(let level, let runs):
            let tag = "h\(min(6, max(2, level)))"
            return "<\(tag)>\(inline(runs))</\(tag)>\n"
        case .paragraph(let runs):
            return "<p>\(inline(runs))</p>\n"
        case .listItem:
            // Grouped into a list by `renderBlocks`.
            return ""
        case .quote(let runs):
            return "<blockquote><p>\(inline(runs))</p></blockquote>\n"
        case .code(let code):
            return "<pre><code>\(escape(code))</code></pre>\n"
        case .table(let headers, let rows):
            var out = "<table>\n<thead><tr>"
            out += headers.map { "<th>\(inline($0))</th>" }.joined()
            out += "</tr></thead>\n<tbody>\n"
            for row in rows {
                out += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
            }
            return out + "</tbody>\n</table>\n"
        case .rule:
            return "<hr>\n"
        }
    }

    // MARK: - Inline

    static func inline(_ runs: [InlineRun]) -> String {
        runs.map { run in
            var html = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.style.contains(.code) { html = "<code>\(html)</code>" }
            if run.style.contains(.strikethrough) { html = "<del>\(html)</del>" }
            if run.style.contains(.italic) { html = "<em>\(html)</em>" }
            if run.style.contains(.bold) { html = "<strong>\(html)</strong>" }
            return html
        }.joined()
    }

    /// Escapes the five characters with meaning in HTML text and attributes.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(char)
            }
        }
        return out
    }
}
