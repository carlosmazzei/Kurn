//
//  CrossMeetingSpeakerMatchView.swift
//  Kurn
//
//  Sheet offering a voiceprint match found in a different meeting, for a
//  speaker just created in this one. Confirming copies the name; dismissing
//  leaves the new row exactly as it was — unnamed, still renameable by hand.
//  Never applies the match itself; see `TranscriptionViewModel.applyCrossMeetingMatch`.
//

import SwiftUI

struct CrossMeetingSpeakerMatchView: View {
    @Environment(\.dismiss) private var dismiss

    let match: TranscriptionViewModel.CrossMeetingSpeakerMatch
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Circle()
                    .fill(Color(hex: match.matchedSpeaker.color))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.white)
                            .accessibilityHidden(true)
                    }

                Text(
                    String(
                        format: NSLocalizedString(
                            "speaker.cross_meeting_match.message",
                            comment: "This sounds like %@ from \"%@\". Apply the name?"
                        ),
                        match.matchedSpeaker.name,
                        match.matchedMeetingTitle
                    )
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)

                Text(NSLocalizedString("speaker.cross_meeting_match.disclaimer", comment: "Voice match disclaimer"))
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)

                Spacer()

                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "speaker.cross_meeting_match.confirm",
                                comment: "Yes, it's %@"
                            ),
                            match.matchedSpeaker.name
                        )
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)

                Button {
                    dismiss()
                } label: {
                    Text(NSLocalizedString("speaker.cross_meeting_match.dismiss", comment: "Not now"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .padding(24)
            .navigationTitle(NSLocalizedString("speaker.cross_meeting_match.title", comment: "Familiar voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
