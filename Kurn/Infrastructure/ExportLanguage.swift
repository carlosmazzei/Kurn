//
//  ExportLanguage.swift
//  Kurn
//
//  Decides which language an export's own words (section headings, the
//  duration label, the date) are written in: the language of the content
//  being exported — the summary, or the transcript when there is none — as
//  `NLLanguageRecognizer` reads it. A summary is written in the transcript's
//  language or translated on request, so the meeting's configured language
//  is only the fallback, for content too short to judge.
//

import Foundation
import KurnCore
import NaturalLanguage

enum ExportLanguage {
    /// Below this many characters the recognizer's guess is noise ("Recap",
    /// "part 0"), so the fallback decides.
    static let minimumSampleLength = 40
    static let minimumConfidence = 0.6
    /// Enough text to recognize any language; a two-hour transcript adds
    /// nothing but time.
    static let sampleLimit = 4_000

    /// The language code of `text`, or of `fallback` when the text is too
    /// short or too mixed to judge; `nil` when neither says.
    static func code(for text: String, fallback: MeetingLanguage) -> String? {
        let sample = String(text.prefix(sampleLimit))
        if sample.count >= minimumSampleLength {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            if let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
               best.value >= minimumConfidence {
                return best.key.rawValue
            }
        }
        return fallback.whisperCode
    }

    static func labels(for text: String, fallback: MeetingLanguage) -> ExportLabels {
        ExportLabels.forLanguage(code(for: text, fallback: fallback))
    }

    /// The meeting's date and time written the way the document's language
    /// writes them ("8 de out. de 2026 14:00" in a Portuguese export).
    static func dateLine(for date: Date, labels: ExportLabels) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: labels.languageCode)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
