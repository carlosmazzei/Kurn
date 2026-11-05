//
//  MeetingTopicProfileTests.swift
//  KurnCoreTests
//

import Foundation
import Testing
@testable import KurnCore

struct MeetingTopicProfileTests {

    private func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 1, text: text, confidence: nil)
    }

    // MARK: - Parsing

    @Test func parsesAFencedReply() throws {
        let reply = """
        Here is the profile:
        ```json
        {"topic":"Migrating the billing service to Kubernetes","domain":"software engineering",
         "key_terms":["Kubernetes","Helm","PostgreSQL"],
         "likely_mishearings":[{"heard":"cuber netes","intended":"Kubernetes"}]}
        ```
        """
        let profile = try #require(MeetingTopicProfile.parse(reply))
        #expect(profile.topic == "Migrating the billing service to Kubernetes")
        #expect(profile.domain == "software engineering")
        #expect(profile.keyTerms == ["Kubernetes", "Helm", "PostgreSQL"])
        #expect(profile.mishearings == [.init(heard: "cuber netes", intended: "Kubernetes")])
    }

    @Test func proseOrAnEmptyObjectIsNoProfile() {
        #expect(MeetingTopicProfile.parse("I could not tell what this meeting was about.") == nil)
        #expect(MeetingTopicProfile.parse(#"{"topic":"  ","key_terms":[]}"#) == nil)
    }

    @Test func fieldsAreTrimmedDeduplicatedAndBounded() throws {
        let tooLong = String(repeating: "x", count: MeetingTopicProfile.maxTermLength + 1)
        let terms = (0..<(MeetingTopicProfile.maxKeyTerms + 10)).map { "term\($0)" }
        let quoted = (["  Helm ", "helm", tooLong, ""] + terms).map { "\"\($0)\"" }.joined(separator: ",")
        let reply = #"{"topic":"t","domain":"d","key_terms":[\#(quoted)],"likely_mishearings":["#
            + #"{"heard":"same","intended":"SAME"},"#
            + #"{"heard":"hell","intended":"Helm"},{"heard":"Hell","intended":"Help"},"#
            + #"{"heard":"x"}]}"#
        let profile = try #require(MeetingTopicProfile.parse(reply))
        #expect(profile.keyTerms.first == "Helm")
        #expect(!profile.keyTerms.contains("helm"))
        #expect(!profile.keyTerms.contains(tooLong))
        #expect(profile.keyTerms.count == MeetingTopicProfile.maxKeyTerms)
        #expect(profile.mishearings == [.init(heard: "hell", intended: "Helm")])
    }

    @Test func anOverlongTopicIsDroppedNotCut() throws {
        let topic = String(repeating: "a", count: MeetingTopicProfile.maxTopicLength + 1)
        let profile = try #require(MeetingTopicProfile.parse(#"{"topic":"\#(topic)","key_terms":["Helm"]}"#))
        #expect(profile.topic.isEmpty)
        #expect(profile.keyTerms == ["Helm"])
    }

    // MARK: - Grounding

    @Test func groundingDropsMishearingsTheTranscriptDoesNotContain() {
        let profile = MeetingTopicProfile(
            topic: "t", domain: "d", keyTerms: ["Kubernetes"],
            mishearings: [
                .init(heard: "cuber netes", intended: "Kubernetes"),
                .init(heard: "post gress", intended: "Postgres")
            ]
        )
        let grounded = profile.grounded(in: [segment("we move it to Cuber Netes next week")])
        #expect(grounded.mishearings.map(\.intended) == ["Kubernetes"])
        #expect(grounded.keyTerms == ["Kubernetes"])
    }

    // MARK: - Excerpt

    @Test func aShortTranscriptIsSentWhole() {
        let segments = [segment("one"), segment(" "), segment("two")]
        #expect(TopicAnalysisExcerpt.build(from: segments) == "one\ntwo")
    }

    @Test func aLongTranscriptIsSampledFromStartMiddleAndEnd() {
        let segments = (0..<300).map { segment("segment number \($0) " + String(repeating: "w", count: 40)) }
        let excerpt = TopicAnalysisExcerpt.build(from: segments, maxCharacters: 3_000)

        #expect(excerpt.count <= 3_000 + 10)
        #expect(excerpt.hasPrefix("segment number 0 "))
        #expect(excerpt.contains("segment number 150 "))
        #expect(excerpt.contains("segment number 299 "))
        #expect(excerpt.components(separatedBy: "\n…\n").count == 3)
        #expect(TopicAnalysisExcerpt.build(from: segments, maxCharacters: 3_000) == excerpt)
    }

    @Test func aSingleHugeSegmentIsStillSent() {
        let segments = (0..<4).map { segment(String(repeating: "\($0)", count: 500)) }
        let excerpt = TopicAnalysisExcerpt.build(from: segments, maxCharacters: 90)
        #expect(!excerpt.isEmpty)
        #expect(excerpt.hasPrefix("000"))
        #expect(excerpt.hasSuffix("333"))
    }

    // MARK: - Vocabulary merge

    @Test func meetingTermsComeFirstAndDuplicatesAreDropped() {
        let profile = MeetingTopicProfile(topic: "", domain: "", keyTerms: ["helm", "Kubernetes"], mishearings: [])
        #expect(CorrectionVocabulary.merge(meetingTerms: ["Helm", "Ana"], profile: profile) == ["Helm", "Ana", "Kubernetes"])
        #expect(CorrectionVocabulary.merge(meetingTerms: ["Ana"], profile: nil) == ["Ana"])
    }

    @Test func theMergedListIsCapped() {
        let profile = MeetingTopicProfile(
            topic: "", domain: "", keyTerms: (0..<50).map { "k\($0)" }, mishearings: []
        )
        let merged = CorrectionVocabulary.merge(meetingTerms: (0..<40).map { "m\($0)" }, profile: profile)
        #expect(merged.count == CorrectionVocabulary.maxTerms)
        #expect(merged.first == "m0")
    }
}
