//
//  ExportDocument.swift
//  KurnCore
//
//  The format-neutral shape of an exported meeting (or one of its summaries or
//  transcripts). The app builds it once from SwiftData; every output format —
//  Markdown, Obsidian, plain text, HTML, Word, PDF — renders the same value,
//  so a section added to the export appears in all of them instead of in
//  whichever renderer remembered it.
//
//  Two layers, because Markdown is both an input and an output here:
//
//  - `blocks` is semantic and keeps LLM-written Markdown *as written*
//    (`.markdown`, `.bulletItems`), which is what lets the Markdown renderer
//    emit the summary body verbatim.
//  - `richBlocks` expands that Markdown through `MarkdownBlockParser` and
//    `InlineMarkdown` into styled runs, which is what every other renderer
//    consumes — none of them parses Markdown on its own.
//

import Foundation

public struct ExportDocument: Equatable, Sendable {
    /// Meeting metadata a format may surface as document properties: YAML
    /// frontmatter for Obsidian, core properties for Word, `<meta>` for HTML.
    public struct Properties: Equatable, Sendable {
        public var date: Date
        public var tags: [String]
        /// `Parent/Child` path of the meeting's folder, if filed.
        public var folderPath: String?
        public var isFavorite: Bool

        public init(date: Date, tags: [String] = [], folderPath: String? = nil, isFavorite: Bool = false) {
            self.date = date
            self.tags = tags
            self.folderPath = folderPath
            self.isFavorite = isFavorite
        }
    }

    /// One transcript line: who spoke, when (meeting-relative, already
    /// formatted), and what they said. Transcript text is never Markdown — it
    /// is whatever was said in the room — so it is not parsed as such.
    public struct Utterance: Equatable, Sendable {
        public var timestamp: String
        public var speaker: String
        public var text: String
        public var isHighlighted: Bool

        public init(timestamp: String, speaker: String, text: String, isHighlighted: Bool = false) {
            self.timestamp = timestamp
            self.speaker = speaker
            self.text = text
            self.isHighlighted = isHighlighted
        }
    }

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        /// User-typed text (meeting notes), kept verbatim.
        case plainText(String)
        /// LLM-written block-level Markdown (a summary section's body).
        case markdown(String)
        /// Bullet items, each a line of inline Markdown (summary items,
        /// highlight timestamps).
        case bulletItems([String])
        case utterance(Utterance)
        /// A photo taken during the meeting. The image is never exported —
        /// same policy as audio — only its timestamp and recognized text.
        case photo(timestamp: String, recognizedText: String?)
    }

    public var title: String
    /// Human-readable meeting date, already localized by the caller.
    public var dateLine: String
    /// Formatted total duration, `nil` when there is no audio.
    public var duration: String?
    public var properties: Properties
    public var blocks: [Block]

    public init(
        title: String,
        dateLine: String,
        duration: String? = nil,
        properties: Properties,
        blocks: [Block] = []
    ) {
        self.title = title
        self.dateLine = dateLine
        self.duration = duration
        self.properties = properties
        self.blocks = blocks
    }

    /// Label of the duration line. English like the section headings: the
    /// export's structure has always been English, whatever language the
    /// meeting itself was held in.
    public static let durationLabel = "Duration"
}

// MARK: - Rich layer

/// A block with its inline Markdown resolved into styled runs. Everything a
/// rich renderer (plain text, HTML, Word, PDF) needs, and nothing it would
/// have to parse.
public enum ExportRichBlock: Equatable, Sendable {
    case heading(level: Int, runs: [InlineRun])
    case paragraph(runs: [InlineRun])
    case listItem(indent: Int, marker: MarkdownListMarker, runs: [InlineRun])
    case quote(runs: [InlineRun])
    case code(String)
    case table(headers: [[InlineRun]], rows: [[[InlineRun]]])
    case rule
}

extension ExportDocument {
    /// Headings inside a summary section's body sit below the section title
    /// (level 3), whatever level the model chose for them.
    static let minimumBodyHeadingLevel = 4

    public var richBlocks: [ExportRichBlock] {
        blocks.flatMap(Self.richBlocks(for:))
    }

    /// The text a transcript line reads as, minus styling: `[0:05] Ana: …`,
    /// with a star when highlighted. Shared so every format words it alike.
    public static func utteranceRuns(_ utterance: Utterance) -> [InlineRun] {
        var runs: [InlineRun] = []
        if utterance.isHighlighted {
            runs.append(InlineRun("⭐ "))
        }
        runs.append(InlineRun("[\(utterance.timestamp)] \(utterance.speaker):", style: .bold))
        runs.append(InlineRun(" \(utterance.text)"))
        return runs
    }

