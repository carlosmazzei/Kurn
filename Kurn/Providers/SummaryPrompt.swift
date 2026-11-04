//
//  SummaryPrompt.swift
//  Kurn
//

import Foundation
import KurnCore

// MARK: - Shared prompt

enum SummaryPrompt {
    /// Build the system prompt for a template: a fixed base, the template's
    /// instructions (which name its sections, if it wants particular ones),
    /// and the Markdown output contract `SummaryMarkdown` parses. The summary
    /// is requested in the transcript's own language.
    static func system(for template: SummaryTemplate) -> String {
        """
        You are an expert meeting assistant. Given a meeting transcript with \
        speaker labels, write a summary in the SAME LANGUAGE as the transcript, \
        section headings included.

        \(template.instructions)

        Transcript conventions:
        - Lines prefixed with ⭐ are moments the speaker flagged as important \
        while recording. When there is at least one, add a section (along the \
        lines of "Highlighted Moments") listing each with its [mm:ss] timestamp \
        and what was said, in order.
        - Lines reading "[mm:ss] 📷 Photo: <text>" are text recognized in a \
        photo taken during the meeting (a whiteboard, a slide).
        - An "Attached documents" part after the transcript, one "=== 📄 \
        Document: <name> ===" header per file, is reference material: use it \
        to get names, figures and terms right, but never present it as \
        something said in the meeting or give it a [mm:ss] timestamp. When it \
        adds substance the conversation does not cover, name the document.

        Output format — Markdown only, no preamble and no code fence around it:
        - Start every section with a "## " heading. Use "#### " for headings \
        inside a section; never "#".
        - Use task checkboxes ("- [ ]" open, "- [x]" done) for action items, \
        with owner and deadline when stated; a table for comparisons or \
        structured facts; "> " for verbatim quotes; plain prose everywhere \
        else. Do not force formatting where it does not help.
        - When a section draws on a photo, end it with one line made of \
        \(SummaryMarkdown.photoMarker) and that photo's stamp copied exactly, \
        e.g. "\(SummaryMarkdown.photoMarker) [12:34] [15:02]".
        """
    }
}
