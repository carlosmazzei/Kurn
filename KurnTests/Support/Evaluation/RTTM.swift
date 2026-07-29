//
//  RTTM.swift
//  KurnTests
//
//  The annotation format every diarization corpus and scoring tool speaks
//  (NIST Rich Transcription). Reading it is what lets a reference produced in
//  Audacity, ELAN, pyannote or `dscore` be scored against this app's output
//  without a conversion step in between — and writing it is what lets the app's
//  output be checked against those tools instead of only against this file.
//
//  One line per turn, space-separated:
//
//      SPEAKER <file> <channel> <start> <duration> <NA> <NA> <speaker> <NA> <NA>
//
//  Only `SPEAKER` lines carry turns; anything else in the file is ignored rather
//  than rejected, because real annotation tools emit comments and other record
//  types alongside them.
//

import Foundation

enum RTTM {

    /// Parse turns out of an RTTM document. Malformed lines are skipped, not
    /// thrown on: a reference file with one bad row should still score.
    static func parse(_ text: String) -> [DiarizationErrorRate.Segment] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 8, fields[0] == "SPEAKER" else { return nil }
            guard let start = TimeInterval(fields[3]),
                  let duration = TimeInterval(fields[4]),
                  start.isFinite, duration.isFinite, duration > 0 else { return nil }
            return DiarizationErrorRate.Segment(
                label: String(fields[7]),
                start: start,
                end: start + duration
            )
        }
    }

    /// Render turns as RTTM, so a result can be handed to an external scorer.
    static func format(_ segments: [DiarizationErrorRate.Segment], fileID: String) -> String {
        segments
            .map { segment in
                String(
                    format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>",
                    fileID, segment.start, segment.duration, segment.label
                )
            }
            .joined(separator: "\n")
    }
}