    public static func photoRuns(timestamp: String, recognizedText: String?) -> [InlineRun] {
        var text = "📷 [\(timestamp)]"
        if let recognizedText, !recognizedText.isEmpty {
            text += " \(recognizedText)"
        }
        return [InlineRun(text, style: .italic)]
    }

    private static func richBlocks(for block: Block) -> [ExportRichBlock] {
        switch block {
        case .heading(let level, let text):
            return [.heading(level: level, runs: [InlineRun(text)])]
        case .plainText(let text):
            return [.paragraph(runs: [InlineRun(text)])]
        case .markdown(let markdown):
            return rich(MarkdownBlockParser.parse(markdown))
        case .bulletItems(let items):
            return items.flatMap(richItem)
        case .utterance(let utterance):
            return [.paragraph(runs: utteranceRuns(utterance))]
        case .photo(let timestamp, let recognizedText):
            return [.paragraph(runs: photoRuns(timestamp: timestamp, recognizedText: recognizedText))]
        }
    }

    /// A summary item is a single string that may still carry its own task
    /// box or sub-bullets on extra lines; normalising it to a list line lets
    /// the block parser resolve both.
    private static func richItem(_ item: String) -> [ExportRichBlock] {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let normalized: String
        if let first = trimmed.first, "-*+".contains(first) {
            normalized = trimmed
        } else {
            normalized = "- " + trimmed
        }
        let blocks = rich(MarkdownBlockParser.parse(normalized))
        // An item the parser does not read as a list line ("-text") is still
        // an item: never drop it, never promote it to a paragraph.
        if blocks.isEmpty {
            return [.listItem(indent: 0, marker: .bullet, runs: InlineMarkdown.runs(trimmed))]
        }
        return blocks
    }

    private static func rich(_ blocks: [MarkdownBlock]) -> [ExportRichBlock] {
        blocks.flatMap { block -> [ExportRichBlock] in
            switch block {
            case .heading(let level, let text):
                let clamped = min(6, max(minimumBodyHeadingLevel, level))
                return [.heading(level: clamped, runs: InlineMarkdown.runs(text))]
            case .paragraph(let text):
                return [.paragraph(runs: InlineMarkdown.runs(text))]
            case .list(let items):
                return items.map {
                    .listItem(indent: $0.indent, marker: $0.marker, runs: InlineMarkdown.runs($0.text))
                }
            case .blockquote(let inner):
                // Quotes flatten to quoted paragraphs: no format here nests
                // them meaningfully, and none may lose their text.
                return rich(inner).map { quoted($0) }
            case .codeBlock(_, let code):
                return [.code(code)]
            case .table(let headers, let rows):
                return [.table(
                    headers: headers.map(InlineMarkdown.runs),
                    rows: rows.map { $0.map(InlineMarkdown.runs) }
                )]
            case .horizontalRule:
                return [.rule]
            }
        }
    }

    private static func quoted(_ block: ExportRichBlock) -> ExportRichBlock {
        switch block {
        case .heading(_, let runs), .paragraph(let runs), .listItem(_, _, let runs), .quote(let runs):
            return .quote(runs: runs)
        case .code(let code):
            return .quote(runs: [InlineRun(code, style: .code)])
        case .table, .rule:
            return block
        }
    }
}

// MARK: - Page geometry

/// Paper size for the paginated formats (Word, PDF). Letter where it is the
/// norm, A4 everywhere else.
public enum ExportPageSize: Equatable, Sendable {
    case a4
    case letter

    /// Width and height in PostScript points (1/72 inch).
    public var points: (width: Double, height: Double) {
        switch self {
        case .a4: return (595.28, 841.89)
        case .letter: return (612, 792)
        }
    }

    /// Width and height in twentieths of a point, Word's unit.
    public var twips: (width: Int, height: Int) {
        switch self {
        case .a4: return (11906, 16838)
        case .letter: return (12240, 15840)
        }
    }

    /// Regions where US Letter is the customary paper size.
    static let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "GT", "PR", "CR", "DO", "SV", "PA", "NI", "HN", "BO"]

    public static func preferred(forRegion regionCode: String?) -> ExportPageSize {
        guard let regionCode else { return .a4 }
        return letterRegions.contains(regionCode.uppercased()) ? .letter : .a4
    }
}
