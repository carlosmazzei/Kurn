//
//  MeetingDetailToolbar.swift
//  Kurn
//
//  MeetingDetailView's toolbar content, split out of that file to keep it
//  under SwiftLint's file-length limit — the same reason
//  Views/MeetingsListToolbar.swift lives in its own file.
//

import SwiftUI

extension MeetingDetailView {
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                meeting.isFavorite.toggle()
                if let failure = modelContext.saveOrError() { txVM?.error = failure }
            } label: {
                Image(systemName: meeting.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(meeting.isFavorite ? Theme.warning : Theme.textSecondary)
            }
            .accessibilityLabel(
                meeting.isFavorite
                    ? NSLocalizedString("meetings.unfavorite", comment: "Unfavorite")
                    : NSLocalizedString("meetings.favorite", comment: "Favorite")
            )
        }
        // Keeps the favorite toggle in a glass group of its own, separate from
        // the overflow menu.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingEdit = true } label: {
                    Label(NSLocalizedString("common.edit", comment: "Edit"), systemImage: "pencil")
                }
                Button { showingShareSelection = true } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("detail.share")
                if canGenerateTitle {
                    Button { regenerateTitle() } label: {
                        if isGeneratingTitle {
                            Label(NSLocalizedString("detail.title.generating", comment: "Generating title"), systemImage: "ellipsis")
                        } else if meeting.aiTitle != nil {
                            Label(NSLocalizedString("detail.title.regenerate", comment: "Regenerate title"), systemImage: "arrow.clockwise")
                        } else {
                            Label(NSLocalizedString("detail.title.generate", comment: "Generate title"), systemImage: "text.quote")
                        }
                    }
                    .disabled(isGeneratingTitle)
                }
                if meeting.wikiArticle != nil {
                    Button { showingWiki = true } label: {
                        Label(
                            NSLocalizedString("detail.wiki.view", comment: "View meeting wiki"),
                            systemImage: "book.pages"
                        )
                    }
                }
                if canGenerateWiki {
                    Button { regenerateWiki() } label: {
                        if isGeneratingWiki {
                            Label(NSLocalizedString("detail.wiki.generating", comment: "Generating wiki"), systemImage: "ellipsis")
                        } else if meeting.wikiArticle != nil {
                            Label(NSLocalizedString("detail.wiki.regenerate", comment: "Regenerate wiki"), systemImage: "arrow.clockwise")
                        } else {
                            Label(NSLocalizedString("detail.wiki.generate", comment: "Generate wiki"), systemImage: "book.pages")
                        }
                    }
                    .disabled(isGeneratingWiki)
                }
                Button {
                    meeting.archivedAt = meeting.isArchived ? nil : Date()
                    if let failure = modelContext.saveOrError() { txVM?.error = failure }
                } label: {
                    Label(
                        meeting.isArchived
                            ? NSLocalizedString("meetings.unarchive", comment: "Unarchive")
                            : NSLocalizedString("meetings.archive", comment: "Archive"),
                        systemImage: meeting.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
                if hasAnyTranscript {
                    Button { pendingRetranscribeAll = true } label: {
                        Label(NSLocalizedString("detail.retranscribe_all", comment: "Re-transcribe all"), systemImage: "arrow.clockwise")
                    }
                }
                if settings.autoTaggingEnabled {
                    Button { suggestTags() } label: {
                        if isAutoTagging {
                            Label(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"), systemImage: "ellipsis")
                        } else {
                            Label(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"), systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isAutoTagging)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(NSLocalizedString("detail.more_options", comment: "More options"))
            .accessibilityIdentifier("detail.more")
        }
    }
}
