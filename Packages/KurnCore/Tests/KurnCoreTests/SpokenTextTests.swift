//
//  SpokenTextTests.swift
//  KurnCoreTests
//
//  `SpokenText` decides what the read-aloud feature says. Markdown syntax and
//  `[mm:ss]` citations must never be voiced, headings and bullets must end in a
//  pause, and chunking must respect a provider's per-request limit without
//  losing or reordering a single word.
//

import Foundation
import Testing
@testable import KurnCore

struct SpokenTextTests {

    // MARK: - Inline cleanup

    @Test func stripsEmphasisCodeAndLinks() {
        let spoken = SpokenText.inline("**Ana** will _review_ the `budget` in [the doc](https://x.y/z).")
        #expect(spoken == "Ana will review the budget in the doc.")
    }

    @Test func keepsSnakeCaseIdentifiers() {
        #expect(SpokenText.inline("rename user_id to owner_id") == "rename user_id to owner_id")
    }

    @Test func removesTimestampCitationsAndRanges() {
        let spoken = SpokenText.inline("We shipped it [12:34]. Budget approved [1:02:03–1:05:00], see (03:15).")
        #expect(spoken == "We shipped it. Budget approved, see.")
    }

    @Test func removesBareURLsAndHTML() {
        #expect(SpokenText.inline("Notes<br>at https://example.com/a?b=c now") == "Notes at now")
    }

    // MARK: - Markdown blocks

    @Test func headingsAndListItemsBecomeSentences() {
        let spoken = SpokenText.fromMarkdown("## Decisions\n\n- Ship Friday\n- [x] Tell Ana\n\nDone!")
        #expect(spoken == "Decisions.\n\nShip Friday.\nTell Ana.\n\nDone!")
    }

    @Test func dropsCodeBlocksAndRules() {
        let spoken = SpokenText.fromMarkdown("Intro\n\n```\nlet x = 1\n```\n\n---\n\nOutro")
        #expect(spoken == "Intro.\n\nOutro.")
    }

    @Test func tablesReadRowByRowWithHeaders() {
        let markdown = "| Owner | Task |\n|---|---|\n| Ana | Deck |\n| Bo | |"
        #expect(SpokenText.fromMarkdown(markdown) == "Owner: Ana, Task: Deck.\nOwner: Bo.")
    }

    @Test func summarySectionsReadTitleBodyAndItems() {
        let sections = [
            SummarySection(title: "Overview", body: "A **short** call [00:10].", items: []),
            SummarySection(title: "Action items", items: ["[ ] Send notes", "Book room\n- by Monday"])
        ]
        let spoken = SpokenText.fromSections(sections)
        #expect(spoken == "Overview.\n\nA short call.\n\nAction items.\n\nSend notes.\n\nBook room.\nby Monday.")
    }

    @Test func emptyInputProducesNothing() {
        #expect(SpokenText.fromMarkdown("  \n\n ").isEmpty)
        #expect(SpokenText.fromSections([SummarySection(title: " ")]).isEmpty)
        #expect(SpokenText.chunks("   ", maxCharacters: 100).isEmpty)
    }

    // MARK: - Chunking

    @Test func shortTextIsOneChunk() {
        #expect(SpokenText.chunks("One.\n\nTwo.", maxCharacters: 100) == ["One.\nTwo."])
    }

    @Test func paragraphsSplitWhenTheyDoNotFitTogether() {
        let first = String(repeating: "a", count: 60)
        let second = String(repeating: "b", count: 60)
        #expect(SpokenText.chunks("\(first)\n\n\(second)", maxCharacters: 100) == [first, second])
    }

    @Test func longParagraphSplitsAtSentences() {
        let text = "First sentence here. Second sentence here. Third one."
        let chunks = SpokenText.chunks(text, maxCharacters: 25)
        #expect(chunks == ["First sentence here.", "Second sentence here.", "Third one."])
    }

    @Test func longSentenceSplitsAtWordsAndOverlongWordsAreCut() {
        let chunks = SpokenText.chunks("alpha beta gamma abcdefghijkl", maxCharacters: 10)
        #expect(chunks == ["alpha beta", "gamma", "abcdefghij", "kl"])
    }

    @Test func fullWidthPunctuationEndsSentences() {
        let chunks = SpokenText.chunks("今天开会。明天发布。", maxCharacters: 6)
        #expect(chunks == ["今天开会。", "明天发布。"])
    }

    @Test func chunksRespectLimitAndPreserveEveryWord() {
        let words = (0..<400).map { "word\($0)" }
        var text = ""
        for (index, word) in words.enumerated() {
            text += word
            text += index % 13 == 12 ? ".\n\n" : (index % 5 == 4 ? ". " : " ")
        }
        for limit in [30, 200, 4_096] {
            let chunks = SpokenText.chunks(text, maxCharacters: limit)
            #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= limit })
            let rejoined = chunks.joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            #expect(rejoined == words)
        }
    }

    // MARK: - WAVE container

    @Test func wavHeaderDescribesPCM() {
        let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])
        let wav = PCMWaveFile.wrap(pcm: pcm, sampleRate: 24_000)
        #expect(wav.count == 44 + pcm.count)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(Self.uint32(wav, at: 4) == UInt32(36 + pcm.count))
        #expect(Self.uint32(wav, at: 24) == 24_000)
        #expect(Self.uint32(wav, at: 28) == 48_000)
        #expect(Self.uint32(wav, at: 40) == UInt32(pcm.count))
        #expect(wav.suffix(pcm.count) == pcm)
    }

    @Test func sampleRateParsesFromMimeType() {
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/L16;codec=pcm;rate=24000") == 24_000)
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/L16; rate = 16000") == 16_000)
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/mpeg") == nil)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(UInt32(0)) { value, pair in
            value | UInt32(pair.element) << (8 * UInt32(pair.offset))
        }
    }
}
