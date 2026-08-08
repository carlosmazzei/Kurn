//
//  LLMTranscriptCorrectorTests.swift
//  KurnTests
//
//  Pure logic (eligibility, batching, JSON parsing, alignment) needs no
//  network and is tested directly. `requestCorrections` is exercised once
//  against a real `OpenAIProvider` over `MockURLProtocol` to verify the
//  request/response shape, mirroring `ProviderHTTPTests`.
//

import Foundation
import Testing
@testable import Kurn

@Suite(.serialized)
struct LLMTranscriptCorrectorTests {

    private func segment(
        text: String,
        confidence: Float? = nil,
        speakerLabel: String = "Speaker 1"
    ) -> TranscriptSegment {
        TranscriptSegment(speakerLabel: speakerLabel, startTime: 0, endTime: 1, text: text, confidence: confidence)
    }

    // MARK: - isEligible

    @Test func emptyTextIsNotEligible() {
        #expect(!LLMTranscriptCorrector.isEligible(segment(text: "   ", confidence: nil)))
    }

    @Test func nilConfidenceIsEligible() {
        // Apple Speech / FluidAudio Parakeet never report a confidence, so
        // there is no signal to filter on: stays eligible.
        #expect(LLMTranscriptCorrector.isEligible(segment(text: "hello", confidence: nil)))
    }

    @Test func belowThresholdConfidenceIsEligible() {
        #expect(LLMTranscriptCorrector.isEligible(segment(text: "hello", confidence: 0.5)))
    }

    @Test func atOrAboveThresholdConfidenceIsNotEligible() {
        #expect(!LLMTranscriptCorrector.isEligible(segment(text: "hello", confidence: LLMTranscriptCorrector.lowConfidenceThreshold)))
        #expect(!LLMTranscriptCorrector.isEligible(segment(text: "hello", confidence: 0.99)))
    }

    // MARK: - batches

    @Test func batchesNeverSplitASegment() {
        // Each segment (10 chars) alone exceeds half the 15-char budget, so a
        // correct packer can only ever fit one whole segment per batch here —
        // never a partial one.
        let segments = (0..<5).map { _ in segment(text: String(repeating: "x", count: 10), confidence: nil) }
        let batches = LLMTranscriptCorrector.batches(segments, maxChars: 15, maxCount: 100)
        let totalInBatches = batches.reduce(0) { $0 + $1.count }
        #expect(totalInBatches == segments.count)
        for batch in batches {
            #expect(batch.count == 1)
        }
    }

    @Test func batchesRespectCountCap() {
        let segments = (0..<10).map { _ in segment(text: "x", confidence: nil) }
        let batches = LLMTranscriptCorrector.batches(segments, maxChars: 10_000, maxCount: 3)
        for batch in batches {
            #expect(batch.count <= 3)
        }
        #expect(batches.reduce(0) { $0 + $1.count } == segments.count)
    }

    @Test func batchesPreserveOrder() {
        let segments = (0..<12).map { segment(text: "word\($0)", confidence: nil) }
        let batches = LLMTranscriptCorrector.batches(segments, maxChars: 20, maxCount: 4)
        let flattened = batches.flatMap { $0 }
        #expect(flattened.map(\.id) == segments.map(\.id))
    }

    // MARK: - parseCorrections

    @Test func parseCorrectionsDecodesValidJSON() {
        let id = UUID()
        let reply = #"{"segments":[{"id":"\#(id.uuidString)","text":"corrected text"}]}"#
        let result = LLMTranscriptCorrector.parseCorrections(from: reply)
        #expect(result[id] == "corrected text")
    }

    @Test func parseCorrectionsStripsMarkdownFences() {
        let id = UUID()
        let reply = "```json\n{\"segments\":[{\"id\":\"\(id.uuidString)\",\"text\":\"fixed\"}]}\n```"
        let result = LLMTranscriptCorrector.parseCorrections(from: reply)
        #expect(result[id] == "fixed")
    }

    @Test func parseCorrectionsOnMalformedJSONReturnsEmptyMap() {
        #expect(LLMTranscriptCorrector.parseCorrections(from: "not json at all").isEmpty)
    }

    @Test func parseCorrectionsSkipsNonUUIDIds() {
        let reply = #"{"segments":[{"id":"not-a-uuid","text":"fixed"}]}"#
        #expect(LLMTranscriptCorrector.parseCorrections(from: reply).isEmpty)
    }

    // MARK: - apply

    @Test func applyPatchesOnlyMatchingEligibleIds() {
        let a = segment(text: "hello world", confidence: nil)
        let b = segment(text: "goodbye now", confidence: nil)
        let segments = [a, b]

        let corrections: [UUID: String] = [a.id: "hello world!"]
        let result = LLMTranscriptCorrector.apply(corrections: corrections, to: segments)

        #expect(result.count == segments.count)
        #expect(result[0].text == "hello world!")
        #expect(result[1].text == "goodbye now") // untouched: no correction supplied
    }

