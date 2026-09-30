//
//  TranscriptionCoordinator+Speakers.swift
//  Kurn
//
//  Speaker reconciliation after a transcript is saved, split out of
//  TranscriptionCoordinator.swift: it is the largest single piece of the
//  coordinator and depends on nothing else in it but the model context and
//  the cross-meeting match staging.
//

import Foundation
import KurnCore
import SwiftData
import SwiftUI // for Color.speakerHex palette helper

extension TranscriptionCoordinator {

    /// Reconcile the meeting's `Speaker` rows with the labels present across all
    /// its recordings' current transcripts, keeping each row attached to the
    /// person it belongs to rather than to the label it happened to have.
    ///
    /// The label is not an identity. The diarizer hands out `"Speaker N"` in
    /// order of first appearance, freshly on every run — **independently per
    /// recording** — so a re-transcription routinely renames the same voice,
    /// and two different recordings' own "Speaker 1" are two different people
    /// unless a voice says otherwise. This method used to key rows on the
    /// label string in the only two ways available, both wrong: deleting a row
    /// whose label stopped appearing threw away the name the user typed, and
    /// keeping a row under its old label would hand that name to whoever the
    /// diarizer now calls Speaker 2 — or, across recordings, to a completely
    /// different person who happened to get the same number.
    ///
    /// So the reconciliation is by voice when there is one, and it runs **one
    /// recording at a time**, in `recordedAt` order: each recording's own
    /// labels are matched, via `SpeakerIdentityMatcher`, only against
    /// whichever stored rows an *earlier* recording in this same pass hasn't
    /// already claimed. `Recording.speakerVoiceprints` is what makes that
    /// possible — every recording keeps its own diarization run's voiceprints,
    /// not just the one that just finished — so a second recording's
    /// "Speaker 1" is judged on its own voice instead of being merged, by
    /// label string alone, into whatever "Speaker 1" the first recording
    /// already produced.
    ///
    /// Where no voiceprint exists (the heuristic engine, or a transcript from
    /// before this existed) identity genuinely cannot be recovered, and guessing
    /// would be the error the matching exists to prevent. There the rule is only
    /// the conservative half: a row the user has named is never deleted, and a
    /// label already claimed within this pass is never handed to a second,
    /// different recording's same-numbered speaker.
    ///
    /// Internal rather than private so the behaviour that used to lose a typed
    /// name — or attach it to the wrong person — can be pinned by a test
    /// against a real `ModelContainer`.
    func syncSpeakers(for meeting: Meeting?) {
        guard let meeting else { return }

        // Snapshot the rows before anything moves: the matching is keyed on
        // what each row was called going in, and rows are relabelled below.
        let rows = meeting.speakers.map { (speaker: $0, original: $0.label) }

        var assignment: [String: Speaker] = [:]
        var claimedLabels: Set<String> = []
        var placed: Set<ObjectIdentifier> = []
        func isPlaced(_ speaker: Speaker) -> Bool { placed.contains(ObjectIdentifier(speaker)) }

        // A label already claimed within this pass gets a fresh one instead of
        // colliding — the only way two different recordings' independently
        // numbered "Speaker 1"s can both survive as distinct rows.
        func canonicalLabel(preferring raw: String) -> String {
            guard claimedLabels.contains(raw) else { return raw }
            var index = 1
            while claimedLabels.contains("Speaker \(index)") { index += 1 }
            return "Speaker \(index)"
        }

        func place(_ speaker: Speaker, rawLabel: String, canonical: String, voiceprints: [String: [Float]]) {
            assignment[canonical] = speaker
            claimedLabels.insert(canonical)
            placed.insert(ObjectIdentifier(speaker))
            // Refresh with this recording's own embedding: a speaker heard
            // again is described better by the newer one than by whichever
            // was stored first.
            if let vector = voiceprints[rawLabel] {
                speaker.voiceprintData = VectorData.encode(vector)
            }
        }

        var byVoiceCount = 0
        var unclaimed: [(label: String, voiceprint: [Float]?)] = []

        for recording in meeting.recordings.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            guard let segments = recording.transcript?.segments, !segments.isEmpty else { continue }

            // This recording's own labels, in first-appearance order — not
            // merged with any other recording's, since the diarizer numbers
            // them independently per run.
            var recordingLabels: [String] = []
            for segment in segments where !recordingLabels.contains(segment.speakerLabel) {
                recordingLabels.append(segment.speakerLabel)
            }
            let recordingVoiceprints = recording.speakerVoiceprints

            // Which row is which person, by voice — over *every* row with a
            // voiceprint, placed or not. A row an earlier recording in this
            // pass already placed can still be recognized by a later
            // recording's own run: that's what lets the same voice be
            // reunified across recordings regardless of which number each
            // one's diarizer gave it. Run over every label this recording
            // produced, not only the ones that appear or disappear: the
            // common case is the label set staying the same while the
            // assignment permutes, and matching only the leftovers would
            // miss exactly that.
            let matches = SpeakerIdentityMatcher.match(
                existing: rows.compactMap { row -> SpeakerIdentityMatcher.Candidate? in
                    guard let voiceprint = row.speaker.voiceprint else { return nil }
                    return SpeakerIdentityMatcher.Candidate(label: row.original, voiceprint: voiceprint)
                },
                incoming: recordingLabels.compactMap { label -> SpeakerIdentityMatcher.Candidate? in
                    guard let voiceprint = recordingVoiceprints[label] else { return nil }
                    return SpeakerIdentityMatcher.Candidate(label: label, voiceprint: voiceprint)
                }
            )
            byVoiceCount += matches.count

            // This recording's own raw labels that found a person this pass —
            // by voice below, or by the label fallback after it — so the
            // "nobody claimed this" step at the end only sees genuine leftovers.
            var consumed: Set<String> = []

            // 1. Voice wins. It is the only evidence here that identifies a
            // person. A fresh match places the row under a (collision-free)
            // canonical label; a match onto a row already placed this pass is
            // just a reconfirmation — same person, refresh the voiceprint,
            // don't relabel or duplicate.
            for row in rows {
                guard let raw = matches[row.original] else { continue }
                consumed.insert(raw)
                if isPlaced(row.speaker) {
                    if let vector = recordingVoiceprints[raw] {
                        row.speaker.voiceprintData = VectorData.encode(vector)
                    }
                    continue
                }
                let canonical = canonicalLabel(preferring: raw)
                place(row.speaker, rawLabel: raw, canonical: canonical, voiceprints: recordingVoiceprints)
                if canonical != row.original {
                    AppLog.transcription.atNotice.notice("VM: syncSpeakers \(row.original, privacy: .public) -> \(canonical, privacy: .public) by voice")
                }
            }
            // 2. Then the label, for rows no voiceprint could speak for — the
            // old behaviour, and still right when nothing has been renumbered.
            // Scoped to *this* recording's own, still-unconsumed labels, so a
            // later recording can never steal a row an earlier one already
            // claimed just because the diarizer handed out the same number
            // again.
            for row in rows where !isPlaced(row.speaker) {
                guard recordingLabels.contains(row.original),
                      !consumed.contains(row.original),
                      !claimedLabels.contains(row.original) else { continue }
                place(row.speaker, rawLabel: row.original, canonical: row.original, voiceprints: recordingVoiceprints)
                consumed.insert(row.original)
            }

            // Whatever this recording produced that no row claimed becomes a
            // new row below — never merged, by raw label string, into another
            // recording's leftover of the same name.
            for label in recordingLabels where !consumed.contains(label) {
                unclaimed.append((label, recordingVoiceprints[label]))
            }
        }

