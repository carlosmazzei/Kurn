import KurnCore
import SwiftUI

struct KnowledgeEvidenceDetailView: View {
    let source: KnowledgeEvidenceRead

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                KnowledgeClaimReadView(entry: source.entry)
                Text(verbatim: source.evidence.quote).font(Theme.title3).textSelection(.enabled)
                    .accessibilityIdentifier("knowledge.browser.quote")
                Text(String(format: NSLocalizedString("detail.knowledge.attribution", comment: "Attribution"), source.evidence.attributedSpeaker))
                Text(verbatim: source.meetingTitle).font(Theme.headline)
                Text(source.entry.fact.source.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.footnote)
                Text(verbatim: (Double(source.evidence.startMs) / 1_000).clockDisplay + " – " + (Double(source.evidence.endMs) / 1_000).clockDisplay)
                NavigationLink(value: KnowledgeBrowserRoute.transcript(assertionID: source.entry.fact.id, evidenceID: source.evidence.id)) {
                    Label(KnowledgeBrowserCopy.text("open_transcript"), systemImage: "text.alignleft")
                }
                .accessibilityIdentifier("knowledge.browser.openTranscript")
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
}

struct KnowledgeSourceTranscriptView: View {
    let source: KnowledgeEvidenceRead
    let isPlaying: Bool
    let isLoadingAudio: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: source.meetingTitle).font(Theme.headline).accessibilityAddTraits(.isHeader)
            Button(action: onPlay) {
                Label(KnowledgeBrowserCopy.text(isPlaying ? "stop" : "play"), systemImage: isPlaying ? "stop.fill" : "play.fill")
            }
            .disabled(isLoadingAudio)
            .accessibilityIdentifier("knowledge.browser.play")
            if isLoadingAudio { ProgressView() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(source.segments) { segment in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: segment.speakerLabel + " · " + segment.startTime.clockDisplay).font(Theme.footnoteEmphasized)
                                Text(verbatim: segment.text).font(Theme.body).textSelection(.enabled)
                                    .accessibilityIdentifier(isCited(segment) ? "knowledge.browser.citedSegment" : "knowledge.browser.segment")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(isCited(segment) ? Theme.accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .id(segment.id)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .task(id: source.transcriptFingerprint) {
                    await Task.yield()
                    if let anchor = source.evidence.segmentIDs.first.flatMap(UUID.init(uuidString:)) { proxy.scrollTo(anchor, anchor: .center) }
                }
            }
        }
        .padding(20)
    }

    private func isCited(_ segment: TranscriptSegment) -> Bool { source.evidence.segmentIDs.contains(segment.id.uuidString.lowercased()) }
}
