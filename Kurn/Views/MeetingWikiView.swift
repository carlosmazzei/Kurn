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

    private var item: ReadAloudItem { .wiki(article) }
    private var controller: ReadAloudController { .shared }

    var body: some View {
        ScrollView {
            MeetingWikiContent(article: article)
                .padding(20)
        }
        .background(Theme.readingBackground.ignoresSafeArea())
        // The same floating bar the Summary tab shows, so playback keeps its
        // chrome after the sheet is up — including an idle-with-error state.
        .safeAreaInset(edge: .bottom) {
            if controller.phase(for: item.id) != .idle
                || controller.error(for: item.id) != nil {
                ReadAloudBar(
                    item: item,
                    title: NSLocalizedString("detail.read_aloud.wiki_title", comment: "Reading the wiki")
                )
            }
        }
        .navigationTitle(NSLocalizedString("detail.wiki.title", comment: "Meeting wiki title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
        .onDisappear { controller.stop(owner: item.ownerID) }
    }
}

/// The same article content works inline and in the existing sheet shortcut.
struct MeetingWikiContent: View {
    let article: WikiArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
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
                Spacer(minLength: 0)
                ReadAloudListenButton(item: .wiki(article))
            }

            MarkdownText(article.bodyMarkdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
