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
    /// - Parameters:
    ///   - summary: the summary currently shown on screen, if any — a meeting
    ///     can have several; only this one is included.
    ///   - obsidianStyle: when `true`, prepends a YAML frontmatter block
    ///     (title/date/tags/folder/favorite) and renders speaker names as
    ///     `[[wikilinks]]` instead of plain text.
    @MainActor
    static func markdown(for meeting: Meeting, summary: Summary?, obsidianStyle: Bool = false) -> String {
        var out = header(for: meeting, obsidianStyle: obsidianStyle)

        if !meeting.notes.isEmpty {
            out += "## Notes\n\n\(meeting.notes)\n\n"
        }

        if let summary {
            out += renderSummary(summary)
        }

        out += renderHighlights(for: meeting)

        let recordings = meeting.recordings
            .filter(\.isReadyForConsumption)
            .sorted { $0.recordedAt < $1.recordedAt }
        let transcribed = recordings.filter { $0.transcript != nil }
        if !transcribed.isEmpty {
            out += "## Transcript\n\n"
            let nameByLabel = speakerNames(for: meeting)
            for (index, recording) in transcribed.enumerated() {
                if transcribed.count > 1 {
                    out += "### Segment \(index + 1)\n\n"
                }
                out += renderTranscript(
                    for: meeting,
                    recording: recording,
                    nameByLabel: nameByLabel,
                    obsidianStyle: obsidianStyle
                )
            }
        }

        return out
    }

    /// Markdown for a single recording's transcript, standalone (own title/date
    /// header, no other recordings or summaries) so it can be shared/copied
    /// independently of the rest of the meeting.
    @MainActor
    static func transcriptMarkdown(for meeting: Meeting, recording: Recording, obsidianStyle: Bool = false) -> String {
        var out = header(for: meeting, obsidianStyle: obsidianStyle)
        out += "## Transcript\n\n"
        out += renderTranscript(
            for: meeting,
            recording: recording,
            nameByLabel: speakerNames(for: meeting),
            obsidianStyle: obsidianStyle
        )
        return out
    }

    /// Markdown for a single summary, standalone (own title/date header, no
    /// other summaries or transcripts).
    @MainActor
    static func summaryMarkdown(for meeting: Meeting, summary: Summary, obsidianStyle: Bool = false) -> String {
        header(for: meeting, obsidianStyle: obsidianStyle) + renderSummary(summary)
    }

    @MainActor
    private static func header(for meeting: Meeting, obsidianStyle: Bool) -> String {
        var out = obsidianStyle ? frontmatter(for: meeting) : ""
        out += "# \(meeting.title)\n\n"
        out += "_\(meeting.createdAt.meetingDisplay)_\n\n"
        if meeting.totalDuration > 0 {
            out += "**Duration:** \(meeting.totalDuration.clockDisplay)\n\n"
        }
        return out
    }

    /// YAML frontmatter block Obsidian recognizes as note properties: title,
    /// date, tags, folder, and favorite. Keys whose value is absent/false are
    /// omitted entirely rather than emitted empty, so an untagged, unfiled,
    /// non-favorite meeting doesn't carry noise in its frontmatter.
    @MainActor
    private static func frontmatter(for meeting: Meeting) -> String {
        var lines = ["title: \(yamlString(meeting.title))"]
        lines.append("date: \(isoDateFormatter.string(from: meeting.createdAt))")
        if !meeting.tags.isEmpty {
            let tags = meeting.tags.map { yamlString($0.name) }.joined(separator: ", ")
            lines.append("tags: [\(tags)]")
        }
        if let folder = meeting.folder {
            lines.append("folder: \(yamlString(folderPath(folder)))")
        }
        if meeting.isFavorite {
            lines.append("favorite: true")
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n\n"
    }

    /// `Parent/Child` path for a (possibly nested) folder.
    private static func folderPath(_ folder: Folder) -> String {
        var components = [folder.name]
        var current = folder.parent
        while let parent = current {
            components.append(parent.name)
            current = parent.parent
        }
        return components.reversed().joined(separator: "/")
    }

    /// Renders a value as a double-quoted YAML scalar, escaping the
    /// characters that would otherwise break the frontmatter block: an
    /// embedded quote, or a newline (frontmatter values are single-line).
    private static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

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

    /// Bullet list of every recording-relative highlight, converted to
    /// meeting-relative `[mm:ss]` stamps and sorted chronologically. Static
    /// document, no tap-to-seek — purely a navigational list.
    @MainActor
    private static func renderHighlights(for meeting: Meeting) -> String {
        let stamps = meeting.recordings
            .filter(\.isReadyForConsumption)
            .sorted { $0.recordedAt < $1.recordedAt }
            .flatMap { recording in
                recording.highlights.map { meeting.startOffset(of: recording) + $0.timestamp }
            }
            .sorted()
        guard !stamps.isEmpty else { return "" }
        var out = "## Highlights\n\n"
        out += stamps.map { "- \($0.clockDisplay)" }.joined(separator: "\n")
        out += "\n\n"
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
    private static func renderTranscript(
        for meeting: Meeting,
        recording: Recording,
        nameByLabel: [String: String],
        obsidianStyle: Bool = false
    ) -> String {
        var out = ""
        let offset = meeting.startOffset(of: recording)
        let highlights = recording.highlights
        for segment in recording.transcript?.segments ?? [] {
            let rawName = nameByLabel[segment.speakerLabel] ?? segment.speakerLabel
            let name = obsidianStyle ? "[[\(rawName)]]" : rawName
            let stamp = (segment.startTime + offset).clockDisplay
            let isHighlighted = highlights.contains { $0.timestamp >= segment.startTime && $0.timestamp < segment.endTime }
            let prefix = isHighlighted ? "⭐ " : ""
            out += "\(prefix)**[\(stamp)] \(name):** \(segment.text)\n\n"
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
