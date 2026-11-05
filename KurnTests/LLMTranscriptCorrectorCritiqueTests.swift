//
//  LLMTranscriptCorrectorCritiqueTests.swift
//  KurnTests
//
//  The topic critique, confidence and context inside `LLMTranscriptCorrector`
//  over a scripted provider: the critic pass runs first, its grounded
//  findings and the inferred domain terms ride with every batch, a confident
//  segment it flags is sent too, a correction adding unspoken words is
//  rejected, and a failed critique still corrects but reports itself as
//  degraded.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct LLMTranscriptCorrectorCritiqueTests {

    private struct ProviderDown: Error {}

    private static func segment(_ text: String, confidence: Float? = nil, at start: TimeInterval = 0) -> TranscriptSegment {
        TranscriptSegment(speakerLabel: "Speaker 1", startTime: start, endTime: start + 2, text: text, confidence: confidence)
    }

    private static let critique = """
    {"topic":"Moving the billing service to Kubernetes","domain":"software engineering",
     "key_terms":["Kubernetes","Helm"],
     "likely_mishearings":[{"heard":"cuber netes","intended":"Kubernetes"},
                           {"heard":"post gress","intended":"Postgres"}]}
    """

    private static func correct(
        _ segments: [TranscriptSegment],
        with llm: ScriptedLLMProvider
    ) async -> TranscriptCorrectionResult {
        let corrector = LLMTranscriptCorrector(resolveProvider: { _, _ in llm })
        return await corrector.correct(
            segments: segments, language: .english, provider: .openAI, model: "gpt-4o",
            onProgress: { _ in }
        )
    }

    @Test func theCritiqueRunsFirstAndGuidesEveryBatch() async throws {
        let uncertain = Self.segment("we move billing to cuber netes", confidence: 0.4)
        let confident = Self.segment("the Helm chart is ready", confidence: 0.99, at: 2)
        let fixed = #"{"segments":[{"id":"\#(uncertain.id.uuidString)","text":"we move billing to Kubernetes"}]}"#
        let llm = ScriptedLLMProvider(chat: { _, index in index == 0 ? Self.critique : fixed })

        let result = await Self.correct([uncertain, confident], with: llm)

        #expect(result.outcome == .succeeded)
        #expect(result.segments.map(\.text) == ["we move billing to Kubernetes", "the Helm chart is ready"])
        try #require(llm.chatCalls.count == 2)

        let analysis = llm.chatCalls[0]
        #expect(analysis.systemPrompt == TranscriptTopicAnalyzer.systemPrompt(language: .english))
        // The critic reads confident segments too: they are the evidence.
        #expect(analysis.messages.first?.content.contains("the Helm chart is ready") == true)

        let batch = llm.chatCalls[1]
        #expect(batch.systemPrompt == LLMTranscriptCorrector.systemPrompt(language: .english, topicAware: true))
        #expect(batch.systemPrompt.contains(LLMTranscriptCorrector.topicGuidance))
        #expect(batch.systemPrompt.contains(LLMTranscriptCorrector.contextGuidance))
        let sent = batch.messages.first?.content ?? ""
        #expect(sent.contains("Moving the billing service to Kubernetes"))
        #expect(sent.contains("software engineering"))
        #expect(sent.contains("cuber netes"))
        #expect(sent.contains("Kubernetes"))
        // Not in the transcript, so the critic invented it: never sent.
        #expect(!sent.contains("post gress"))
        #expect(!sent.contains(confident.id.uuidString))
    }

    @Test func aConfidentSegmentTheCriticFlagsIsSentWithItsConfidenceAndNeighbours() async throws {
        let opening = Self.segment("we are planning the migration", confidence: 0.98)
        let flagged = Self.segment("billing moves to cuber netes in May", confidence: 0.95, at: 2)
        let closing = Self.segment("any questions so far", confidence: 0.97, at: 4)
        let llm = ScriptedLLMProvider(chat: { _, index in index == 0 ? Self.critique : #"{"segments":[]}"# })

        let result = await Self.correct([opening, flagged, closing], with: llm)

        #expect(result.outcome == .succeeded)
        try #require(llm.chatCalls.count == 2)
        let sent = llm.chatCalls[1].messages.first?.content ?? ""
        #expect(sent.contains(flagged.id.uuidString))
        #expect(!sent.contains(opening.id.uuidString))
        #expect(!sent.contains(closing.id.uuidString))
        #expect(sent.contains(#""confidence":0.95"#))
        #expect(sent.contains(#""before":"we are planning the migration""#))
        #expect(sent.contains(#""after":"any questions so far""#))
    }

    @Test func aCorrectionThatAddsUnspokenWordsIsRejected() async {
        // Small enough for the magnitude guardrail (3 of 14 words), so only
        // the faithfulness check stands between "by Friday" and the transcript.
        let original = "so the plan is that we move the billing service to cuber netes soon"
        let uncertain = Self.segment(original, confidence: 0.4)
        let corrected = "so the plan is that we move the billing service to Kubernetes by Friday"
        #expect(TranscriptCorrectionGuardrail.accepts(original: original, corrected: corrected))
        let invented = #"{"segments":[{"id":"\#(uncertain.id.uuidString)","text":"\#(corrected)"}]}"#
        let llm = ScriptedLLMProvider(chat: { _, index in index == 0 ? Self.critique : invented })

        let result = await Self.correct([uncertain], with: llm)

        #expect(result.outcome == .succeeded)
        #expect(result.segments.map(\.text) == [original])
        // The magnitude guardrail alone would have let it through.
        let unguarded = LLMTranscriptCorrector.apply(corrections: [uncertain.id: corrected], to: [uncertain])
        #expect(unguarded.map(\.text) == [corrected])
    }

    @Test func neighbourContextIsTrimmedAndAbsentAtTheEdges() {
        let long = String(repeating: "a", count: LLMTranscriptCorrector.neighbourContextCharacters + 20)
        let segments = [Self.segment(long), Self.segment("middle", at: 2), Self.segment(long, at: 4)]
        let context = LLMTranscriptCorrector.neighbourContext(of: segments)

        #expect(context[segments[0].id]?.before == nil)
        #expect(context[segments[0].id]?.after == "middle")
        #expect(context[segments[2].id]?.after == nil)
        let before = context[segments[1].id]?.before ?? ""
        #expect(before.hasPrefix("…"))
        #expect(before.count == LLMTranscriptCorrector.neighbourContextCharacters + 1)
        #expect(context[segments[1].id]?.after?.hasSuffix("…") == true)
        #expect(LLMTranscriptCorrector.roundedConfidence(0.8349) == 0.83)
    }

    @Test func aFailedCritiqueStillCorrectsButIsReportedAsDegraded() async {
        let uncertain = Self.segment("we ned it", confidence: 0.4)
        let fixed = #"{"segments":[{"id":"\#(uncertain.id.uuidString)","text":"we need it"}]}"#
        let llm = ScriptedLLMProvider(chat: { _, index in
            if index == 0 { throw ProviderDown() }
            return fixed
        })

        let result = await Self.correct([uncertain], with: llm)

        #expect(result.outcome == .degraded)
        #expect(result.reason == .topicAnalysisFailed)
        #expect(result.segments.map(\.text) == ["we need it"])
        #expect(llm.chatCalls.count == 2)
        #expect(llm.chatCalls[1].systemPrompt == LLMTranscriptCorrector.systemPrompt(language: .english))
        #expect(!llm.chatCalls[1].systemPrompt.contains(LLMTranscriptCorrector.topicGuidance))
        #expect(llm.chatCalls[1].messages.first?.content.contains("\"topic\"") == false)
    }

    @Test func anUnparseableCritiqueIsAFailedAnalysis() async {
        let llm = ScriptedLLMProvider(chat: { _, index in
            index == 0 ? "This meeting is about many things." : #"{"segments":[]}"#
        })
        let result = await Self.correct([Self.segment("we ned it")], with: llm)
        #expect(result.outcome == .degraded)
        #expect(result.reason == .topicAnalysisFailed)
    }

    @Test func failingBatchesOutrankAFailedCritique() async {
        let llm = ScriptedLLMProvider(chat: { _, _ in throw ProviderDown() })
        let result = await Self.correct([Self.segment("we ned it")], with: llm)
        #expect(result.outcome == .failed)
        #expect(result.reason == .engineFailed)
    }

    @Test func anEmptyTranscriptIsNeverSentToTheCritic() async {
        let llm = ScriptedLLMProvider()
        let profile = await TranscriptTopicAnalyzer().analyze(
            segments: [Self.segment("   ")], meetingTerms: [], language: .english, llm: llm
        )
        #expect(profile == nil)
        #expect(llm.chatCalls.isEmpty)
    }

    @Test func theCriticSeesTheMeetingsOwnTerms() {
        let prompt = TranscriptTopicAnalyzer.userPrompt(excerpt: "hello", meetingTerms: ["Ana", "KPI"])
        #expect(prompt.contains("Ana, KPI"))
        #expect(TranscriptTopicAnalyzer.userPrompt(excerpt: "hello", meetingTerms: []).contains("(none)"))
    }
}
