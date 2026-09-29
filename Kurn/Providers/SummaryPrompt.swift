//
//  SummaryPrompt.swift
//  Kurn
//

import Foundation

// MARK: - Shared prompt

enum SummaryPrompt {
    /// Build the system prompt for a template. Combines a fixed base + the
    /// template's persona/focus + its suggested sections + the JSON contract.
    /// The summary is requested in the transcript's own language.
    static func system(for template: SummaryTemplate) -> String {
        var prompt = """
        You are an expert meeting assistant. Given a meeting transcript with \
        speaker labels, produce a structured summary in the SAME LANGUAGE as the \
        transcript.

        Some transcript lines are prefixed with ⭐ — these mark moments the \
        speaker explicitly flagged as important while the meeting was being \
        recorded. Whenever at least one ⭐-marked line is present, include a \
        dedicated section (title translated into the transcript's language, \
        along the lines of "Highlighted Moments") listing each one with its \
        [mm:ss] timestamp and a short description of what was said, in \
        chronological order.

        Some transcript lines read "[mm:ss] 📷 Photo: <text>" — text recognized \
        in a photo taken during the meeting (e.g. a whiteboard or slide). \
        Whenever a section's content draws on one of these, copy that line's \
        exact "mm:ss" stamp (do not compute or reformat it) into that \
        section's "photoReferences" array, so the reader can jump back to the \
        photo. Omit "photoReferences" entirely for a section that draws on no \
        photo.

        \(template.instructions)
        """

        let sections = template.sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !sections.isEmpty {
            let list = sections.map { "- \($0)" }.joined(separator: "\n")
            prompt += """


            Organize the summary into sections along these lines (adapt, merge, \
            rename, or add sections as the content requires):
            \(list)
            """
        }

        prompt += """


        Output valid JSON with this shape:
        {
          "sections": [
            { "title": "Section heading", "body": "markdown paragraph(s)", "items": ["bullet", "bullet"], "photoReferences": ["mm:ss"] }
          ]
        }
        Each section needs a "title". Use "body" for prose and "items" for bullet \
        lists; either may be omitted when not needed. "photoReferences" is \
        optional — see the photo instruction above.
        "body" is rendered as Markdown and supports: **bold** and *italic*, #### \
        subheadings, bullet and numbered lists (nest by indenting two spaces), task \
        checkboxes ("- [ ]" open, "- [x]" done), "> " blockquotes, pipe tables with \
        a |---| separator row, and ``` fenced code blocks.
        Prefer task checkboxes for action items and to-dos (include owner and \
        deadline when stated), a table when comparing options or listing structured \
        facts, and "> " blockquotes when quoting a speaker verbatim. Use plain \
        prose everywhere else — do not force formatting where it does not help.
        "items" entries render as bullets; start an entry with "[ ] " or "[x] " to \
        render it as a task checkbox instead.
        Use real line breaks inside "body" — never write the two characters \
        backslash-n. Keep each "items" entry to a single line.
        Translate the section titles into the transcript's language.
        Output ONLY the JSON object itself — no markdown fences around it.
        """
        return prompt
    }
}
