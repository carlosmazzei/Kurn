//
//  AttachmentPromptContext.swift
//  KurnCore
//
//  The text of the documents attached to a meeting (PDFs picked from Files
//  or shared into the app) as one block appended after the transcript, in
//  every prompt that grounds on a single meeting: its summaries, its wiki
//  article, its chat and the documents generated from it. A transcript says
//  what was spoken; an agenda, a slide deck or a report says what the
//  meeting was about — names, figures and terms the recognizer could only
//  guess at.
//
//  The block is bounded twice — per document and in total — because a
//  300-page PDF would otherwise decide the cost and the budget of every
//  request about a ten-minute meeting. Lines are also hard-wrapped, since
//  `SummaryService.splitTranscript` breaks only on line boundaries and turns
//  a line longer than a block into an oversized block of its own; extracted
//  PDF text sometimes arrives as a single enormous line.
//

import Foundation

public enum AttachmentPromptContext {
    /// One attached document: the name the user knows it by and the text
    /// extracted from it.
    public struct Document: Sendable, Equatable {
        public let name: String
        public let text: String

        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    /// Longest share of the prompt one document may take.
    public static let maxCharactersPerDocument = 40_000
    /// Longest the whole block may be, however many documents are attached.
    public static let maxTotalCharacters = 120_000
    /// Lines longer than this are wrapped at a word boundary.
    public static let maxLineLength = 2_000

    /// Opens the block; `SummaryPrompt` tells the model what it means.
    public static let header = "Attached documents (reference material added to this meeting, not spoken in it):"
    /// Ends a document that was cut to fit its share.
    public static let truncationMarker = "[document truncated]"

    /// The transcript followed by the attached documents' block. An empty
    /// transcript stays empty: documents add context to a meeting, they are
    /// not a meeting on their own, so "nothing transcribed yet" keeps meaning
    /// exactly that to every caller.
    public static func appending(_ documents: [Document], to transcript: String) -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }
        let block = block(for: documents)
        guard !block.isEmpty else { return transcript }
        return transcript + "\n\n" + block
    }

    /// The block for `documents`, in the order given; empty when none carries
    /// any text. Documents past the total budget are left out.
    public static func block(for documents: [Document]) -> String {
        var sections: [String] = []
        var remaining = maxTotalCharacters
        for document in documents {
            let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, remaining > 0 else { continue }
            let allowance = min(maxCharactersPerDocument, remaining)
            let isTruncated = text.count > allowance
            let kept = isTruncated ? cut(text, to: allowance) : text
            remaining -= kept.count
            var body = wrapped(kept)
            if isTruncated {
                body += "\n" + truncationMarker
            }
            sections.append("=== 📄 Document: \(displayName(document.name)) ===\n\(body)")
        }
        guard !sections.isEmpty else { return "" }
        return ([header] + sections).joined(separator: "\n\n")
    }

    /// `text`'s first `limit` characters, backed off to the last whitespace
    /// in the final tenth so a word is not cut in half.
    static func cut(_ text: String, to limit: Int) -> String {
        let prefix = String(text.prefix(limit))
        let floor = prefix.index(prefix.endIndex, offsetBy: -(limit / 10), limitedBy: prefix.startIndex) ?? prefix.startIndex
        guard let space = prefix[floor...].lastIndex(where: \.isWhitespace) else { return prefix }
        return String(prefix[..<space])
    }

    /// Every line of `text` no longer than `maxLineLength`, breaking at the
    /// last whitespace before the limit (or at the limit when there is none).
    static func wrapped(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { wrap(line: Substring($0)) }
            .joined(separator: "\n")
    }

    private static func wrap(line: Substring) -> [Substring] {
        var rest = line
        var lines: [Substring] = []
        while rest.count > maxLineLength {
            let limit = rest.index(rest.startIndex, offsetBy: maxLineLength)
            let head = rest[..<limit]
            if let space = head.lastIndex(where: \.isWhitespace), space > rest.startIndex {
                lines.append(rest[..<space])
                rest = rest[rest.index(after: space)...]
            } else {
                lines.append(head)
                rest = rest[limit...]
            }
        }
        lines.append(rest)
        return lines
    }

    /// The name on one line, so it cannot open a fake section of its own.
    private static func displayName(_ name: String) -> String {
        let flattened = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.isEmpty ? "Untitled" : flattened
    }
}
