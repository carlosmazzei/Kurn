import KurnCore
import SwiftUI

struct KnowledgeEntityPageView: View {
    let page: KnowledgeWikiPage
    let meetingTitles: [UUID: String]
    @State private var showsSources = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Ask about the entity (K5.3). The browser presents it, so a reload of this page cannot dismiss it.
    var onAsk: ((ChatSourceScope) -> Void)?
    /// Pushing from inside a Menu needs the browser's path, not a NavigationLink.
    var navigate: ((KnowledgeBrowserRoute) -> Void)?

    private var entries: [KnowledgeWikiPage.Entry] { page.sections.flatMap(\.entries) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showsSources { sources } else { overview }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 96)
            }
        }
        .background(Theme.readingBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { askBar }
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: KnowledgeBrowserRoute.timeline) {
                Label(KnowledgeBrowserCopy.text("timeline"), systemImage: "clock")
            }
            .accessibilityIdentifier("knowledge.browser.timeline")
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: KnowledgeBrowserRoute.graph(page.entity.id)) {
                Label(KnowledgeGraphPresentation.copy("title"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("knowledge.browser.graph")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { navigate?(.compare(page.entity.id)) } label: {
                    Label(KnowledgeComparePresentation.copy("title"), systemImage: "calendar.badge.clock")
                }
                .accessibilityIdentifier("knowledge.browser.compare")
                Button { showsSources.toggle() } label: {
                    Label(KnowledgeBrowserCopy.text("sources"), systemImage: "list.bullet")
                }
                .accessibilityIdentifier("knowledge.browser.sources")
                if let onAsk, let scope = KnowledgeEntityAsk.scope(page) {
                    Button { onAsk(scope) } label: {
                        Label(KnowledgeBrowserCopy.text("ask_entity"), systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
            } label: {
                Label(NSLocalizedString("knowledge.entity.page_actions", comment: "Page actions"), systemImage: "ellipsis")
            }
            .accessibilityLabel(NSLocalizedString("knowledge.entity.page_actions", comment: "Page actions"))
            .accessibilityIdentifier("knowledge.entity.actions")
        }
    }

    /// The floating Ask bar, mirroring the meeting detail's; hidden while the
    /// Sources list replaces the page.
    @ViewBuilder
    private var askBar: some View {
        if let onAsk, let scope = KnowledgeEntityAsk.scope(page), !showsSources {
            Button { onAsk(scope) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(Theme.bodyEmphasized)
                        .foregroundStyle(Theme.ink)
                        .accessibilityHidden(true)
                    Text(String(format: NSLocalizedString("knowledge.entity.ask_about", comment: "Ask about entity"), page.entity.name))
                        .font(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onInk)
                        .frame(width: 38, height: 38)
                        .background(Theme.ink, in: Circle())
                        .accessibilityHidden(true)
                }
                .padding(.leading, 16).padding(.trailing, 7)
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
            .padding(.horizontal, 14)
            .accessibilityIdentifier("knowledge.entity.ask")
        }
    }

    @ViewBuilder
    private var overview: some View {
        chipsRow
        if !page.entity.aliases.isEmpty {
            Text(verbatim: page.entity.aliases.joined(separator: " · "))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
        }
        if let narrative = page.narrative {
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
                    .tint(Theme.textSecondary)
                    .accessibilityIdentifier("knowledge.browser.narrative.sources")
                }
                Label(NSLocalizedString("knowledge.entity.provenance", comment: "AI provenance"), systemImage: "sparkles")
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("knowledge.browser.narrative")
        }
        factsSection
        KnowledgeMentionedInView(entries: entries, meetingTitles: meetingTitles)
        KnowledgeLateArrivalsView(page: page)
    }

    /// Kind, source count and freshness as small grey capsules.
    private var chipsRow: some View {
        HStack(spacing: 8) {
            chip(NSLocalizedString("knowledge.entity_kind." + page.entity.kind.rawValue, comment: "Entity kind"))
            chip(knowledgeCountText("knowledge.count.meeting", Set(entries.map(\.fact.source.meetingID)).count))
            if let latest = entries.map(\.fact.source.recordedAt).max() {
                chip(String(format: NSLocalizedString("knowledge.entity.updated", comment: "Updated"), latest.relativeDay))
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.footnote)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.fill, in: Capsule())
    }

    @ViewBuilder
    private var factsSection: some View {
        if !entries.isEmpty {
            KnowledgeSectionLabel(NSLocalizedString("knowledge.entity.facts", comment: "Facts")).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.fact.id) { index, entry in
                    if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 14).accessibilityHidden(true) }
                    factRow(entry)
                }
            }
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private func factRow(_ entry: KnowledgeWikiPage.Entry) -> some View {
        let proposed = entry.fact.qualifiers.modality == .proposed || entry.fact.qualifiers.modality == .hypothetical
        let predicate = NSLocalizedString("knowledge.predicate." + entry.fact.predicate.rawValue, comment: "Claim predicate")
        let source = sourceLine(entry)
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: predicate).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            Text(verbatim: factValueText(entry))
                .font(proposed ? Theme.body.italic() : Theme.body.weight(.medium))
                .foregroundStyle(proposed ? Theme.textSecondary : Theme.textPrimary)
                .accessibilityIdentifier("knowledge.browser.claim")
            HStack(spacing: 4) {
                Text(verbatim: source).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                if proposed {
                    Text(verbatim: "· " + NSLocalizedString("knowledge.modality." + entry.fact.qualifiers.modality.rawValue, comment: "Claim modality"))
                        .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)

        if let evidence = entry.fact.source.evidence.first {
            NavigationLink(value: KnowledgeBrowserRoute.evidence(assertionID: entry.fact.id, evidenceID: evidence.id)) {
                HStack(spacing: 12) {
                    content
                    KnowledgeChevron()
                }
                .padding(.trailing, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.browser.evidence")
        } else {
            content
        }
    }

    /// The fact's object alone ("Open"); the page is the subject and the
    /// label line names the predicate. Falls back to the full claim text when
    /// the fact carries no object.
    private func factValueText(_ entry: KnowledgeWikiPage.Entry) -> String {
        if let object = entry.object?.name { return object }
        if let value = entry.fact.value { return MeetingKnowledgeClaimPresentation.valueText(value) }
        return MeetingKnowledgeClaimPresentation.text(entry)
    }

    /// "<meeting title> · m:ss" — where this fact was said.
    private func sourceLine(_ entry: KnowledgeWikiPage.Entry) -> String {
        let title = meetingTitles[entry.fact.source.meetingID] ?? ""
        if let first = entry.fact.source.evidence.first {
            return "\(title) · \((Double(first.startMs) / 1_000).clockDisplay)"
        }
        return title
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

/// Every meeting a fact on this page was said in, newest first. The sheet
/// cannot push a meeting detail, so these rows inform only.
private struct KnowledgeMentionedInView: View {
    let entries: [KnowledgeWikiPage.Entry]
    let meetingTitles: [UUID: String]

    private struct MeetingMention: Identifiable {
        let id: UUID
        let title: String
        let date: Date
        let count: Int
    }

    private var meetings: [MeetingMention] {
        var latest: [UUID: MeetingMention] = [:]
        for entry in entries {
            let id = entry.fact.source.meetingID
            let recorded = entry.fact.source.recordedAt
            if let existing = latest[id] {
                latest[id] = MeetingMention(id: id, title: existing.title,
                                            date: max(existing.date, recorded), count: existing.count + 1)
            } else {
                latest[id] = MeetingMention(id: id, title: meetingTitles[id] ?? "", date: recorded, count: 1)
            }
        }
        return latest.values.sorted { $0.date > $1.date }
    }

    var body: some View {
        if !meetings.isEmpty {
            KnowledgeSectionLabel(NSLocalizedString("knowledge.entity.mentioned_in", comment: "Mentioned in")).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 58).accessibilityHidden(true) }
                    HStack(spacing: 12) {
                        KnowledgeIconWell(systemImage: "waveform")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title).font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                            Text(verbatim: item.date.relativeDay + " · " + knowledgeCountText("knowledge.count.fact", item.count))
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
