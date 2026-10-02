//
//  WhisperSegmentAssemblyTests.swift
//  KurnCoreTests
//
//  What `WhisperCppTranscriber` does with the raw values whisper.cpp reports:
//  SentencePiece pieces into words, token probabilities into a confidence,
//  centiseconds into seconds — and the progress mapping across chunks.
//

import Foundation
import Testing
@testable import KurnCore

struct WhisperSegmentAssemblyTests {

    private func token(_ piece: String, _ start: Int64, _ end: Int64, p: Float = 0.9) -> WhisperDecodedToken {
        WhisperDecodedToken(piece: piece, startCentiseconds: start, endCentiseconds: end, probability: p)
    }

    @Test func piecesWithoutALeadingSpaceExtendTheCurrentWord() {
        let words = WhisperSegmentAssembly.words(from: [
            token(" o", 0, 10),
            token(" or", 12, 30),
            token("ça", 30, 45),
            token("mento", 45, 80)
        ])
        #expect(words == [
            TimedWord(text: "o", start: 0, end: 0.1),
            TimedWord(text: "orçamento", start: 0.12, end: 0.8)
        ])
    }

    @Test func aLeadingPieceWithoutSpaceStillOpensTheFirstWord() {
        let words = WhisperSegmentAssembly.words(from: [token("Ok", 5, 20), token(" sim", 25, 40)])
        #expect(words.map(\.text) == ["Ok", "sim"])
    }

    @Test func whitespaceOnlyPiecesAreSkippedAndInvertedBoundsClamp() {
        let words = WhisperSegmentAssembly.words(from: [token(" ", 0, 5), token(" fim", 50, 40)])
        #expect(words == [TimedWord(text: "fim", start: 0.5, end: 0.5)])
    }

    @Test func qualityAveragesTextTokenLogProbabilities() throws {
        let quality = WhisperSegmentAssembly.quality(tokenProbabilities: [0.5, 0.5], noSpeechProbability: 0.1)
        let average = try #require(quality.averageLogProb)
        #expect(abs(average - log(0.5)) < 1e-9)
        #expect(abs((quality.noSpeechProb ?? 0) - 0.1) < 1e-6)
        #expect(quality.compressionRatio == nil)
    }

    @Test func zeroProbabilityIsFlooredAndNonFiniteValuesIgnored() throws {
        let quality = WhisperSegmentAssembly.quality(
            tokenProbabilities: [0, .nan, .infinity],
            noSpeechProbability: .nan
        )
        let average = try #require(quality.averageLogProb)
        #expect(abs(average - log(1e-10)) < 1e-9)
        #expect(quality.noSpeechProb == nil)
    }

    @Test func noTokensMeansNoLogProbability() {
        let quality = WhisperSegmentAssembly.quality(tokenProbabilities: [], noSpeechProbability: 0.2)
        #expect(quality.averageLogProb == nil)
    }

    @Test func scoredSpanTrimsTextAndConvertsBounds() throws {
        let scored = try #require(WhisperSegmentAssembly.scoredSpan(
            text: "  Bom dia.  ",
            startCentiseconds: 150,
            endCentiseconds: 320,
            tokens: [token(" Bom", 150, 200), token(" dia", 200, 300), token(".", 300, 320)],
            noSpeechProbability: 0.01
        ))
        #expect(scored.span == TranscribedSpan(text: "Bom dia.", start: 1.5, end: 3.2, confidence: nil))
        #expect(scored.words.map(\.text) == ["Bom", "dia."])
        #expect(scored.quality.averageLogProb != nil)
    }

    @Test func blankSegmentsAreDroppedAndEndClampsToStart() {
        #expect(WhisperSegmentAssembly.scoredSpan(
            text: " \n", startCentiseconds: 0, endCentiseconds: 100, tokens: [], noSpeechProbability: 0
        ) == nil)
        let clamped = WhisperSegmentAssembly.scoredSpan(
            text: "x", startCentiseconds: 500, endCentiseconds: 100, tokens: [], noSpeechProbability: 0
        )
        #expect(clamped?.span.end == 5)
    }

    @Test func oneCoreIsLeftForTheInterface() {
        #expect(WhisperSegmentAssembly.inferenceThreadCount(activeProcessors: 6) == 5)
        #expect(WhisperSegmentAssembly.inferenceThreadCount(activeProcessors: 1) == 1)
        #expect(WhisperSegmentAssembly.inferenceThreadCount(activeProcessors: 0) == 1)
    }

    @Test func chunkProgressMapsIntoTheWholeRun() {
        let middle = ChunkedProgress.overall(chunkIndex: 1, fraction: 0.5, total: 4)
        #expect(middle.fraction == 0.375)
        #expect(middle.completedChunks == 2)
        #expect(ChunkedProgress.overall(chunkIndex: 0, fraction: 2, total: 2).fraction == 0.5)
        #expect(ChunkedProgress.overall(chunkIndex: 0, fraction: -1, total: 2).fraction == 0)
        #expect(ChunkedProgress.overall(chunkIndex: 0, fraction: .nan, total: 0).fraction == 0)
        #expect(ChunkedProgress.overall(chunkIndex: 3, fraction: 1, total: 2).completedChunks == 2)
    }
}
