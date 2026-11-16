import KurnCore
import SwiftUI

struct KnowledgeEntityPageView: View {
    let page: KnowledgeWikiPage
    let meetingTitles: [UUID: String]
    @State private var showsSources = false

    var body: some View {
        VStack(spacing: 0) {
            Picker(KnowledgeBrowserCopy.text("page"), selection: $showsSources) {
                Text(KnowledgeBrowserCopy.text("overview")).tag(false).accessibilityIdentifier("knowledge.browser.overview")
                Text(KnowledgeBrowserCopy.text("sources")).tag(true).accessibilityIdentifier("knowledge.browser.sources")
            }
            .pickerStyle(.segmented).padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if showsSources {
                        ForEach(page.sections.flatMap(\.entries), id: \.fact.id) { entry in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(verbatim: meetingTitles[entry.fact.source.meetingID] ?? "").font(Theme.headline)
                                    .accessibilityAddTraits(.isHeader)
                                KnowledgeClaimReadView(entry: entry)
                                ForEach(entry.fact.source.evidence, id: \.id) { evidence in
                                    NavigationLink(value: KnowledgeBrowserRoute.evidence(assertionID: entry.fact.id, evidenceID: evidence.id)) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(verbatim: evidence.quote)
                                            Text(verbatim: evidence.attributedSpeaker).font(Theme.footnote)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .accessibilityIdentifier("knowledge.browser.evidence")
                                }
                            }
                            .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                        }
                    } else {
                        if !page.entity.aliases.isEmpty {
                            Text(verbatim: page.entity.aliases.joined(separator: " · ")).font(Theme.footnote)
                        }
                        ForEach(page.sections, id: \.kind) { section in
                            Text(KnowledgeBrowserCopy.text("section." + section.kind.rawValue))
                                .font(Theme.title3).accessibilityAddTraits(.isHeader)
                            ForEach(section.entries, id: \.fact.id) { entry in KnowledgeClaimReadView(entry: entry) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }
}

struct KnowledgeClaimReadView: View {
    let entry: KnowledgeWikiPage.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: MeetingKnowledgeClaimPresentation.text(entry)).font(Theme.bodyEmphasized)
                .accessibilityIdentifier("knowledge.browser.claim")
            Text(NSLocalizedString("knowledge.modality." + entry.fact.qualifiers.modality.rawValue, comment: "Claim modality"))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            if let from = entry.fact.qualifiers.validFrom {
                Text(String(format: KnowledgeBrowserCopy.text("valid_from"), from.text)).font(Theme.footnote)
            }
            if let to = entry.fact.qualifiers.validTo {
                Text(String(format: KnowledgeBrowserCopy.text("valid_to"), to.text)).font(Theme.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
