//
//  MeetingWikiView.swift
//  Kurn
//
//  Read-only presentation of the condensed article generated for one meeting.
//  Generation and lifecycle remain owned by `WikiCoordinator`; this view only
//  makes the already-persisted article visible from the meeting detail screen.
//

import SwiftUI

struct MeetingWikiView: View {
    let article: WikiArticle

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label {
                    Text(
                        String(
                            format: NSLocalizedString("detail.wiki.updated", comment: "Wiki last updated date"),
                            article.updatedAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    )
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

                MarkdownText(article.bodyMarkdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(NSLocalizedString("detail.wiki.title", comment: "Meeting wiki title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
    }
}