    @Test func applyPreservesOrderLengthAndNonTextFields() {
        let a = segment(text: "hello", confidence: 0.4, speakerLabel: "Speaker A")
        let b = segment(text: "world", confidence: 0.9, speakerLabel: "Speaker B")
        let segments = [a, b]
        let corrections: [UUID: String] = [a.id: "hello!", b.id: "world!"]

        let result = LLMTranscriptCorrector.apply(corrections: corrections, to: segments)

        #expect(result.map(\.id) == segments.map(\.id))
        #expect(result.map(\.speakerLabel) == segments.map(\.speakerLabel))
        #expect(result.map(\.startTime) == segments.map(\.startTime))
        #expect(result.map(\.endTime) == segments.map(\.endTime))
        #expect(result.map(\.confidence) == segments.map(\.confidence))
    }

    @Test func applyRejectsAWholesaleRewriteViaGuardrail() {
        let a = segment(text: "the quarterly numbers are looking strong", confidence: nil)
        let corrections: [UUID: String] = [a.id: "completely different sentence about something else entirely"]
        let result = LLMTranscriptCorrector.apply(corrections: corrections, to: [a])
        #expect(result[0].text == a.text)
    }

    @Test func applyIgnoresIdsNotPresentInInputSegments() {
        let a = segment(text: "hello", confidence: nil)
        let phantomID = UUID()
        let corrections: [UUID: String] = [phantomID: "should never appear"]
        let result = LLMTranscriptCorrector.apply(corrections: corrections, to: [a])
        #expect(result.count == 1)
        #expect(result[0].text == "hello")
    }

    // MARK: - correct(segments:...) confidence gating, composed without network

    @Test func onlyLowOrUnknownConfidenceSegmentsAreEligibleForCorrection() {
        let confidentlyRight = segment(text: "already correct", confidence: 0.95)
        let uncertain = segment(text: "unc3rtain wrd", confidence: 0.3)
        let noSignal = segment(text: "apple speech text", confidence: nil)
        let segments = [confidentlyRight, uncertain, noSignal]

        let candidates = segments.filter(LLMTranscriptCorrector.isEligible)
        #expect(candidates.map(\.id).sorted { $0.uuidString < $1.uuidString } ==
                 [uncertain, noSignal].map(\.id).sorted { $0.uuidString < $1.uuidString })

        // A correction offered for the high-confidence segment (which was
        // never sent) must not be applied even if somehow present.
        let corrections: [UUID: String] = [
            confidentlyRight.id: "tampered",
            uncertain.id: "uncertain word"
        ]
        let result = LLMTranscriptCorrector.apply(corrections: corrections, to: segments)
        #expect(result[0].text == confidentlyRight.text) // untouched despite a correction key existing
        #expect(result[1].text == "uncertain word")
        #expect(result[2].text == noSignal.text)
    }

    // MARK: - NoOpTranscriptCorrector

    @Test func noOpCorrectorReturnsInputUnchanged() async {
        let segments = [segment(text: "hello", confidence: nil), segment(text: "world", confidence: 0.9)]
        let result = await NoOpTranscriptCorrector().correct(
            segments: segments, language: .autoDetect, provider: .openAI, model: "", onProgress: { _ in }
        )
        #expect(result.map(\.id) == segments.map(\.id))
        #expect(result.map(\.text) == segments.map(\.text))
    }

    // MARK: - requestCorrections network shape

    @Test func requestCorrectionsSendsIdsAndParsesReply() async throws {
        let a = segment(text: "we ned to ship", confidence: 0.3)
        let b = segment(text: "this is fine", confidence: 0.4)

        let replyJSON = """
        {"segments":[{"id":"\(a.id.uuidString)","text":"we need to ship"},{"id":"\(b.id.uuidString)","text":"this is fine"}]}
        """
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": replyJSON]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let corrections = await LLMTranscriptCorrector().requestCorrections(
            for: [a, b], vocabulary: ["ship"], language: .english, llm: provider
        )

        #expect(corrections[a.id] == "we need to ship")
        #expect(corrections[b.id] == "this is fine")

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try JSONSerialization.jsonObject(with: MockURLProtocol.body(of: request)) as? [String: Any]
        let messages = body?["messages"] as? [[String: String]]
        let userMessage = messages?.last?["content"] ?? ""
        #expect(userMessage.contains(a.id.uuidString))
        #expect(userMessage.contains(b.id.uuidString))
        #expect(userMessage.contains("ship"))
    }

    @Test func requestCorrectionsFailsOpenOnTransportError() async {
        MockURLProtocol.enqueue([.failure(URLError(.notConnectedToInternet))])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())
        let a = segment(text: "hello", confidence: 0.3)

        let corrections = await LLMTranscriptCorrector().requestCorrections(
            for: [a], vocabulary: [], language: .autoDetect, llm: provider
        )
        #expect(corrections.isEmpty)
    }
}
