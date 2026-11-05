//
//  MeetingTopicProfile.swift
//  KurnCore
//
//  What the correction stage (`LLMTranscriptCorrector`) learns about a meeting
//  before correcting it: the subject, the domain, the
//  vocabulary that domain uses, and the mishearings an ASR engine is likely to
//  have produced for it. `MeetingVocabularyExtractor` can only recover a term
//  the ASR got right *somewhere* in the same recording; a profile inferred from
//  the meeting's content can also name a term the ASR got wrong every time
//  ("cuber netes" in a Kubernetes migration), which is the case the frequency
//  list structurally cannot reach.
//
//  Everything here is pure and model-free: the LLM call lives in the app
//  (`TranscriptTopicAnalyzer`), this file parses, bounds and grounds its reply.
//

import Foundation

public struct MeetingTopicProfile: Sendable, Equatable {
    /// A form the ASR probably produced, paired with the term the speaker
    /// probably said.
    public struct Mishearing: Sendable, Equatable {
        public var heard: String
        public var intended: String

        public init(heard: String, intended: String) {
            self.heard = heard
            self.intended = intended
        }
    }

    /// One sentence describing what the meeting is about.
    public var topic: String
    /// The field the meeting belongs to ("software engineering",
    /// "cardiology"), which decides how ambiguous words should be read.
    public var domain: String
    /// Names, jargon, acronyms and product terms the domain and topic make
    /// likely, spelled as they should be written.
    public var keyTerms: [String]
    public var mishearings: [Mishearing]

    public static let maxTopicLength = 240
    public static let maxDomainLength = 80
    public static let maxTermLength = 60
    public static let maxKeyTerms = 40
    public static let maxMishearings = 20

    public init(topic: String, domain: String, keyTerms: [String], mishearings: [Mishearing]) {
        self.topic = topic
        self.domain = domain
        self.keyTerms = keyTerms
        self.mishearings = mishearings
    }

    /// Whether the profile carries nothing a correction prompt could use.
    public var isEmpty: Bool {
        topic.isEmpty && domain.isEmpty && keyTerms.isEmpty && mishearings.isEmpty
    }

    private struct ReplyJSON: Decodable {
        struct MishearingJSON: Decodable {
            let heard: String?
            let intended: String?
        }
        let topic: String?
        let domain: String?
        let keyTerms: [String]?
        let likelyMishearings: [MishearingJSON]?

        enum CodingKeys: String, CodingKey {
            case topic, domain
            case keyTerms = "key_terms"
            case likelyMishearings = "likely_mishearings"
        }
    }

    /// Parses a topic-analysis reply, tolerating fences and prose around the
    /// JSON (`ModelJSON`), and bounds every field: an over-long string is
    /// dropped rather than cut (a truncated term is a wrong term), lists are
    /// deduplicated case-insensitively and capped, and a mishearing that maps
    /// a form onto itself is discarded. `nil` when the reply is not JSON or
    /// carries nothing usable, so the caller can tell a failed analysis from
    /// a meeting with no special vocabulary.
    public static func parse(_ reply: String) -> MeetingTopicProfile? {
        guard let data = try? ModelJSON.objectData(from: reply),
              let decoded = try? JSONDecoder().decode(ReplyJSON.self, from: data) else {
            return nil
        }
        var seenMishearings = Set<String>()
        let mishearings = (decoded.likelyMishearings ?? []).compactMap { item -> Mishearing? in
            guard let heard = bounded(item.heard, maxLength: maxTermLength),
                  let intended = bounded(item.intended, maxLength: maxTermLength),
                  heard.lowercased() != intended.lowercased(),
                  seenMishearings.insert(heard.lowercased()).inserted else {
                return nil
            }
            return Mishearing(heard: heard, intended: intended)
        }
        let profile = MeetingTopicProfile(
            topic: bounded(decoded.topic, maxLength: maxTopicLength) ?? "",
            domain: bounded(decoded.domain, maxLength: maxDomainLength) ?? "",
            keyTerms: Array(deduplicated((decoded.keyTerms ?? []).compactMap { bounded($0, maxLength: maxTermLength) })
                .prefix(maxKeyTerms)),
            mishearings: Array(mishearings.prefix(maxMishearings))
        )
        return profile.isEmpty ? nil : profile
    }

    /// The profile with every mishearing whose `heard` form never occurs in
    /// `segments` removed. A mishearing is a claim about *this* transcript, so
    /// one that cannot be found in it is invented, and sending it would only
    /// invite the corrector to apply it somewhere it does not belong. Key terms
    /// are kept: they are the intended spellings, which by definition may not
    /// appear yet.
    public func grounded(in segments: [TranscriptSegment]) -> MeetingTopicProfile {
        let haystack = segments.map { $0.text.lowercased() }.joined(separator: "\n")
        var copy = self
        copy.mishearings = mishearings.filter { haystack.contains($0.heard.lowercased()) }
        return copy
    }

    private static func bounded(_ value: String?, maxLength: Int) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= maxLength else {
            return nil
        }
        return trimmed
    }

    static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

/// The text a topic analysis reads. Sending a two-hour transcript to infer one
/// sentence of topic would cost more than the correction it serves, so a long
/// meeting is sampled: whole segments from its start, middle and end, which is
/// where an agenda, the discussion and the wrap-up usually sit.
public enum TopicAnalysisExcerpt {
    public static let defaultMaxCharacters = 8_000
    static let gapMarker = "…"

    /// Pure and deterministic. Never splits a segment; skips empty ones.
    public static func build(from segments: [TranscriptSegment], maxCharacters: Int = defaultMaxCharacters) -> String {
        let texts = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let total = texts.reduce(0) { $0 + $1.count + 1 }
        guard total > maxCharacters, texts.count > 3 else {
            return texts.joined(separator: "\n")
        }

        let window = max(1, maxCharacters / 3)
        let starts = [0, texts.count / 2, texts.count]
        var windows: [[String]] = []
        var used = Set<Int>()
        for (position, anchor) in starts.enumerated() {
            let indices = position == 2
                ? Array((0..<texts.count).reversed())
                : Array(anchor..<texts.count)
            var picked: [Int] = []
            var size = 0
            for index in indices where !used.contains(index) {
                let length = texts[index].count + 1
                if !picked.isEmpty && size + length > window { break }
                picked.append(index)
                size += length
            }
            used.formUnion(picked)
            windows.append(picked.sorted().map { texts[$0] })
        }
        return windows
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\(gapMarker)\n")
    }
}

/// The vocabulary hint a correction batch is sent.
public enum CorrectionVocabulary {
    public static let maxTerms = 60

    /// The meeting's own recurring terms first — they are evidence from this
    /// recording — then the inferred domain terms it did not already contain,
    /// deduplicated case-insensitively and capped.
    public static func merge(meetingTerms: [String], profile: MeetingTopicProfile?) -> [String] {
        let combined = meetingTerms + (profile?.keyTerms ?? [])
        return Array(MeetingTopicProfile.deduplicated(combined).prefix(maxTerms))
    }
}
