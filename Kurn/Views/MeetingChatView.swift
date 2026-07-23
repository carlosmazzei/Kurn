//
//  MeetingChatView.swift
//  Kurn
//
//  "Chat with your meetings": a grounded Q&A over transcripts. Used two ways —
//  as a tab inside a single meeting (`meeting` non-nil), and as a library-wide
//  "Ask" sheet from the meetings list (`meeting` nil, searching every indexed
//  chunk). Answers come from the configured summary LLM provider, grounded in
//  on-device retrieved passages; tapping a citation calls `onJump`.
//

import SwiftData
import SwiftUI

struct MeetingChatView: View {
    /// The meeting to chat about, or `nil` to ask across the whole library.
    let meeting: Meeting?
    /// Invoked when the user taps a retrieval citation (host decides where to jump).
    var onJump: ((SemanticSearchService.Hit) -> Void)?
    /// Invoked when the user taps a cited `[mm:ss]` in a full-context answer;
    /// the host seeks that absolute meeting time. Per-meeting scope only.
    var onJumpToTime: ((TimeInterval) -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var vm = MeetingChatViewModel()
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !settings.semanticSearchEnabled {
                disabledState
            } else if !hasIndex {
                emptyIndexState
            } else {
                conversation
            }
            composer
        }
        .background(Theme.background)
        .errorAlert($vm.error)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.turns.isEmpty { starterHint }
                    ForEach(vm.turns) { turn in
                        turnRow(turn).id(turn.id)
                    }
                    if vm.isResponding { respondingRow }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            // Tap on the message area lowers the keyboard. `simultaneousGesture`
            // (not `onTapGesture`) so it doesn't swallow citation-button taps or
            // block scrolling.
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            .onChange(of: vm.turns.count) { _, _ in
                if let last = vm.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: MeetingChatViewModel.Turn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant, .system:
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(turn.text)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.separator, lineWidth: 1)
                    )
                if !turn.citations.isEmpty {
                    citations(turn.citations)
                } else if meeting != nil {
                    // Full-context answer: no retrieval hits, so make the [mm:ss]
                    // timestamps the model cited tappable.
                    timestampChips(MeetingChatService.citedTimestamps(in: turn.text))
                }
            }
        }
    }

    @ViewBuilder
    private func timestampChips(_ times: [TimeInterval]) -> some View {
        if !times.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(times, id: \.self) { time in
                        Button { onJumpToTime?(time) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "clock").font(.system(size: 10))
                                Text(time.clockDisplay).font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.fill, in: Capsule())
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(onJumpToTime == nil)
                    }
                }
            }
        }
    }

    /// Citation chip text. In the library-wide ask the meeting title is shown so
    /// a quote can be traced to its source meeting; per-meeting scope omits it.
    private func citationLabel(for hit: SemanticSearchService.Hit) -> String {
        let base = "\(hit.start.clockDisplay) · \(hit.speakerLabel)"
        guard meeting == nil, !hit.meetingTitle.isEmpty else { return base }
        return "\(hit.meetingTitle) · \(base)"
    }

    private func citations(_ hits: [SemanticSearchService.Hit]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(hits) { hit in
                    Button { onJump?(hit) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "quote.opening").font(.system(size: 10))
                            Text(citationLabel(for: hit))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.fill, in: Capsule())
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(onJump == nil)
                }
            }
        }
    }

    private var respondingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(NSLocalizedString("chat.thinking", comment: "Assistant thinking"))
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var starterHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("chat.starter.title", comment: "Chat starter title"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(NSLocalizedString("chat.starter.subtitle", comment: "Chat starter subtitle"))
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(
                NSLocalizedString("chat.placeholder", comment: "Chat input placeholder"),
                text: $input,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.separator, lineWidth: 1))
            .disabled(!canChat)

            if vm.isResponding {
                Button { vm.cancel() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.warning)
                }
            } else {
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.accent : Theme.textTertiary)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider().overlay(Theme.separator) }
    }

    // MARK: - Empty / disabled states

    private var disabledState: some View {
        infoState(
            icon: "magnifyingglass",
            title: NSLocalizedString("chat.disabled.title", comment: "Chat disabled title"),
            subtitle: NSLocalizedString("chat.disabled.subtitle", comment: "Chat disabled subtitle")
        )
    }

    private var emptyIndexState: some View {
        infoState(
            icon: "text.magnifyingglass",
            title: NSLocalizedString("chat.no_index.title", comment: "Chat no index title"),
            subtitle: NSLocalizedString("chat.no_index.subtitle", comment: "Chat no index subtitle")
        )
    }

    private func infoState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - State & actions

    /// Whether any indexed passages exist for the current scope.
    private var hasIndex: Bool {
        if let meeting { return !meeting.semanticChunks.isEmpty }
        return (try? modelContext.fetchCount(FetchDescriptor<SemanticChunk>())) ?? 0 > 0
    }

    private var canChat: Bool { settings.semanticSearchEnabled && hasIndex }
    private var canSend: Bool {
        canChat && !vm.isResponding && !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Max characters of a meeting's summary passed to the library chat as an
    /// overview, so overviews stay a connective aid without dominating the prompt.
    private static let summaryContextLimit = 1_500

    private func send() {
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        vm.send(
            question: input,
            transcriptText: meetingTranscriptText(),
            candidates: candidates(),
            summariesByMeeting: summariesByMeeting(),
            provider: provider,
            model: model
        )
        input = ""
        inputFocused = false
    }

    /// Per-meeting summary overviews for the library-wide ask (meetingID →
    /// condensed markdown). Empty for single-meeting scope, which grounds on the
    /// full transcript instead. Built here on the main actor; the service only
    /// renders the ones whose meeting shows up in the retrieved excerpts.
    private func summariesByMeeting() -> [UUID: String] {
        guard meeting == nil else { return [:] }
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        var result: [UUID: String] = [:]
        for item in meetings {
            guard let summary = item.latestSummary else { continue }
            let markdown = SummaryService.markdownText(from: summary.sections)
            guard !markdown.isEmpty else { continue }
            result[item.id] = String(markdown.prefix(Self.summaryContextLimit))
        }
        return result
    }

    /// Snapshot the chunks to search over: this meeting's, or every meeting's
    /// for a library-wide ask. Built here on the main actor.
    private func candidates() -> [SemanticSearchService.Candidate] {
        if let meeting {
            return meeting.semanticChunks.map(\.searchCandidate)
        }
        let all = (try? modelContext.fetch(FetchDescriptor<SemanticChunk>())) ?? []
        return all.map(\.searchCandidate)
    }

    /// The whole meeting transcript as `[mm:ss] Speaker: text` lines, for
    /// full-context grounding. Nil for the library-wide ask (no single meeting).
    private func meetingTranscriptText() -> String? {
        guard let meeting else { return nil }
        let groups: [(offset: TimeInterval, segments: [TranscriptSegment])] = meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { recording in
                guard let segments = recording.transcript?.segments, !segments.isEmpty else { return nil }
                return (offset: meeting.startOffset(of: recording), segments: segments)
            }
        let text = SummaryService.assembleTranscriptText(from: groups)
        return text.isEmpty ? nil : text
    }
}
