//
//  MeetingExport.swift
//  Kurn
//
//  Turns a meeting (or one of its summaries or transcripts) into a
//  format-neutral `ExportDocument`, renders it as Markdown, and writes
//  exports to protected temporary files for the share sheet. The other
//  formats render the same document; see `MeetingExportFormat`.
//

import Foundation
import KurnCore

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
        MarkdownExportRenderer.render(document(for: meeting, summary: summary), obsidianStyle: obsidianStyle)
    }

    /// Markdown for a single recording's transcript, standalone (own title/date
    /// header, no other recordings or summaries) so it can be shared/copied
    /// independently of the rest of the meeting.
    @MainActor
    static func transcriptMarkdown(for meeting: Meeting, recording: Recording, obsidianStyle: Bool = false) -> String {
        MarkdownExportRenderer.render(transcriptDocument(for: meeting, recording: recording), obsidianStyle: obsidianStyle)
    }

    /// Markdown for a single summary, standalone (own title/date header, no
    /// other summaries or transcripts).
    @MainActor
    static func summaryMarkdown(for meeting: Meeting, summary: Summary, obsidianStyle: Bool = false) -> String {
        MarkdownExportRenderer.render(summaryDocument(for: meeting, summary: summary), obsidianStyle: obsidianStyle)
    }

    // MARK: - Documents

    /// The whole meeting as a format-neutral document: notes, the given
    /// summary, highlights, then every transcribed recording in order.
    @MainActor
    static func document(for meeting: Meeting, summary: Summary?) -> ExportDocument {
        let transcribed = meeting.recordings
            .filter(\.isReadyForConsumption)
            .sorted { $0.recordedAt < $1.recordedAt }
            .filter { $0.transcript != nil }
        // The summary decides the language when there is one: it is what the
        // reader reads first, and it may have been translated on request.
        let sample = [summary.map(summaryText) ?? "", transcriptText(transcribed), meeting.notes].joined(separator: "\n")
        var document = header(for: meeting, languageSample: sample)
        let labels = document.labels

        if !meeting.notes.isEmpty {
            document.blocks.append(.heading(level: 2, text: labels.notes))
            document.blocks.append(.plainText(meeting.notes))
        }

        if let summary {
            document.blocks += summaryBlocks(summary, labels: labels)
        }

        document.blocks += highlightBlocks(for: meeting, labels: labels)

        if !transcribed.isEmpty {
            document.blocks.append(.heading(level: 2, text: labels.transcript))
            let nameByLabel = speakerNames(for: meeting)
            for (index, recording) in transcribed.enumerated() {
                if transcribed.count > 1 {
                    document.blocks.append(.heading(level: 3, text: labels.segment(index + 1)))
                }
                document.blocks += transcriptBlocks(for: meeting, recording: recording, nameByLabel: nameByLabel)
            }
        }

        return document
    }

    /// One recording's transcript, standalone.
    @MainActor
    static func transcriptDocument(for meeting: Meeting, recording: Recording) -> ExportDocument {
        var document = header(for: meeting, languageSample: transcriptText([recording]))
        document.blocks.append(.heading(level: 2, text: document.labels.transcript))
        document.blocks += transcriptBlocks(for: meeting, recording: recording, nameByLabel: speakerNames(for: meeting))
        return document
    }

    /// One summary, standalone.
    @MainActor
    static func summaryDocument(for meeting: Meeting, summary: Summary) -> ExportDocument {
        var document = header(for: meeting, languageSample: summaryText(summary))
        document.blocks = summaryBlocks(summary, labels: document.labels)
        return document
    }

    /// Title, date and properties, with the labels of the language
    /// `languageSample` is written in (see `ExportLanguage`).
    @MainActor
    private static func header(for meeting: Meeting, languageSample: String) -> ExportDocument {
        let labels = ExportLanguage.labels(for: languageSample, fallback: meeting.language)
        return ExportDocument(
            title: meeting.title,
            dateLine: ExportLanguage.dateLine(for: meeting.createdAt, labels: labels),
            duration: meeting.totalDuration > 0 ? meeting.totalDuration.clockDisplay : nil,
            properties: ExportDocument.Properties(
                date: meeting.createdAt,
                tags: meeting.tags.map(\.name),
                folderPath: meeting.folder.map(folderPath),
                isFavorite: meeting.isFavorite
            ),
            labels: labels
        )
    }

    /// A summary's text as one string, for language detection.
    private static func summaryText(_ summary: Summary) -> String {
        summary.sections
            .flatMap { [$0.title, $0.body] + $0.items }
            .joined(separator: "\n")
    }

    /// The opening of the recordings' transcripts, for language detection —
    /// stopping once there is enough, so a long meeting costs no more.
    @MainActor
    private static func transcriptText(_ recordings: [Recording]) -> String {
        var text = ""
        for recording in recordings {
            for segment in recording.transcript?.segments ?? [] {
                text += segment.text + "\n"
                if text.count >= ExportLanguage.sampleLimit { return text }
            }
        }
        return text
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

    private static func summaryBlocks(_ summary: Summary, labels: ExportLabels) -> [ExportDocument.Block] {
        var blocks: [ExportDocument.Block] = [.heading(level: 2, text: labels.summary)]
        for section in summary.sections {
            if !section.title.isEmpty {
                blocks.append(.heading(level: 3, text: section.title))
            }
            if !section.body.isEmpty {
                blocks.append(.markdown(section.body))
            }
            if !section.items.isEmpty {
                blocks.append(.bulletItems(section.items))
            }
        }
        return blocks
    }

    /// Every recording-relative highlight, converted to meeting-relative
    /// stamps and sorted chronologically. Static document, no tap-to-seek —
    /// purely a navigational list.
    @MainActor
    private static func highlightBlocks(for meeting: Meeting, labels: ExportLabels) -> [ExportDocument.Block] {
        let stamps = meeting.recordings
            .filter(\.isReadyForConsumption)
            .sorted { $0.recordedAt < $1.recordedAt }
            .flatMap { recording in
                recording.highlights.map { meeting.startOffset(of: recording) + $0.timestamp }
            }
            .sorted()
        guard !stamps.isEmpty else { return [] }
        return [
            .heading(level: 2, text: labels.highlights),
            .bulletItems(stamps.map(\.clockDisplay))
        ]
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
    private static func transcriptBlocks(
        for meeting: Meeting,
        recording: Recording,
        nameByLabel: [String: String]
    ) -> [ExportDocument.Block] {
        var blocks: [ExportDocument.Block] = []
        let offset = meeting.startOffset(of: recording)
        let highlights = recording.highlights
        let photos = recording.photos
        for segment in recording.transcript?.segments ?? [] {
            let isHighlighted = highlights.contains { $0.timestamp >= segment.startTime && $0.timestamp < segment.endTime }
            blocks.append(.utterance(ExportDocument.Utterance(
                timestamp: (segment.startTime + offset).clockDisplay,
                speaker: nameByLabel[segment.speakerLabel] ?? segment.speakerLabel,
                text: segment.text,
                isHighlighted: isHighlighted
            )))
            // The image itself is never exported — same policy as audio — but
            // its OCR text, if any, is already just text and carries the
            // context forward.
            for photo in photos where photo.capturedAt >= segment.startTime && photo.capturedAt < segment.endTime {
                blocks.append(.photo(
                    timestamp: (photo.capturedAt + offset).clockDisplay,
                    recognizedText: photo.recognizedText
                ))
            }
        }
        return blocks
    }

    // MARK: - Files

    /// Write the Markdown to a temporary `.md` file and return its URL.
    ///
    /// Each call gets its own UUID-named subdirectory under the temp
    /// directory (rather than writing `<title>.md` straight into the shared
    /// temp root) so two exports with the same or empty title — sharing
    /// twice in quick succession, or two meetings that both fall back to
    /// "meeting.md" — never collide on the same path while one share sheet
    /// is still open and the other's `.atomic` write or later cleanup runs.
    /// Prefix of every export folder in the temp directory; see `TempFileCleaner`.
    static let exportDirectoryPrefix = "kurn_export_"

    @MainActor
    static func temporaryFile(for meeting: Meeting, summary: Summary?) throws -> URL {
        try temporaryFile(markdown: markdown(for: meeting, summary: summary), suggestedName: meeting.title)
    }

    /// Write arbitrary Markdown to a temporary `.md` file, named after
    /// `suggestedName` (sanitized), and return its URL.
    static func temporaryFile(markdown text: String, suggestedName: String) throws -> URL {
        try temporaryFile(data: Data(text.utf8), suggestedName: suggestedName, fileExtension: "md")
    }

    /// Write an export of any format to a temporary file named after
    /// `suggestedName` (sanitized) with `fileExtension`, and return its URL.
    /// See `temporaryFile(for:summary:)` for why each call gets its own
    /// UUID-named subdirectory.
    ///
    /// The file is written protected (`.completeFileProtectionUnlessOpen`)
    /// rather than stamped after the fact, and the folder carries
    /// `exportDirectoryPrefix` so `TempFileCleaner` removes it once it is an
    /// hour old: an export is meeting content, and the share sheet only needs
    /// it for as long as it is open.
    static func temporaryFile(data: Data, suggestedName: String, fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(exportDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: suggestedName, fileExtension: fileExtension))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        RecordingProtection.apply(to: url)
        return url
    }

    /// `suggestedName` reduced to alphanumeric words joined by dashes, with
    /// `meeting` standing in when nothing survives.
    static func fileName(for suggestedName: String, fileExtension: String) -> String {
        let safeName = suggestedName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return (safeName.isEmpty ? "meeting" : safeName) + "." + fileExtension
    }
}
