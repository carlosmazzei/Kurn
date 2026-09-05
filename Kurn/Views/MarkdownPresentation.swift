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
    static func inlineAttributedString(_ text: String) -> AttributedString? {
        try? AttributedString(markdown: text)
    }
}
