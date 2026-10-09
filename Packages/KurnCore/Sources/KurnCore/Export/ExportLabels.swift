//
//  ExportLabels.swift
//  KurnCore
//
//  The words an export adds around the meeting's own content — section
//  headings and the duration label — in the language of that content, so a
//  Portuguese summary reads "Resumo", not "Summary". The language is the
//  document's, detected by the caller from the summary or transcript, never
//  the app's UI language: the reader of an exported file is often not the
//  person who exported it.
//
//  A table rather than `Localizable.strings`: these follow the meeting's
//  language, which can be one the app itself is not localized into, and the
//  package has no bundle of its own to look strings up in.
//

import Foundation

public struct ExportLabels: Equatable, Sendable {
    /// BCP-47 language code the labels are written in ("pt", "zh"), used for
    /// the document's own language metadata (`<html lang>`, Word's `w:lang`).
    public var languageCode: String
    public var notes: String
    public var summary: String
    public var highlights: String
    public var transcript: String
    public var duration: String
    /// Heading for the n-th recording of a multi-recording transcript; `%d`
    /// is replaced by the number.
    public var segmentFormat: String

    public init(
        languageCode: String,
        notes: String,
        summary: String,
        highlights: String,
        transcript: String,
        duration: String,
        segmentFormat: String
    ) {
        self.languageCode = languageCode
        self.notes = notes
        self.summary = summary
        self.highlights = highlights
        self.transcript = transcript
        self.duration = duration
        self.segmentFormat = segmentFormat
    }

    public func segment(_ number: Int) -> String {
        segmentFormat.replacingOccurrences(of: "%d", with: String(number))
    }

    public static let english = ExportLabels(
        languageCode: "en", notes: "Notes", summary: "Summary", highlights: "Highlights",
        transcript: "Transcript", duration: "Duration", segmentFormat: "Segment %d"
    )

    /// Labels for a BCP-47 tag or bare code ("pt-BR", "pt", "zh-Hans"),
    /// English for anything without a table entry.
    public static func forLanguage(_ tag: String?) -> ExportLabels {
        guard let tag, let base = tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else { return .english }
        return table[base.lowercased()] ?? .english
    }

    /// Languages with a table entry: the app's seven localizations plus the
    /// most common other meeting languages.
    public static var supportedLanguageCodes: [String] { table.keys.sorted() }

    static let table: [String: ExportLabels] = [
        "en": .english,
        "pt": ExportLabels(
            languageCode: "pt", notes: "Notas", summary: "Resumo", highlights: "Destaques",
            transcript: "Transcrição", duration: "Duração", segmentFormat: "Segmento %d"
        ),
        "es": ExportLabels(
            languageCode: "es", notes: "Notas", summary: "Resumen", highlights: "Destacados",
            transcript: "Transcripción", duration: "Duración", segmentFormat: "Segmento %d"
        ),
        "fr": ExportLabels(
            languageCode: "fr", notes: "Notes", summary: "Résumé", highlights: "Moments clés",
            transcript: "Transcription", duration: "Durée", segmentFormat: "Segment %d"
        ),
        "it": ExportLabels(
            languageCode: "it", notes: "Note", summary: "Riepilogo", highlights: "Momenti salienti",
            transcript: "Trascrizione", duration: "Durata", segmentFormat: "Segmento %d"
        ),
        "de": ExportLabels(
            languageCode: "de", notes: "Notizen", summary: "Zusammenfassung", highlights: "Highlights",
            transcript: "Transkript", duration: "Dauer", segmentFormat: "Abschnitt %d"
        ),
        "zh": ExportLabels(
            languageCode: "zh", notes: "笔记", summary: "摘要", highlights: "重点",
            transcript: "转录", duration: "时长", segmentFormat: "第 %d 段"
        ),
        "ja": ExportLabels(
            languageCode: "ja", notes: "メモ", summary: "要約", highlights: "ハイライト",
            transcript: "文字起こし", duration: "時間", segmentFormat: "セグメント %d"
        ),
        "ko": ExportLabels(
            languageCode: "ko", notes: "메모", summary: "요약", highlights: "하이라이트",
            transcript: "녹취록", duration: "길이", segmentFormat: "세그먼트 %d"
        ),
        "nl": ExportLabels(
            languageCode: "nl", notes: "Notities", summary: "Samenvatting", highlights: "Hoogtepunten",
            transcript: "Transcriptie", duration: "Duur", segmentFormat: "Segment %d"
        ),
        "ru": ExportLabels(
            languageCode: "ru", notes: "Заметки", summary: "Резюме", highlights: "Ключевые моменты",
            transcript: "Расшифровка", duration: "Длительность", segmentFormat: "Фрагмент %d"
        )
    ]
}
