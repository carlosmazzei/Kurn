//
//  SummaryDraftPreview.swift
//  KurnCore
//
//  The readable draft of a summary while it is still streaming. A summary is
//  generated as Markdown with "## " section headings (`SummaryMarkdown`), and
//  the draft is that text with the syntax a reader should not see removed:
//  heading markers (the title stays, on its own line after a blank one),
//  photo-reference lines and code-fence lines. Everything else passes through
//  character by character, so the draft grows like a chat reply.
//
//  Only the start of a line is held back, and only while it could still turn
//  out to be one of those markers ("#", "📷", "`"); as soon as it cannot, the
//  held text is emitted and the rest of the line streams.
//
//  Deliberately unformatted and forgiving: it is a preview of work in
//  progress, replaced by the parsed summary the moment generation finishes.
//

import Foundation

public struct SummaryDraftPreview: Sendable, Equatable {
    /// The readable draft so far.
    public private(set) var text = ""
    /// Approximate words in `text`; see `StreamedWordCount`.
    public var words: Int { wordCount.words }

    private enum LineMode: Equatable {
        /// At the start of a line, holding `pending` until it is classified.
        case undecided
        /// Shown as it arrives (a heading's title or ordinary text).
        case visible
        /// Dropped up to the end of the line.
        case hidden
    }

    private static let photoScalar: Unicode.Scalar = "\u{1F4F7}"

    private var mode = LineMode.undecided
    private var pending = ""
    private var wordCount = StreamedWordCount()

    public init() {}

    public mutating func add(_ fragment: String) {
        for scalar in fragment.unicodeScalars {
            if scalar == "\n" {
                endLine()
                continue
            }
            switch mode {
            case .undecided:
                pending.unicodeScalars.append(scalar)
                classify(isComplete: false)
            case .visible:
                emit(String(scalar))
            case .hidden:
                break
            }
        }
    }

    // MARK: - Lines

    private mutating func endLine() {
        if mode == .undecided { classify(isComplete: true) }
        if mode == .visible { emit("\n") }
        // A hidden line leaves no trace, not even its line break; a blank line
        // is kept, but never more than one in a row.
        if mode == .undecided, !text.isEmpty, !text.hasSuffix("\n\n") { emit("\n") }
        mode = .undecided
        pending = ""
    }

    /// Decide what the held start of a line is, once enough of it has
    /// arrived — or, at the end of the line, with whatever did.
    private mutating func classify(isComplete: Bool) {
        let content = pending.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = content.unicodeScalars.first else {
            // Only indentation so far: an empty line stays undecided.
            return
        }
        switch first {
        case "#":
            let hashes = content.prefix(while: { $0 == "#" })
            let afterHashes = content.dropFirst(hashes.count)
            guard let next = afterHashes.first else {
                if isComplete { show(pending) }
                return
            }
            guard hashes.count <= 6, next == " " || next == "\t" else {
                show(pending)
                return
            }
            startHeading(with: afterHashes.trimmingCharacters(in: .whitespaces))
        case "`", "~":
            let marker = String(first)
            let fence = String(repeating: marker, count: 3)
            if content.hasPrefix(fence) {
                mode = .hidden
            } else if fence.hasPrefix(String(content)), !isComplete {
                return
            } else {
                show(pending)
            }
        case Self.photoScalar:
            mode = .hidden
        default:
            show(pending)
        }
    }

    private mutating func startHeading(with title: String) {
        if !text.isEmpty {
            emit(text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n"))
        }
        mode = .visible
        emit(title)
    }

    private mutating func show(_ held: String) {
        mode = .visible
        emit(held)
    }

    private mutating func emit(_ piece: String) {
        guard !piece.isEmpty else { return }
        text += piece
        wordCount.add(piece)
    }
}

/// One update of a streaming summary's draft, as handed to the UI.
/// `sequence` increases with every update of a run — including the empty
/// draft that opens each new request — so a receiver that hops threads can
/// drop an update overtaken by a newer one instead of flickering back to
/// stale text.
public struct SummaryDraftSnapshot: Sendable, Equatable {
    public let sequence: Int
    public let text: String
    public let words: Int

    public init(sequence: Int, text: String, words: Int) {
        self.sequence = sequence
        self.text = text
        self.words = words
    }
}
