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
                        Button(KnowledgeTimelinePresentation.text("reset")) { filter = KnowledgeTimeline.Filter() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("knowledge.timeline.reset")
                    }
                }
            } else {
                List {
                    Section {
                        Text(KnowledgeTimelinePresentation.text("footer")).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(timeline.periods, id: \.month.text) { period in
                        Section {
                            ForEach(period.entries, id: \.factID) { row($0) }
                        } header: {
                            Text(verbatim: KnowledgeTimelinePresentation.monthTitle(period.month))
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    if !timeline.undated.isEmpty {
                        Section {
                            ForEach(timeline.undated, id: \.factID) { row($0) }
                        } header: {
                            Text(KnowledgeTimelinePresentation.text("undated")).accessibilityAddTraits(.isHeader)
                        } footer: {
                            Text(KnowledgeTimelinePresentation.text("undated_footer"))
                        }
                        .accessibilityIdentifier("knowledge.timeline.undated")
                    }
                }
                .accessibilityIdentifier("knowledge.timeline")
            }
        }
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

    @ViewBuilder
    private func row(_ entry: KnowledgeTimeline.Entry) -> some View {
        let row = KnowledgeTimelinePresentation.row(entry, meetingTitles: read.meetingTitles)
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: row.claim).font(Theme.bodyEmphasized)
            if let stated = row.stated { Text(verbatim: stated).font(Theme.footnote) }
            Text(verbatim: row.source).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            if !row.badges.isEmpty {
                Text(verbatim: row.badges.joined(separator: " · ")).font(Theme.captionEmphasized)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let route = row.evidence {
            NavigationLink(value: route) { content }
                .accessibilityIdentifier("knowledge.timeline.entry")
        } else {
            content.accessibilityIdentifier("knowledge.timeline.entry")
        }
    }
}
