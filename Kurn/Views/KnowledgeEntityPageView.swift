import KurnCore
import SwiftUI

struct KnowledgeEntityPageView: View {
    let page: KnowledgeWikiPage
    let meetingTitles: [UUID: String]
    @State private var showsSources = false
    /// Ask about the entity (K5.3). The browser presents it, so a reload of this page cannot dismiss it.
    var onAsk: ((ChatSourceScope) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Picker(KnowledgeBrowserCopy.text("page"), selection: $showsSources) {
                Text(KnowledgeBrowserCopy.text("overview")).tag(false).accessibilityIdentifier("knowledge.browser.overview")
                Text(KnowledgeBrowserCopy.text("sources")).tag(true).accessibilityIdentifier("knowledge.browser.sources")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showsSources { sources } else { overview }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            }
        }
        .knowledgeReadingSurface()
        .toolbar {
            if let onAsk, let scope = KnowledgeEntityAsk.scope(page) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onAsk(scope) } label: {
                        Label(KnowledgeBrowserCopy.text("ask_entity"), systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .accessibilityIdentifier("knowledge.entity.ask")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: KnowledgeBrowserRoute.compare(page.entity.id)) {
                    Label(KnowledgeComparePresentation.copy("title"), systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("knowledge.browser.compare")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: KnowledgeBrowserRoute.graph(page.entity.id)) {
                    Label(KnowledgeGraphPresentation.copy("title"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityIdentifier("knowledge.browser.graph")
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        if !page.entity.aliases.isEmpty {
            Text(verbatim: page.entity.aliases.joined(separator: " · "))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
        }
        if let narrative = page.narrative {
            KnowledgeSectionLabel(KnowledgeBrowserCopy.text("narrative")).padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(narrative.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph.text).font(Theme.body)
                    let cited = page.entries(citedBy: paragraph)
                    DisclosureGroup(String(format: KnowledgeBrowserCopy.text("narrative_sources"), cited.count)) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(cited, id: \.fact.id) { KnowledgeClaimReadView(entry: $0) }
                        }
                        .padding(.top, 6)
                    }
                    .font(Theme.footnote)
                    .accessibilityIdentifier("knowledge.browser.narrative.sources")
                }
                Text(KnowledgeBrowserCopy.text("narrative_note")).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            }
            .knowledgeCard()
            .accessibilityIdentifier("knowledge.browser.narrative")
        }
        ForEach(page.sections, id: \.kind) { section in
            KnowledgeSectionLabel(KnowledgeBrowserCopy.text("section." + section.kind.rawValue))
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(section.entries.enumerated()), id: \.element.fact.id) { index, entry in
                    if index > 0 { Divider().overlay(Theme.separator).accessibilityHidden(true) }
                    KnowledgeClaimReadView(entry: entry)
                }
            }
            .knowledgeCard()
        }
        KnowledgeLateArrivalsView(page: page)
    }

    private var sources: some View {
        ForEach(page.sections.flatMap(\.entries), id: \.fact.id) { entry in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    KnowledgeIconWell(systemImage: "waveform", tint: Theme.info)
                    Text(verbatim: meetingTitles[entry.fact.source.meetingID] ?? "")
                        .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                KnowledgeClaimReadView(entry: entry)
                ForEach(entry.fact.source.evidence, id: \.id) { evidence in
                    NavigationLink(value: KnowledgeBrowserRoute.evidence(assertionID: entry.fact.id, evidenceID: evidence.id)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                KnowledgeQuote(text: evidence.quote)
                                Text(verbatim: evidence.attributedSpeaker)
                                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).padding(.leading, 15)
                            }
                            KnowledgeChevron()
                        }
                        .padding(12)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("knowledge.browser.evidence")
                }
            }
            .knowledgeCard()
        }
    }
}

struct KnowledgeClaimReadView: View {
    let entry: KnowledgeWikiPage.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: MeetingKnowledgeClaimPresentation.text(entry))
                .font(Theme.bodyEmphasized).foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("knowledge.browser.claim")
            Text(NSLocalizedString("knowledge.modality." + entry.fact.qualifiers.modality.rawValue, comment: "Claim modality"))
                .font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
            if let from = entry.fact.qualifiers.validFrom {
                Text(String(format: KnowledgeBrowserCopy.text("valid_from"), from.text))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            if let to = entry.fact.qualifiers.validTo {
                Text(String(format: KnowledgeBrowserCopy.text("valid_to"), to.text))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
