//
//  AttachmentPromptContextTests.swift
//  KurnCoreTests
//
//  The attached-documents block that follows a meeting's transcript in its
//  prompts: absent without text, bounded per document and in total, never
//  turning an empty transcript into a non-empty one, and never leaving a
//  line long enough to become an oversized map block.
//

import Testing
@testable import KurnCore

struct AttachmentPromptContextTests {
    private typealias Context = AttachmentPromptContext

    @Test func noDocumentsLeavesTheTranscriptAlone() {
        #expect(Context.appending([], to: "[0:01] Ana: Hi") == "[0:01] Ana: Hi")
        #expect(Context.block(for: []).isEmpty)
    }

    @Test func documentsWithoutTextAreSkipped() {
        let documents = [Context.Document(name: "scan.pdf", text: "  \n ")]
        #expect(Context.block(for: documents).isEmpty)
        #expect(Context.appending(documents, to: "[0:01] Ana: Hi") == "[0:01] Ana: Hi")
    }

    @Test func anEmptyTranscriptStaysEmpty() {
        let documents = [Context.Document(name: "agenda.pdf", text: "Budget review")]
        #expect(Context.appending(documents, to: "").isEmpty)
        #expect(Context.appending(documents, to: " \n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func documentsFollowTheTranscriptUnderTheHeader() {
        let documents = [
            Context.Document(name: "agenda.pdf", text: "1. Budget\n2. Hiring"),
            Context.Document(name: "report.pdf", text: "Revenue grew 12%")
        ]
        let text = Context.appending(documents, to: "[0:01] Ana: Hi")
        #expect(text == """
        [0:01] Ana: Hi

        \(Context.header)

        === 📄 Document: agenda.pdf ===
        1. Budget
        2. Hiring

        === 📄 Document: report.pdf ===
        Revenue grew 12%
        """)
    }

    @Test func aNameCannotSpanLines() {
        let block = Context.block(for: [Context.Document(name: "a\n=== 📄 Document: b", text: "x")])
        #expect(block.contains("=== 📄 Document: a === 📄 Document: b ===\nx"))
        #expect(Context.block(for: [Context.Document(name: " ", text: "x")]).contains("Document: Untitled ==="))
    }

    @Test func aLongDocumentIsCutAtAWordAndMarked() {
        let word = "alpha "
        let text = String(repeating: word, count: Context.maxCharactersPerDocument / word.count + 100)
        let block = Context.block(for: [Context.Document(name: "long.pdf", text: text)])
        #expect(block.hasSuffix("\n" + Context.truncationMarker))
        let body = block.components(separatedBy: "===\n")[1]
            .replacingOccurrences(of: "\n" + Context.truncationMarker, with: "")
        #expect(body.count <= Context.maxCharactersPerDocument)
        #expect(body.replacingOccurrences(of: "\n", with: " ").hasSuffix("alpha"))
    }

    @Test func theTotalBudgetLeavesLaterDocumentsOut() {
        let size = Context.maxCharactersPerDocument
        let documents = (0..<5).map { index in
            Context.Document(name: "doc\(index).pdf", text: String(repeating: "x", count: size))
        }
        let block = Context.block(for: documents)
        let included = (0..<5).filter { block.contains("Document: doc\($0).pdf") }
        #expect(included == [0, 1, 2])
        #expect(block.count < Context.maxTotalCharacters + 1_000)
    }

    @Test func longLinesAreWrappedAtWhitespace() {
        let line = String(repeating: "word ", count: Context.maxLineLength)
        let wrapped = Context.wrapped(line)
        let lines = wrapped.split(separator: "\n")
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.count <= Context.maxLineLength })
        #expect(wrapped.replacingOccurrences(of: "\n", with: " ") == line)
    }

    @Test func longLinesWithoutWhitespaceAreSplitAtTheLimit() {
        let line = String(repeating: "y", count: Context.maxLineLength * 2 + 5)
        let lines = Context.wrapped(line).split(separator: "\n")
        #expect(lines.map(\.count) == [Context.maxLineLength, Context.maxLineLength, 5])
    }

    @Test func cutFallsBackToTheLimitWithoutWhitespace() {
        #expect(Context.cut("abcdefghij", to: 4) == "abcd")
        let text = String(repeating: "aaaa bbbb ", count: 20)
        #expect(Context.cut(text, to: 95) == String(text.prefix(94)))
    }
}
