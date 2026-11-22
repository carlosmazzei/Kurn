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
        // The nav bar shows no visible title — the content header owns the
        // meeting's title — but `navigationTitle` still names the screen for
        // the back button and VoiceOver.
        ToolbarItem(placement: .principal) {
            Text(meeting.title)
                .hidden()
                .accessibilityHidden(true)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                meeting.isFavorite.toggle()
                if let failure = modelContext.saveOrError() { actionError = failure }
            } label: {
                Image(systemName: meeting.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(meeting.isFavorite ? Theme.favorite : Theme.ink)
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
                Section {
                    Button { showingEdit = true } label: {
                        Label(NSLocalizedString("common.edit", comment: "Edit"), systemImage: "pencil")
                    }
                    Button { showingShareSelection = true } label: {
                        Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("detail.share")
                    Button { showingTagPicker = true } label: {
                        Label(NSLocalizedString("tag.title", comment: "Tags"), systemImage: "tag")
                    }
                    Button { showingFolderPicker = true } label: {
                        Label(NSLocalizedString("folder.move_to", comment: "Move to folder"), systemImage: "folder")
                    }
                }
                Section {
                    Button { generateSummary() } label: {
                        Label(NSLocalizedString("detail.summary.new", comment: "New summary"), systemImage: "sparkles")
                    }
                    if canGenerateTitle {
                        Button { regenerateTitle() } label: {
                            if isGeneratingTitle {
                                Label {
                                    Text(NSLocalizedString("detail.title.generating", comment: "Generating title"))
                                } icon: {
                                    ProgressView().controlSize(.mini)
                                }
                            } else if meeting.aiTitle != nil {
                                Label(NSLocalizedString("detail.title.regenerate", comment: "Regenerate title"), systemImage: "arrow.clockwise")
                            } else {
                                Label(NSLocalizedString("detail.title.generate", comment: "Generate title"), systemImage: "text.quote")
                            }
                        }
                        .disabled(isGeneratingTitle)
                    }
                    if settings.autoTaggingEnabled {
                        Button { suggestTags() } label: {
                            if isAutoTagging {
                                Label {
                                    Text(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"))
                                } icon: {
                                    ProgressView().controlSize(.mini)
                                }
                            } else {
                                Label(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"), systemImage: "wand.and.stars")
                            }
                        }
                        .disabled(isAutoTagging)
                    }
                    Button { attachments.requestImport() } label: {
                        Label(NSLocalizedString("detail.attachments.add", comment: "Add PDF"), systemImage: "doc.badge.plus")
                    }
                    .disabled(attachments.isImporting)
                }
                Section {
                    if !settings.knowledgeEnabled {
                        if meeting.wikiArticle != nil {
                            Button { showingWiki = true } label: {
                                Label(
                                    NSLocalizedString("detail.wiki.view", comment: "View meeting wiki"),
                                    systemImage: "book"
                                )
                            }
                        }
                        if canGenerateWiki {
                            Button { regenerateWiki() } label: {
                                if isGeneratingWiki {
                                    Label {
                                        Text(NSLocalizedString("detail.wiki.generating", comment: "Generating wiki"))
                                    } icon: {
                                        ProgressView().controlSize(.mini)
                                    }
                                } else if meeting.wikiArticle != nil {
                                    Label(NSLocalizedString("detail.wiki.regenerate", comment: "Regenerate wiki"), systemImage: "arrow.clockwise")
                                } else {
                                    Label(NSLocalizedString("detail.wiki.generate", comment: "Generate wiki"), systemImage: "book")
                                }
                            }
                            .disabled(isGeneratingWiki)
                        }
                    }
                    if hasAnyTranscript {
                        Button { pendingRetranscribeAll = true } label: {
                            Label(NSLocalizedString("detail.retranscribe_all", comment: "Re-transcribe all"), systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        meeting.archivedAt = meeting.isArchived ? nil : Date()
                        if let failure = modelContext.saveOrError() { actionError = failure }
                    } label: {
                        Label(
                            meeting.isArchived
                                ? NSLocalizedString("meetings.unarchive", comment: "Unarchive")
                                : NSLocalizedString("meetings.archive", comment: "Archive"),
                            systemImage: meeting.isArchived ? "tray.and.arrow.up" : "archivebox"
                        )
                    }
                    Button(role: .destructive) {
                        pendingDeleteMeeting = true
                    } label: {
                        Label(NSLocalizedString("meetings.delete", comment: "Delete meeting"), systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .tint(Theme.ink)
            .accessibilityLabel(NSLocalizedString("detail.more_options", comment: "Meeting actions"))
            .accessibilityInputLabels([
                NSLocalizedString("detail.more_options", comment: "Meeting actions"),
                NSLocalizedString("detail.more", comment: "More")
            ])
            .accessibilityIdentifier("detail.more")
        }
    }
}
