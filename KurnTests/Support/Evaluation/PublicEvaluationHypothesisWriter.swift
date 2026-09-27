//
//  PublicEvaluationHypothesisWriter.swift
//  KurnTests
//
//  What `PublicDatasetEvaluationHarnessTests` scored, kept. The CSV holds only
//  this repository's own WER/DER counts, so a doubt about the scorer could
//  only be settled by re-running the whole matrix. With each cell's output on
//  disk as JSON Lines (`KURN_PUBLIC_EVAL_HYPOTHESES`), the same output is
//  re-scored by the industry's reference implementations in
//  `Tools/evaluation/rescore.py` — Whisper's text normalizers with `jiwer`,
//  `pyannote.metrics` for DER, `meeteval` for speaker-attributed WER.
//
//  Only public benchmark audio ever reaches this harness, so writing its
//  transcripts to a file carries none of the concerns that keep meeting-derived
//  text out of loose files in the app.
//

import Foundation
import KurnCore
@testable import Kurn

/// Appends one JSON line per scored cell: what the pipeline actually
/// produced, so the numbers can be re-derived by independent, standard
/// scorers instead of only by this file's own implementation.
final class PublicEvaluationHypothesisWriter {
    struct Segment: Encodable {
        var speaker: String
        var start: Double
        var end: Double
        var text: String?
    }

    struct Record: Encodable {
        var corpus: String
        var name: String
        var language: String
        var configuration: String
        var segments: [Segment]
        var turns: [Segment]
    }

    private let handle: FileHandle
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(path: String, resuming: Bool) throws {
        if !resuming || !FileManager.default.fileExists(atPath: path) {
            try Data().write(to: URL(fileURLWithPath: path))
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
    }

    func append(
        corpus: String,
        name: String,
        language: String,
        configuration: String,
        output: TranscriptionService.Output
    ) {
        let record = Record(
            corpus: corpus,
            name: name,
            language: language,
            configuration: configuration,
            segments: output.segments.map {
                Segment(speaker: $0.speakerLabel, start: $0.startTime, end: $0.endTime, text: $0.text)
            },
            turns: output.turns.map {
                Segment(speaker: $0.speakerLabel, start: $0.start, end: $0.end, text: nil)
            }
        )
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }
}
