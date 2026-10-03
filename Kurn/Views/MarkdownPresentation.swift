//
//  MarkdownPresentation.swift
//  Kurn
//
//  Value-level styling decisions for `MarkdownText`, separated from the view
//  so the mapping from Markdown structure to typography can be asserted
//  without rendering.
//

import Foundation
import SwiftUI

enum MarkdownPresentation {
    static func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .subheadline.bold()
        case 4: return .subheadline.weight(.semibold)
        case 5: return .footnote.bold()
        default: return .footnote.weight(.semibold)
        }
    }

    /// Nested bullets cycle through three glyphs by indent depth.
    static func bulletGlyph(indent: Int) -> String {
        switch indent % 3 {
        case 1: return "◦"
        case 2: return "▪"
        default: return "•"
        }
    }

    /// Inline Markdown parsed for display, or `nil` when the text is not
    /// valid Markdown and should be shown verbatim.
    ///
    /// Links are rendered as their text but are not tappable. Everything
    /// shown through here — summaries, wiki articles, documents, chat
    /// replies — is written by an LLM from a transcript, and the transcript
    /// is whatever was said in the room: a speaker (or a document read aloud)
    /// can steer the model into emitting a link whose URL carries meeting
    /// content to a server, or opens another app's URL scheme. Nothing the
    /// app shows legitimately depends on a tappable link in that text.
    static func inlineAttributedString(_ text: String) -> AttributedString? {
        guard var attributed = try? AttributedString(markdown: text) else { return nil }
        let linkRanges = attributed.runs.filter { $0.link != nil }.map(\.range)
        for range in linkRanges {
            attributed[range].link = nil
        }
        return attributed
    }
}
