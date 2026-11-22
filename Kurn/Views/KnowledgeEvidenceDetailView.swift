import KurnCore
import SwiftUI

struct KnowledgeEvidenceDetailView: View {
    let source: KnowledgeEvidenceRead
    var isPlaying: Bool = false
    var isLoadingAudio: Bool = false
    var onPlay: (() -> Void)?

    /// When the meeting was recorded and where in it the passage sits.
    private var range: String {
        let start = (Double(source.evidence.startMs) / 1_000).clockDisplay
        let end = (Double(source.evidence.endMs) / 1_000).clockDisplay
        return "\(start) – \(end)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "\(source.meetingTitle) · \(source.fileName)")
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                Text(verbatim: MeetingKnowledgeClaimPresentation.text(source.entry))
                    .font(Theme.bodyEmphasized).foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("knowledge.browser.claim")
                playerCard
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

    /// The passage's audio: an ink play/pause circle beside its m:ss range.
    private var playerCard: some View {
        HStack(spacing: 14) {
            if let onPlay {
                Button(action: onPlay) {
                    ZStack {
                        if isLoadingAudio {
                            ProgressView().controlSize(.small).tint(Theme.onInk)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(Theme.bodyEmphasized)
                                .foregroundStyle(Theme.onInk)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .background(Theme.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isLoadingAudio)
                .accessibilityLabel(KnowledgeBrowserCopy.text(isPlaying ? "stop" : "play"))
                .accessibilityIdentifier("knowledge.browser.play")
            } else {
                Image(systemName: "play.fill")
                    .font(Theme.bodyEmphasized)
                    .foregroundStyle(Theme.onInk)
                    .frame(width: 46, height: 46)
                    .background(Theme.ink, in: Circle())
                    .accessibilityHidden(true)
            }
            Capsule().fill(Theme.fill).frame(height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.ink).frame(width: 4, height: 4).accessibilityHidden(true)
                }
                .accessibilityHidden(true)
            Text(verbatim: range)
                .font(Theme.footnote.monospacedDigit()).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            // The cited passage sits on a soft fill, as an
                            // active transcript segment does — no coloured stroke.
                            .background(isCited(segment) ? Theme.fill : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
