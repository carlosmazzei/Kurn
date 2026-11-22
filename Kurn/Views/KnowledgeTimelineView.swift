import KurnCore
import SwiftUI

/// The scoped timeline (K3.3): claims placed by the date they state, with the
/// meeting each was said in beside it and undated claims kept apart. Built from
/// the same authorized read as the rest of the reader; no store access here.
struct KnowledgeTimelineView: View {
    let read: KnowledgeBrowserRead
    @State private var filter = KnowledgeTimeline.Filter()

    private var timeline: KnowledgeTimeline { KnowledgeTimeline.build(pages: read.pages, filter: filter) }

    var body: some View {
        let timeline = timeline
        Group {
            if timeline.isEmpty {
                ContentUnavailableView {
                    Label(KnowledgeTimelinePresentation.text("empty"), systemImage: "calendar")
                } description: {
                    if !filter.isDefault { Text(KnowledgeTimelinePresentation.text("empty_filtered")) }
                } actions: {
                    if !filter.isDefault {
                        KnowledgeChipButton(title: KnowledgeTimelinePresentation.text("reset"), systemImage: "arrow.uturn.backward") {
                            filter = KnowledgeTimeline.Filter()
                        }
                        .accessibilityIdentifier("knowledge.timeline.reset")
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text(KnowledgeTimelinePresentation.text("footer"))
                            .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(timeline.periods, id: \.month.text) { period in
                            KnowledgeSectionLabel(KnowledgeTimelinePresentation.monthTitle(period.month)).padding(.top, 8)
                            entries(period.entries)
                        }
                        if !timeline.undated.isEmpty {
                            KnowledgeSectionLabel(KnowledgeTimelinePresentation.text("undated")).padding(.top, 8)
                                .accessibilityIdentifier("knowledge.timeline.undated")
                            entries(timeline.undated)
                            Text(KnowledgeTimelinePresentation.text("undated_footer"))
                                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
                }
                .accessibilityIdentifier("knowledge.timeline")
            }
        }
        .knowledgeReadingSurface()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
    }

    private var filterMenu: some View {
        Menu {
            Section {
                ForEach(KnowledgeTimeline.EntryKind.allCases, id: \.self) { kind in
                    Toggle(KnowledgeTimelinePresentation.kindName(kind), isOn: Binding(
                        get: { filter.shows(kind) }, set: { filter = filter.showing(kind, $0) }))
                }
            }
            Section {
                Toggle(KnowledgeTimelinePresentation.text("include_tentative"), isOn: $filter.includesTentative)
                Toggle(KnowledgeTimelinePresentation.text("include_negated"), isOn: $filter.includesNegated)
            }
            if !filter.isDefault {
                Button(KnowledgeTimelinePresentation.text("reset")) { filter = KnowledgeTimeline.Filter() }
            }
        } label: {
            Label(KnowledgeTimelinePresentation.text("filter"),
                  systemImage: filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("knowledge.timeline.filter")
    }

    private func entries(_ entries: [KnowledgeTimeline.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.element.factID) { index, entry in
                if index > 0 { Divider().overlay(Theme.separator).accessibilityHidden(true) }
                row(entry)
            }
        }
        .knowledgeCard()
    }

    @ViewBuilder
    private func row(_ entry: KnowledgeTimeline.Entry) -> some View {
        let row = KnowledgeTimelinePresentation.row(entry, meetingTitles: read.meetingTitles)
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: row.claim).font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
            if let stated = row.stated { Text(verbatim: stated).font(Theme.caption).foregroundStyle(Theme.textPrimary) }
            Text(verbatim: row.source).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            if !row.badges.isEmpty {
                Text(verbatim: row.badges.joined(separator: " · ")).font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let route = row.evidence {
            NavigationLink(value: route) {
                HStack(spacing: 12) {
                    content
                    KnowledgeChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.timeline.entry")
        } else {
            content.accessibilityIdentifier("knowledge.timeline.entry")
        }
    }
}
