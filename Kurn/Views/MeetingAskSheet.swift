//
//  MeetingAskSheet.swift
//  Kurn
//
//  The floating "Ask" bar shown on every meeting detail tab and the sheet it
//  opens: `MeetingChatView` in a navigation stack, shared by the per-meeting
//  scope (`meeting` non-nil) and the library-wide Ask (`meeting` nil) so both
//  read identically.
//

import SwiftData
import SwiftUI

/// Floating capsule at the bottom of every detail tab — one button that
/// opens `MeetingAskSheet`.
struct MeetingAskBar: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(NSLocalizedString("detail.ask.placeholder", comment: "Ask about this meeting"))
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onInk)
                    .frame(width: 38, height: 38)
                    .background(Theme.ink, in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background {
                if reduceTransparency {
                    Capsule()
                        .fill(Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                } else {
                    Color.clear
                        .glassEffect(in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.ask")
        .accessibilityLabel(NSLocalizedString("detail.ask.placeholder", comment: "Ask about this meeting"))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}

/// The Ask sheet shared by the meeting detail and the meetings list.
struct MeetingAskSheet: View {
    /// The meeting to ask about; `nil` asks across the whole library.
    let meeting: Meeting?
    /// Per-meeting scope only: taps a cited `[m:ss]` to seek the transcript.
    var onJumpToTime: ((TimeInterval) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(subtitle)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                MeetingChatView(meeting: meeting) { time in
                    dismiss()
                    onJumpToTime?(time)
                }
            }
            .navigationTitle(NSLocalizedString("chat.ask.title", comment: "Ask"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
        .hostsRecordingMiniBarInSheet()
    }

    private var subtitle: String {
        if let meeting {
            let key = settings.knowledgeEnabled && settings.wikiEnabled
                ? "chat.ask.subtitle.meeting"
                : "chat.ask.subtitle.meeting.no_wiki"
            return String(format: NSLocalizedString(key, comment: "Ask subtitle"), meeting.title)
        }
        return String(format: NSLocalizedString("chat.ask.subtitle.library", comment: "Ask subtitle"),
                      meetings.count)
    }
}
