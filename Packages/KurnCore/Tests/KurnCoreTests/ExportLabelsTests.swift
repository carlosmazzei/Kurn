//
//  ExportLabelsTests.swift
//  KurnCoreTests
//
//  Section headings and the duration label follow the exported content's
//  language, and every format carries that language in its own metadata.
//

import Foundation
import Testing
@testable import KurnCore

struct ExportLabelsTests {

    @Test func resolvesTagsByTheirBaseLanguage() {
        #expect(ExportLabels.forLanguage("pt-BR").summary == "Resumo")
        #expect(ExportLabels.forLanguage("pt_PT").transcript == "Transcrição")
        #expect(ExportLabels.forLanguage("zh-Hans").summary == "摘要")
        #expect(ExportLabels.forLanguage("ES").notes == "Notas")
    }

    @Test func unknownOrMissingLanguagesFallBackToEnglish() {
        #expect(ExportLabels.forLanguage(nil) == .english)
        #expect(ExportLabels.forLanguage("") == .english)
        #expect(ExportLabels.forLanguage("tlh") == .english)
    }

    @Test func everyAppLocalizationHasAnEntry() {
        for code in ["en", "pt", "es", "fr", "it", "de", "zh"] {
            #expect(ExportLabels.supportedLanguageCodes.contains(code), "missing \(code)")
        }
    }

    @Test func everyEntryIsCompleteAndNumbersSegments() {
        for code in ExportLabels.supportedLanguageCodes {
            let labels = ExportLabels.forLanguage(code)
            #expect(labels.languageCode == code)
            for text in [labels.notes, labels.summary, labels.highlights, labels.transcript, labels.duration] {
                #expect(!text.isEmpty, "\(code) has an empty label")
            }
            #expect(labels.segmentFormat.contains("%d"), "\(code) segment heading has no number")
            #expect(labels.segment(3).contains("3"))
        }
        #expect(ExportLabels.forLanguage("pt").segment(2) == "Segmento 2")
    }

    @Test func renderersUseTheDocumentsLabels() throws {
        let document = ExportDocument(
            title: "Planejamento",
            dateLine: "8 de out.",
            duration: "1:00",
            properties: ExportDocument.Properties(date: Date(timeIntervalSince1970: 0)),
            labels: .forLanguage("pt"),
            blocks: [.heading(level: 2, text: "Resumo")]
        )
        #expect(MarkdownExportRenderer.render(document).contains("**Duração:** 1:00"))
        #expect(PlainTextExportRenderer.render(document).contains("Duração: 1:00"))

        let html = HTMLExportRenderer.render(document)
        #expect(html.contains("<html lang=\"pt\">"))
        #expect(html.contains("Duração: 1:00"))

        let entries = try ZipTestReader.entries(in: DOCXExportRenderer.render(document))
        let styles = try #require(entries.first { $0.name == "word/styles.xml" }).text
        #expect(styles.contains("<w:lang w:val=\"pt\" w:eastAsia=\"pt\" w:bidi=\"pt\"/>"))
        let body = try #require(entries.first { $0.name == "word/document.xml" }).text
        #expect(body.contains("Duração: 1:00"))
    }
}