        for (label, speaker) in assignment {
            speaker.label = label
        }

        // 3. Rows with nowhere to go. An unnamed one holds nothing but a label
        // that no longer means anything; a named one holds what the user typed,
        // and losing that silently is the failure this method exists to prevent.
        var keptNamed = 0
        var removed = 0
        for row in rows where !isPlaced(row.speaker) {
            guard row.speaker.name.isEmpty else {
                keptNamed += 1
                continue
            }
            modelContext.delete(row.speaker)
            removed += 1
        }

        // 4. Rows for labels nobody claimed. The color index counts the rows
        // that will actually remain — deletes above aren't applied until save,
        // so `meeting.speakers` can't be counted for this. A brand-new row is
        // also checked against every *other* meeting's named speakers here
        // (D6, see TranscriptionCoordinator+CrossMeetingSpeakerMatch.swift);
        // `crossMeetingCandidates` is fetched once, not per entry.
        let crossMeetingCandidates = unclaimed.contains { $0.voiceprint != nil }
            ? crossMeetingSpeakerCandidates(excluding: meeting)
            : []
        var index = assignment.count
        var addedLabels: [String] = []
        for entry in unclaimed {
            let canonical = canonicalLabel(preferring: entry.label)
            // Setting `meeting` establishes the relationship; SwiftData maintains
            // the inverse `meeting.speakers`.
            let speaker = Speaker(
                meeting: meeting,
                label: canonical,
                color: Color.speakerHex(for: index),
                voiceprintData: entry.voiceprint.map(VectorData.encode)
            )
            modelContext.insert(speaker)
            claimedLabels.insert(canonical)
            addedLabels.append(canonical)
            index += 1
            stageCrossMeetingMatchIfPossible(for: speaker, voiceprint: entry.voiceprint, among: crossMeetingCandidates)
        }

        // Final state the UI (filter chips + speaker list) will render, plus the
        // delta, so a "UI shows 1 speaker" report can be traced to the exact stage:
        // if `final` here is >1 the data layer is correct and any UI mismatch is a
        // view-refresh problem; if it's 1, the collapse happened upstream (see the
        // diarizer's `turnSpeakers`/`speakers` log lines).
        let finalLabels = claimedLabels.sorted()
        AppLog.transcription.atNotice.notice("VM: syncSpeakers final=\(finalLabels.count, privacy: .public) [\(finalLabels.joined(separator: ", "), privacy: .public)] added=\(addedLabels.count, privacy: .public) removed=\(removed, privacy: .public) byVoice=\(byVoiceCount, privacy: .public) keptNamed=\(keptNamed, privacy: .public)")
    }
}
