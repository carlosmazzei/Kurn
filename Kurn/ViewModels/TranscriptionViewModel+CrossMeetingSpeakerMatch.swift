//
//  TranscriptionViewModel+CrossMeetingSpeakerMatch.swift
//  Kurn
//
//  D6: a person who attends every week used to get an unrelated, freshly
//  named `Speaker` row in every meeting, because `Speaker.voiceprintData` was
//  only ever compared *within* one meeting. This extension is what checks a
//  brand-new row's voice against every other meeting's named speakers — and,
//  same rule as the rest of speaker identity, only ever *offers* the match.
//  Split out of TranscriptionViewModel.swift to keep that file under
//  SwiftLint's file-length limit, the same reason MeetingDetailAutoTagging.swift
//  is a separate file from MeetingDetailView.swift.
//

import Foundation
import SwiftData

extension TranscriptionViewModel {

    /// A candidate identity for a freshly created `Speaker` row, suggested
    /// from a voiceprint match found in a *different* meeting. Staged on
    /// `pendingCrossMeetingMatches` rather than applied, so a misidentified
    /// voice never silently attaches the wrong name to the wrong person —
    /// the view presents it as a confirm sheet (`CrossMeetingSpeakerMatchView`),
    /// and `applyCrossMeetingMatch`/`dismissCrossMeetingMatch` below are the
    /// only ways an entry leaves the list.
    struct CrossMeetingSpeakerMatch: Identifiable {
        let id = UUID()
        let newSpeaker: Speaker
        let matchedSpeaker: Speaker
        let matchedMeetingTitle: String
    }

    /// Every other meeting's named, voiceprinted speakers — the candidate
    /// pool a brand-new row's voice can be checked against. Unfiltered fetch
    /// then filter in Swift, same shape as `SemanticIndexCoordinator`'s
    /// store-wide sweeps; `Speaker` rows carry no transcript text, so this is
    /// cheap even across a large library. Only named rows are candidates —
    /// offering "this might be Speaker 3 from another meeting" would suggest
    /// a label, not an identity.
    func crossMeetingSpeakerCandidates(excluding meeting: Meeting) -> [(value: Speaker, voiceprint: [Float])] {
        let allSpeakers = (try? modelContext.fetch(FetchDescriptor<Speaker>())) ?? []
        return allSpeakers.compactMap { candidate -> (value: Speaker, voiceprint: [Float])? in
            guard !candidate.name.isEmpty,
                  candidate.meeting?.id != meeting.id,
                  let voiceprint = candidate.voiceprint else { return nil }
            return (candidate, voiceprint)
        }
    }

    /// Checks one freshly created row's voiceprint against `candidates` and,
    /// on a close-enough match, stages a suggestion. Never sets `.name`
    /// itself — `applyCrossMeetingMatch` is the only path that does.
    func stageCrossMeetingMatchIfPossible(
        for speaker: Speaker,
        voiceprint: [Float]?,
        among candidates: [(value: Speaker, voiceprint: [Float])]
    ) {
        guard let voiceprint,
              let matched = SpeakerIdentityMatcher.closestMatch(to: voiceprint, among: candidates) else { return }
        pendingCrossMeetingMatches.append(
            CrossMeetingSpeakerMatch(
                newSpeaker: speaker,
                matchedSpeaker: matched,
                matchedMeetingTitle: matched.meeting?.title ?? ""
            )
        )
    }

    /// Confirms a suggested cross-meeting identity: the only place
    /// `pendingCrossMeetingMatches` ever causes a `.name` to be set.
    func applyCrossMeetingMatch(_ match: CrossMeetingSpeakerMatch) {
        match.newSpeaker.name = match.matchedSpeaker.name
        persist()
        pendingCrossMeetingMatches.removeAll { $0.id == match.id }
    }

    /// Declines a suggested cross-meeting identity. The new row is left
    /// exactly as it already was — unnamed, still renameable by hand — so
    /// declining costs nothing beyond not confirming.
    func dismissCrossMeetingMatch(_ match: CrossMeetingSpeakerMatch) {
        pendingCrossMeetingMatches.removeAll { $0.id == match.id }
    }
}
