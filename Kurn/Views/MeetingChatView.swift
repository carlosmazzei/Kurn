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

import Combine
import SwiftData
import SwiftUI
import UIKit

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var vm = MeetingChatViewModel()
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    /// Anchor for the "thinking for Ns" live timer in `respondingRow`, reset
    /// each time a new reply starts.
    @State private var respondingStartedAt = Date()
    @State private var showingHistory = false
    /// Measured height of the floating composer card. The transcript scrolls
    /// beneath it (see `conversation`), so scrolling to the latest message has
    /// to clear this much on top of the bottom safe area.
    @State private var composerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if !settings.semanticSearchEnabled {
                disabledState
            } else if !hasIndex {
                emptyIndexState
            } else {
                conversation
            }
        }
        .background(Theme.background)
        // A composer is an input surface, not a toolbar, so it stays custom.
        // It's an overlay rather than a `.safeAreaBar`: a bar reserves its own
        // strip of safe area, which the transcript would stop above — as an
        // overlay the card floats over the transcript, which keeps running
        // beneath it and the keyboard (the keyboard's glass is only
        // translucent when there's content behind it). This VStack still
        // respects the keyboard safe area, so the bottom-aligned overlay
        // rides up with it for free.
        .overlay(alignment: .bottom) {
            composer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .errorAlert($vm.error)
        .toolbar { historyToolbar }
        .sheet(isPresented: $showingHistory) {
            ChatSessionListView(
                sessions: vm.pastSessions(),
                currentSessionID: vm.currentSessionID,
                onSelect: { vm.load(session: $0) },
                onDelete: { vm.delete($0) }
            )
        }
        // Wiring the persistence scope is cheap and idempotent, so redoing it
        // on every appearance (rather than a one-shot `.task`) needs no extra
        // state to guard against `meeting`/`modelContext` changing under it.
        .onAppear { vm.configure(meeting: meeting, modelContext: modelContext) }
    }

    /// "New conversation" and "History" — mirrors Claude's own chat history
    /// affordances: start fresh, or reopen a saved one. Shown regardless of
    /// `canChat` so past conversations stay reachable even if semantic search
    /// is currently off or unindexed.
    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel(NSLocalizedString("chat.history.button", comment: "Open chat history"))
            Button {
                vm.reset()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel(NSLocalizedString("chat.new.button", comment: "Start a new conversation"))
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        // The reader's bottom inset is the keyboard while it's up and the
        // home indicator otherwise — exactly the region the ScrollView below
        // extends into, so it's what the content padding has to clear.
        GeometryReader { geometry in
            conversationScroll(bottomInset: geometry.safeAreaInsets.bottom)
        }
    }

    private func conversationScroll(bottomInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            // SwiftLint attributes the accessibility_trait_for_button
            // violation from the `.simultaneousGesture` below to this
            // ScrollView's declaration, not to the modifier call site.
            // swiftlint:disable:next accessibility_trait_for_button
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.turns.isEmpty { starterHint }
                    ForEach(vm.turns) { turn in
                        turnRow(turn).id(turn.id)
                    }
                    // Once the reply starts streaming, its growing text bubble
                    // (rendered by `turnRow`, with a cursor) replaces this row —
                    // showing both at once would say "thinking" next to an
                    // answer that's already appearing.
                    if vm.isResponding && vm.turns.last?.role != .assistant { respondingRow }
                    if let question = vm.retryableQuestion { retryRow(question: question) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                // The ScrollView below runs to the screen's bottom edge (so
                // the transcript itself doesn't resize when the keyboard
                // shows), which means nothing reserves room for the composer
                // card or the keyboard — without this, `proxy.scrollTo(anchor:
                // .bottom)` would park the latest message right behind them
                // instead of above them.
                .padding(.bottom, 16 + composerHeight + bottomInset)
                .kurnAnimation(.easeInOut(duration: 0.25), value: bottomInset)
            }
            .scrollDismissesKeyboard(.interactively)
            // A short conversation leaves most of the ScrollView's own frame
            // as blank space below the last row — a `LazyVStack` only lays
            // out to fit its content, so a gesture that only sees that
            // content never gets a chance to fire there. `.background` takes
            // the ScrollView's own (full) size regardless of content height,
            // so this catches a tap anywhere in the visible conversation
            // area, not just on a rendered row. `.onTapGesture` (a discrete
            // tap, no movement) rather than the ScrollView's own drag-based
            // scroll gesture, so it doesn't compete with scrolling; sitting
            // behind the real content means a citation/retry button or
            // selectable text still claims the touch first where they
            // overlap it. Not a button semantically — it's a dismiss-keyboard
            // convenience over the whole scroll area — so `.isButton` would
            // misrepresent it to VoiceOver rather than fix anything.
            .background(
                // This `onTapGesture` gets its own enclosing declaration
                // (`Color.clear`, not the ScrollView above), so it needs its
                // own disable comment even though the rationale is the same.
                // swiftlint:disable:next accessibility_trait_for_button
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
            )
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .onChange(of: vm.turns.count) { _, _ in
                guard let last = vm.turns.last else { return }
                if reduceMotion {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.isResponding) { _, isResponding in
                if isResponding { respondingStartedAt = Date() }
            }
            // Claude's own composer floats over the transcript instead of
            // pushing it up: the keyboard and the composer read as a layer in
            // front, and the last few rows are simply covered (scrollable
            // back into view) rather than the whole conversation reflowing.
            // Ignoring the whole bottom safe area (not just `.keyboard`) is
            // what lets the transcript run under the home indicator and the
            // keyboard so both stay translucent; without it, the ScrollView's
            // own keyboard-avoidance shrinks it by the keyboard's height and
            // the content visibly jumps every time the keyboard shows or hides.
            .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: MeetingChatViewModel.Turn) -> some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant, .system:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    // Claude/ChatGPT-style "not yet confirmed" cue: while a
                    // reply is streaming in, its text is plain (not
                    // Markdown-rendered) and reads as provisional — italic
                    // and dimmed. Rendering plain text while streaming keeps
                    // each delta cheap to apply (no re-parsing the whole
                    // growing string into blocks on every fragment), which is
                    // what makes the answer actually appear incrementally
                    // rather than in occasional bursts; the instant it's the
                    // finished answer, it swaps to full Markdown at full
                    // weight/opacity.
                    if isStreaming(turn) {
                        Text(turn.text)
                            .italic()
                            .opacity(0.7)
                        StreamingCursor()
                    } else {
                        MarkdownText(turn.text)
                    }
                }
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .kurnAnimation(.easeInOut(duration: 0.2), value: isStreaming(turn))
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
                usageCaption(turn)
            }
        }
    }

    /// Token count, estimated cost, and generation time for a finished reply
    /// — shown only once the answer is confirmed (never mid-stream) and only
    /// when the provider actually reported usage.
    @ViewBuilder
    private func usageCaption(_ turn: MeetingChatViewModel.Turn) -> some View {
        if !isStreaming(turn), let usage = turn.usage {
            Text(Self.usageCaptionText(usage: usage, costUSD: turn.costUSD, elapsedSeconds: turn.elapsedSeconds))
                .font(Theme.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private static func usageCaptionText(usage: TokenUsage, costUSD: Double?, elapsedSeconds: TimeInterval?) -> String {
        var parts = [String(format: NSLocalizedString("chat.usage.tokens", comment: "Token count"), usage.totalTokens)]
        if let costUSD {
            parts.append(String(format: NSLocalizedString("chat.usage.cost", comment: "Estimated cost"), costUSD))
        }
        if let elapsedSeconds {
            parts.append(String(format: NSLocalizedString("chat.usage.duration", comment: "Generation duration"), elapsedSeconds))
        }
        return parts.joined(separator: " · ")
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
                                    .accessibilityHidden(true)
                                Text(time.clockDisplay).font(.system(.caption, design: .default, weight: .medium))
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
                                .accessibilityHidden(true)
                            Text(citationLabel(for: hit))
                                .font(.system(.caption, design: .default, weight: .medium))
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

    /// Whether `turn` is the reply currently streaming in, so its bubble gets
    /// a trailing cursor instead of reading as a finished answer.
    private func isStreaming(_ turn: MeetingChatViewModel.Turn) -> Bool {
        vm.isResponding && turn.role == .assistant && turn.id == vm.turns.last?.id
    }

    /// The "reasoning" row shown before any reply text has arrived. Mirrors
    /// the current `ChatPhase` reported by `MeetingChatService` — rewriting
    /// the question, searching, reranking, reading notes — so the wait reads
    /// as visible work instead of an opaque spinner, the same idea as the
    /// transcription progress phases. Also carries a Claude-style "breathing"
    /// shimmer and a live elapsed-time readout, so a long wait still reads as
    /// active work rather than a stall.
    private var respondingRow: some View {
        ThinkingRow(phase: vm.currentPhase, detail: vm.currentPhaseDetail, startedAt: respondingStartedAt)
    }

    /// Shown under an unanswered question — cancelled mid-stream, or failed
    /// before/without producing an answer — so the interruption isn't a dead
    /// end. Only one can exist at a time (there's at most one trailing
    /// unanswered question), mirroring Claude/ChatGPT's own retry affordance.
    private func retryRow(question: String) -> some View {
        Button {
            retry(question: question)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text(NSLocalizedString("chat.retry", comment: "Retry a cancelled or failed question"))
                    .font(Theme.footnote)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.retry")
    }

    private var starterHint: some View {
        // The library-wide "Ask" sheet (`meeting == nil`) needs its own copy —
        // "Ask about this meeting" makes no sense when there isn't one.
        let titleKey = meeting == nil ? "chat.starter.library.title" : "chat.starter.title"
        let subtitleKey = meeting == nil ? "chat.starter.library.subtitle" : "chat.starter.subtitle"
        return VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(titleKey, comment: "Chat starter title"))
                .font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
            Text(NSLocalizedString(subtitleKey, comment: "Chat starter subtitle"))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Composer

    /// Inset glass card, two rows: the text field across the top, then a
    /// row with the model chip on the left and the send/stop control on
    /// the right — the field gets the card's full width instead of sharing
    /// a line with the button.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                NSLocalizedString("chat.placeholder", comment: "Chat input placeholder"),
                text: $input,
                axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .accessibilityIdentifier("chat.input")
            .disabled(!canChat)

            HStack(spacing: 10) {
                modelChip
                Spacer(minLength: 0)
                sendOrStopButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.separator, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Which model answers — the summary provider's model, since chat shares
    /// it (see `sendQuestion`). Informational; the choice lives in Settings.
    private var modelChip: some View {
        let provider = settings.aiProvider
        let model = provider.kind == .appleOnDevice
            ? NSLocalizedString("settings.on_device_model_name", comment: "Apple Intelligence")
            : settings.summaryModel(for: provider)
        return Text(model)
            .font(.footnote)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.fill, in: Capsule())
            .accessibilityLabel(String(
                format: NSLocalizedString("chat.model_chip", comment: "Model in use"),
                model
            ))
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if vm.isResponding {
            Button { vm.cancel() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.warning, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("chat.stop", comment: "Stop"))
        } else {
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? .white : Theme.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Theme.accent : Theme.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(NSLocalizedString("chat.send", comment: "Send"))
            .accessibilityIdentifier("chat.send")
        }
    }

    // MARK: - Empty / disabled states

    private var disabledState: some View {
        infoState(
            icon: "magnifyingglass",
            title: NSLocalizedString("chat.disabled.title", comment: "Chat disabled title"),
            subtitle: NSLocalizedString("chat.disabled.subtitle", comment: "Chat disabled subtitle")
        )
        .accessibilityIdentifier("chat.disabled_state")
    }

    private var emptyIndexState: some View {
        infoState(
            icon: "text.magnifyingglass",
            title: NSLocalizedString("chat.no_index.title", comment: "Chat no index title"),
            subtitle: NSLocalizedString("chat.no_index.subtitle", comment: "Chat no index subtitle")
        )
        .accessibilityIdentifier("chat.empty_state")
    }

    private func infoState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .contain)
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
        sendQuestion(input)
        input = ""
        dismissKeyboard()
    }

    /// Resigns the composer's focus and, belt and suspenders, asks UIKit to
    /// resign whatever is first responder. `@FocusState` alone is usually
    /// enough, but a multi-line (`axis: .vertical`) `TextField` has had
    /// edge cases across iOS versions where setting it from outside the
    /// field's own update cycle doesn't reliably release the keyboard —
    /// this doesn't depend on that working.
    private func dismissKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Re-sends an interrupted question. `retryableQuestion` only reports a
    /// non-nil value when the last turn is that bare, unanswered question, so
    /// dropping it first (rather than leaving it for `vm.send` to duplicate)
    /// keeps the retried question as one bubble, not two.
    private func retry(question: String) {
        vm.dropRetryableQuestion()
        sendQuestion(question)
    }

    private func sendQuestion(_ question: String) {
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        vm.send(
            question: question,
            transcriptText: meetingTranscriptText(),
            candidates: candidates(),
            summariesByMeeting: summariesByMeeting(),
            articlesByMeeting: articlesByMeeting(),
            provider: provider,
            model: model
        )
    }

    /// Condensed wiki articles for the library-wide ask (meetingID → snapshot).
    /// Empty for single-meeting scope and when the wiki feature is off; the chat
    /// service grounds on these alongside the retrieved excerpts, and degrades to
    /// excerpts only when the map is empty. Built here on the main actor.
    private func articlesByMeeting() -> [UUID: WikiArticleSnapshot] {
        guard meeting == nil, settings.wikiEnabled else { return [:] }
        let articles = (try? modelContext.fetch(FetchDescriptor<WikiArticle>())) ?? []
        var result: [UUID: WikiArticleSnapshot] = [:]
        for article in articles {
            guard let meetingID = article.meeting?.id else { continue }
            result[meetingID] = article.snapshot
        }
        return result
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
        let text = meeting.assembledTranscriptText()
        return text.isEmpty ? nil : text
    }
}

/// A small blinking bar trailing a streaming reply's text, the same "still
/// typing" cue Claude/ChatGPT-style chat UIs use. Purely decorative — the
/// growing text and the "reasoning" row above it already convey progress to
/// VoiceOver, so this renders solid (no blink) rather than looping under
/// Reduce Motion, matching `RecorderView`'s `PulsingDot`.
private struct StreamingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Theme.textSecondary)
            .frame(width: 2, height: 14)
            .opacity(dim ? 0.15 : 1)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// The pre-answer "reasoning" row: the current `ChatPhase` (or a generic
/// "thinking" label before the first one arrives) plus a live elapsed-time
/// readout, the same shape Claude's own "Thinking for Ns" indicator uses so a
/// long wait still reads as active work. The label "breathes" — a slow,
/// looping opacity pulse — under normal motion; Reduce Motion keeps it at
/// full opacity and drops the pulse entirely, matching `StreamingCursor`.
private struct ThinkingRow: View {
    let phase: ChatPhase?
    let detail: String?
    let startedAt: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    /// Before the first `ChatPhase` arrives there's nothing to name yet, but
    /// the row still needs an icon — reusing the platform `ProgressView`
    /// spinner here reads as a different control from every other phase's
    /// icon+label row that follows it. An SF Symbol in the same family (and
    /// the same "breathing" treatment as the rest of this row) keeps the
    /// very first moment visually consistent with the phases after it.
    private static let defaultSystemImage = "ellipsis"

    private var label: String {
        let base = phase?.displayName ?? NSLocalizedString("chat.thinking", comment: "Assistant thinking")
        guard let detail else { return base }
        return "\(base) \(detail)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: phase?.systemImage ?? Self.defaultSystemImage)
                .font(.system(size: 12))
                .accessibilityHidden(true)
            Text(label)
                .font(Theme.footnote)
                .contentTransition(.opacity)
            Text(startedAt, style: .timer)
                .font(Theme.footnote.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.textSecondary)
        .opacity(shimmer ? 0.55 : 1)
        .kurnAnimation(.easeInOut(duration: 0.2), value: label)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        // The live timer already tells VoiceOver the wait is ongoing; a
        // breathing opacity loop has nothing to add and would just be noise.
        .accessibilityElement(children: .combine)
    }
}
