//
//  MeetingDetailCrossMeetingSpeakerMatch.swift
//  Kurn
//
//  Presents D6's cross-meeting voiceprint suggestion (see
//  TranscriptionViewModel+CrossMeetingSpeakerMatch.swift) for whichever new
//  speaker, if any, belongs to *this* meeting. Split out of MeetingDetailView.swift
//  to keep that file under SwiftLint's file-length limit, the same reason
//  MeetingDetailAutoTagging.swift exists.
//

import SwiftUI

extension MeetingDetailView {

    /// Scoped to this meeting: a suggestion for a *different* meeting's new
    /// speaker just waits in `pendingCrossMeetingMatches` until that meeting's
    /// own detail view is opened, rather than interrupting whatever the user
    /// is looking at right now.
    var crossMeetingMatchBinding: Binding<TranscriptionViewModel.CrossMeetingSpeakerMatch?> {
        Binding(
            get: { txVM?.pendingCrossMeetingMatches.first { $0.newSpeaker.meeting?.id == meeting.id } },
            set: { newValue in
                guard newValue == nil,
                      let match = txVM?.pendingCrossMeetingMatches.first(where: { $0.newSpeaker.meeting?.id == meeting.id })
                else { return }
                // Reached on dismissal (swipe-down or the sheet's own cancel
                // button) as well as after a confirmed apply — both already
                // remove the entry, so this only ever fires for a decline.
                txVM?.dismissCrossMeetingMatch(match)
            }
        )
    }

    @ViewBuilder
    func crossMeetingMatchSheetContent(_ match: TranscriptionViewModel.CrossMeetingSpeakerMatch) -> some View {
        CrossMeetingSpeakerMatchView(match: match) {
            txVM?.applyCrossMeetingMatch(match)
        }
    }
}
