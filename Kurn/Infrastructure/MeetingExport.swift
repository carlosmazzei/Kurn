//
//  MeetingExport.swift
//  Kurn
//
//  Renders a meeting to a structured Markdown document and writes it to a temp
//  file for sharing via ShareLink.
//

import Foundation

enum MeetingExport {
    /// Build the full Markdown representation of a meeting.
    /// - Parameter summary: the summary currently shown on screen, if any —
    ///   a meeting can have several; only this one is included.
    @MainActor
    static func markdown(for meeting: Meeting, summary: Summary?) -> String {
        var out = header(for: meeting)

        if !meeting.notes.isEmpty {
            out += "## Notes\n\n\(meeting.notes)\n\n"
        }

        if let summary {
            out += renderSummary(summary)
        }

        let recordings = meeting.recordings.sorted { $0.recordedAt < $1.recordedAt }
        let transcribed = recordings.filter { $0.transcript != nil }
        if !transcribed.isEmpty {
            out += "## Transcript\n\n"
            let nameByLabel = speakerNames(for: meeting)
            for (index, recording) in transcribed.enumerated() {
                if transcribed.count > 1 {
                    out += "### Segment \(index + 1)\n\n"
                }
                out += renderTranscript(for: meeting, recording: recording, nameByLabel: nameByLabel)
            }
        }

        return out
    }

    /// Markdown for a single recording's transcript, standalone (own title/date
    /// header, no other recordings or summaries) so it can be shared/copied
    /// independently of the rest of the meeting.
    @MainActor
    static func transcriptMarkdown(for meeting: Meeting, recording: Recording) -> String {
        var out = header(for: meeting)
        out += "## Transcript\n\n"
        out += renderTranscript(for: meeting, recording: recording, nameByLabel: speakerNames(for: meeting))
        return out
    }

    /// Markdown for a single summary, standalone (own title/date header, no
    /// other summaries or transcripts).
    @MainActor
    static func summaryMarkdown(for meeting: Meeting, summary: Summary) -> String {
        header(for: meeting) + renderSummary(summary)
    }

    @MainActor
    private static func header(for meeting: Meeting) -> String {
        var out = "# \(meeting.title)\n\n"
        out += "_\(meeting.createdAt.meetingDisplay)_\n\n"
        if meeting.totalDuration > 0 {
            out += "**Duration:** \(meeting.totalDuration.clockDisplay)\n\n"
        }
        return out
    }

    private static func renderSummary(_ summary: Summary) -> String {
        var out = "## Summary\n\n"
        for section in summary.sections {
            if !section.title.isEmpty {
                out += "### \(section.title)\n\n"
            }
            if !section.body.isEmpty {
                out += "\(section.body)\n\n"
            }
            if !section.items.isEmpty {
                out += section.items.map { "- \($0)" }.joined(separator: "\n")
                out += "\n\n"
            }
        }
        return out
    }

    /// Map speaker labels to display names for nicer export.
    @MainActor
    private static func speakerNames(for meeting: Meeting) -> [String: String] {
        Dictionary(
            meeting.speakers.map { ($0.label, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @MainActor
    private static func renderTranscript(for meeting: Meeting, recording: Recording, nameByLabel: [String: String]) -> String {
        var out = ""
        let offset = meeting.startOffset(of: recording)
        for segment in recording.transcript?.segments ?? [] {
            let name = nameByLabel[segment.speakerLabel] ?? segment.speakerLabel
            let stamp = (segment.startTime + offset).clockDisplay
            out += "**[\(stamp)] \(name):** \(segment.text)\n\n"
        }
        return out
    }

    /// Write the Markdown to a temporary `.md` file and return its URL.
    ///
    /// Each call gets its own UUID-named subdirectory under the temp
    /// directory (rather than writing `<title>.md` straight into the shared
    /// temp root) so two exports with the same or empty title — sharing
    /// twice in quick succession, or two meetings that both fall back to
    /// "meeting.md" — never collide on the same path while one share sheet
    /// is still open and the other's `.atomic` write or later cleanup runs.
    @MainActor
    static func temporaryFile(for meeting: Meeting, summary: Summary?) throws -> URL {
        try temporaryFile(markdown: markdown(for: meeting, summary: summary), suggestedName: meeting.title)
    }

    /// Write arbitrary Markdown to a temporary `.md` file, named after
    /// `suggestedName` (sanitized), and return its URL. See
    /// `temporaryFile(for:summary:)` for why each call gets its own
    /// UUID-named subdirectory.
    static func temporaryFile(markdown text: String, suggestedName: String) throws -> URL {
        let safeName = suggestedName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let name = (safeName.isEmpty ? "meeting" : safeName) + ".md"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        RecordingProtection.apply(to: url)
        return url
    }
}
