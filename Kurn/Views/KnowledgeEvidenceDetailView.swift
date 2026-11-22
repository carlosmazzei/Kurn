import KurnCore
import SwiftUI

struct KnowledgeEvidenceDetailView: View {
    let source: KnowledgeEvidenceRead

    /// When the meeting was recorded and where in it the passage sits.
    private var when: String {
        let recorded = source.entry.fact.source.recordedAt.formatted(date: .abbreviated, time: .shortened)
        let start = (Double(source.evidence.startMs) / 1_000).clockDisplay
        let end = (Double(source.evidence.endMs) / 1_000).clockDisplay
        return "\(recorded) · \(start) – \(end)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                KnowledgeClaimReadView(entry: source.entry).knowledgeCard()
                KnowledgeSectionLabel(KnowledgeBrowserCopy.text("evidence")).padding(.top, 4)
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: source.evidence.quote)
                        .font(Theme.body).foregroundStyle(Theme.textPrimary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.separator).frame(width: 3).accessibilityHidden(true)
                        }
                        .accessibilityIdentifier("knowledge.browser.quote")
                    Text(String(format: NSLocalizedString("detail.knowledge.attribution", comment: "Attribution"), source.evidence.attributedSpeaker))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Divider().overlay(Theme.separator).accessibilityHidden(true)
                    HStack(spacing: 12) {
                        KnowledgeIconWell(systemImage: "waveform", tint: Theme.info)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: source.meetingTitle).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                            Text(verbatim: when).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    NavigationLink(value: KnowledgeBrowserRoute.transcript(assertionID: source.entry.fact.id, evidenceID: source.evidence.id)) {
                        KnowledgeChipLabel(title: KnowledgeBrowserCopy.text("open_transcript"), systemImage: "text.alignleft")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("knowledge.browser.openTranscript")
                }
                .knowledgeCard()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .knowledgeReadingSurface()
    }
}

struct KnowledgeSourceTranscriptView: View {
    let source: KnowledgeEvidenceRead
    let isPlaying: Bool
    let isLoadingAudio: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(verbatim: source.meetingTitle)
                    .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLoadingAudio { ProgressView().controlSize(.small) }
                KnowledgeChipButton(title: KnowledgeBrowserCopy.text(isPlaying ? "stop" : "play"),
                                    systemImage: isPlaying ? "stop.fill" : "play.fill", action: onPlay)
                    .disabled(isLoadingAudio)
                    .accessibilityIdentifier("knowledge.browser.play")
            }
            .padding(.horizontal, 20).padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(source.segments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: segment.speakerLabel + " · " + segment.startTime.clockDisplay)
                                    .font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
                                Text(verbatim: segment.text).font(Theme.body).foregroundStyle(Theme.textPrimary)
                                    .accessibilityIdentifier(isCited(segment) ? "knowledge.browser.citedSegment" : "knowledge.browser.segment")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            // The cited passage is outlined as well as tinted: not colour alone.
                            .overlay {
                                if isCited(segment) {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.ink, lineWidth: 1.5)
                                }
                            }
                            .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .task(id: source.transcriptFingerprint) {
                    await Task.yield()
                    if let anchor = source.evidence.segmentIDs.first.flatMap(UUID.init(uuidString:)) { proxy.scrollTo(anchor, anchor: .center) }
                }
            }
        }
        .knowledgeReadingSurface()
    }

    private func isCited(_ segment: TranscriptSegment) -> Bool { source.evidence.segmentIDs.contains(segment.id.uuidString.lowercased()) }
}
