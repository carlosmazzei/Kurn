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
    @MainActor
    static func markdown(for meeting: Meeting) -> String {
        var out = "# \(meeting.title)\n\n"
        out += "_\(meeting.createdAt.meetingDisplay)_\n\n"
        if meeting.totalDuration > 0 {
            out += "**Duration:** \(meeting.totalDuration.clockDisplay)\n\n"
        }

        if !meeting.notes.isEmpty {
            out += "## Notes\n\n\(meeting.notes)\n\n"
        }

        if let summary = meeting.summary {
            out += "## Summary\n\n"
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
        }

        // Map speaker labels to display names for nicer export.
        let nameByLabel = Dictionary(
            meeting.speakers.map { ($0.label, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )

        let recordings = meeting.recordings.sorted { $0.recordedAt < $1.recordedAt }
        let transcribed = recordings.filter { $0.transcript != nil }
        if !transcribed.isEmpty {
            out += "## Transcript\n\n"
            for (index, recording) in transcribed.enumerated() {
                if transcribed.count > 1 {
                    out += "### Segment \(index + 1)\n\n"
                }
                let offset = meeting.startOffset(of: recording)
                for segment in recording.transcript?.segments ?? [] {
                    let name = nameByLabel[segment.speakerLabel] ?? segment.speakerLabel
                    let stamp = (segment.startTime + offset).clockDisplay
                    out += "**[\(stamp)] \(name):** \(segment.text)\n\n"
                }
            }
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
    static func temporaryFile(for meeting: Meeting) throws -> URL {
        let text = markdown(for: meeting)
        let safeTitle = meeting.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let name = (safeTitle.isEmpty ? "meeting" : safeTitle) + ".md"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        RecordingProtection.apply(to: url)
        return url
    }
}
