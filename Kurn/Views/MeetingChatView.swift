//
//  MeetingChatView.swift
//  Kurn
//
//  "Chat with your meetings": an agent that answers from the selected sources with
//  tools. Used two ways — as a tab inside a single meeting (`meeting` non-nil), and
//  as a library-wide "Ask" sheet from the meetings list (`meeting` nil). Answers
//  come from the configured summary provider, which must be a cloud provider with
//  agent support; tapping a cited timestamp calls `onJumpToTime`.
//

import AgentHarness
import Combine
import KurnCore
import SwiftData
import SwiftUI
import UIKit

struct MeetingChatView: View {
    /// The meeting to chat about, or `nil` to ask across the whole library.
    let meeting: Meeting?
    /// Invoked when the user taps a cited `[m:ss]` in an answer; the host seeks that absolute
    /// meeting time. Per-meeting scope only.
    var onJumpToTime: ((TimeInterval) -> Void)?

    /// The app-wide owner of conversations (NH05): a run outlives this view. Optional only so a
    /// view built outside the app environment still works, with a conversation of its own.
    @Environment(ChatConversationHost.self) private var conversations: ChatConversationHost?
    @State private var detached = MeetingChatViewModel()

    var body: some View {
        MeetingChatConversationView(meeting: meeting, onJumpToTime: onJumpToTime,
                                    vm: conversations?.conversation(for: meeting?.id) ?? detached)
    }
}

/// The conversation itself, rendering whichever retained view model `MeetingChatView` resolved.
struct MeetingChatConversationView: View {
    let meeting: Meeting?
    var onJumpToTime: ((TimeInterval) -> Void)?
    @Bindable var vm: MeetingChatViewModel

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var showingHistory = false
    @State private var showingSources = false
    @Query(sort: \Meeting.createdAt, order: .reverse) private var sourceMeetings: [Meeting]
    @Query(sort: \Tag.name) private var sourceTags: [Tag]
    @Query(sort: \Folder.name) private var sourceFolders: [Folder]
    /// Measured height of the floating composer card. The transcript scrolls
    /// beneath it (see `conversation`), so scrolling to the latest message has
    /// to clear this much on top of the bottom safe area.
    @State private var composerHeight: CGFloat = 0
    /// Whether the reader is at the end of the conversation (NH08): turns added while they read
    /// older messages do not move them.
    @State private var scrollFollowing = ChatScrollFollowing()
    /// Set by `send`, so the reader's own question is always brought into view.
    @State private var sentQuestion = false
    /// The question being labelled, and the label being typed (NH09).
    @State private var labelTarget: UUID?
    @State private var labelText = ""

    var body: some View {
        VStack(spacing: 0) {
            if !usesHarness {
                ChatArtifactProviderNotice()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            if !settings.semanticSearchEnabled {
                disabledState
            } else {
                conversation
            }
        }
        // The system background, not `Theme.background`: the keyboard's glass
        // is tuned to blend with the system tone, and a custom near-black
        // behind it reads as a lighter band where the keyboard begins.
        // `MeetingDetailView` switches its own backdrop to match on this tab.
        .background(Color(uiColor: .systemBackground))
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
        // Typing a label needs a text field, which only the system alert offers.
        .alert(NSLocalizedString("chat.branch.label", comment: "Label this question"),
               isPresented: Binding(get: { labelTarget != nil }, set: { if !$0 { labelTarget = nil } })) {
            TextField(NSLocalizedString("chat.branch.label_placeholder", comment: "Label text"), text: $labelText)
            Button(NSLocalizedString("common.save", comment: "Save")) {
                if let target = labelTarget { vm.label(turnID: target, as: labelText) }
                labelTarget = nil
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) { labelTarget = nil }
        }
        .toolbar { historyToolbar }
        .sheet(isPresented: $showingHistory) {
            ChatSessionListView(
                sessions: vm.pastSessions(),
                currentSessionID: vm.currentSessionID,
                onSelect: { vm.load(session: $0) },
                onDelete: { vm.delete($0) },
                onRename: { vm.rename($0, to: $1) }
            )
        }
        .sheet(isPresented: $showingSources) {
            ChatSourceSheet(meeting: meeting, scope: Binding(get: { vm.scope }, set: { vm.updateScope($0) }))
        }
        // Wiring the persistence scope is cheap and idempotent, so redoing it
        // on every appearance (rather than a one-shot `.task`) needs no extra
        // state to guard against `meeting`/`modelContext` changing under it.
        .onAppear {
            vm.configure(meeting: meeting, modelContext: modelContext)
            takeRestoredDraft()
        }
        // Queued input a stop or a failed run did not answer comes back into the composer (NH08).
        .onChange(of: vm.restoredDraft) { _, _ in takeRestoredDraft() }
        // A reopened conversation a dead process interrupted is resumed once, with the provider
        // and model the chat uses now (`MeetingChatViewModel.resumeInterruptedRun`).
        .onChange(of: vm.interruptedResume?.runID) { _, runID in
            guard runID != nil, canChat, sourceValidation == nil else { return }
            let provider = settings.aiProvider
            vm.resumeInterruptedRun(provider: provider, model: settings.summaryModel(for: provider))
        }
    }

    /// "New conversation" and "History" — mirrors Claude's own chat history
    /// affordances: start fresh, or reopen a saved one. Shown regardless of
    /// `canChat` so past conversations stay reachable even if semantic search
    /// is currently off or unindexed.
    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
        if usesHarness {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSources = true } label: {
                    Label(sourceSummary, systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                        .frame(minHeight: 44)
                }
                .disabled(vm.isResponding)
                .accessibilityLabel(NSLocalizedString("chat.sources.title", comment: "Sources") + ": " + sourceSummary)
                .accessibilityIdentifier("chat.sources.open")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel(NSLocalizedString("chat.history.button", comment: "Open chat history"))
            Button {
                vm.duplicateConversation()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .disabled(!vm.canChangeBranch)
            .accessibilityLabel(NSLocalizedString("chat.branch.duplicate", comment: "Duplicate this conversation"))
            .accessibilityIdentifier("chat.branch.duplicate")
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
                        MeetingChatTurnView(turn: turn, isStreaming: isStreaming(turn), isMeetingScope: meeting != nil,
                                            meetingTitles: Dictionary(uniqueKeysWithValues: sourceMeetings.map { ($0.id, $0.title) }),
                                            documentTitles: Dictionary(uniqueKeysWithValues: vm.artifacts.map { ($0.id, $0.title) }),
                                            artifacts: vm.artifacts, artifactSession: vm.artifactSession,
                                            onJumpToTime: onJumpToTime, branch: branchActions(for: turn))
                            .id(turn.id)
                    }
                    if let usage = vm.branches.usageSummary, !vm.isResponding {
                        Text(usage)
                            .font(Theme.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityIdentifier("chat.branch.usage")
                    }
                    if vm.isResponding { respondingRow }
                    if let question = vm.retryableQuestion {
                        if vm.retryableQuestionWasInterrupted {
                            Text(NSLocalizedString("chat.run.interrupted", comment: "A reply cut off when the app closed"))
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityIdentifier("chat.run_interrupted")
                        } else if vm.replyWasStopped {
                            // The stop is confirmed only once the run settled.
                            Text(NSLocalizedString("chat.run.stopped", comment: "The person stopped this reply"))
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityIdentifier("chat.run_stopped")
                        }
                        retryRow(question: question)
                    }
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
            .onScrollGeometryChange(for: ChatScrollFollowing.self) { geometry in
                var following = ChatScrollFollowing()
                following.observe(contentOffsetY: geometry.contentOffset.y, visibleHeight: geometry.containerSize.height,
                                  contentHeight: geometry.contentSize.height)
                return following
            } action: { _, following in scrollFollowing = following }
            .onChange(of: vm.turns.count) { _, _ in
                guard let last = vm.turns.last else { return }
                let ownQuestion = sentQuestion && last.role == .user
                sentQuestion = false
                guard scrollFollowing.follows(newTurnIsOwnQuestion: ownQuestion) else { return }
                if reduceMotion {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
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

    /// The branch actions of a saved question (NH09); none for a reply or an unsaved question.
    private func branchActions(for turn: MeetingChatViewModel.Turn) -> ChatTurnBranchActions? {
        guard turn.role == .user, vm.branches.entryIDs[turn.id] != nil else { return nil }
        return ChatTurnBranchActions(versions: vm.branches.alternatives[turn.id], label: vm.branches.labels[turn.id],
                                     isEnabled: vm.canChangeBranch,
                                     showVersion: { vm.showVersion(of: turn.id, offset: $0) },
                                     fork: { vm.fork(from: turn.id) },
                                     editLabel: {
                                         labelText = vm.branches.labels[turn.id] ?? ""
                                         labelTarget = turn.id
                                     })
    }

    /// Whether `turn` is the reply currently streaming in, so its bubble gets
    /// a trailing cursor instead of reading as a finished answer.
    private func isStreaming(_ turn: MeetingChatViewModel.Turn) -> Bool {
        vm.isResponding && turn.role == .assistant && turn.id == vm.turns.last?.id
    }

    /// The running row shown while the agent works, with the turn's live usage once reported.
    private var respondingRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView().accessibilityHidden(true)
                Text(vm.phase.statusText(retryDelaySeconds: vm.runProgress.retryDelaySeconds))
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.run_status")
            }
            if let turn = vm.turns.last, turn.role == .assistant, let usage = turn.usage {
                Text(MeetingChatTurnView.usageCaptionText(usage: usage, costUSD: turn.costUSD, elapsedSeconds: nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.live_usage")
            }
        }
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
                    .font(.caption)
                    .accessibilityHidden(true)
                Text(NSLocalizedString("chat.retry", comment: "Retry a cancelled or failed question"))
                    .font(Theme.footnote)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canChat || sourceValidation != nil)
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
            if usesHarness, let sourceValidation { ChatSourceValidationView(validation: sourceValidation) }
            if !vm.queued.isEmpty {
                ChatQueuedInputView(queued: vm.queued,
                                    edit: { item in Task { await vm.editQueued(item) } },
                                    remove: { item in Task { await vm.removeQueued(item.id) } })
            }
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
                if canQueue { queueButtons } else { modelChip }
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

    /// While a reply runs, a typed message can steer it after its current step, or wait until
    /// it finishes (NH08).
    @ViewBuilder
    private var queueButtons: some View {
        Button(NSLocalizedString("chat.queue.steer", comment: "Steer the running reply")) { queueInput(.steering) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("chat.queue.steer")
        Button(NSLocalizedString("chat.queue.follow_up", comment: "Send after this task")) { queueInput(.followUp) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("chat.queue.follow_up")
    }

    private var canQueue: Bool {
        vm.isResponding && vm.phase != .cancelling && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Queues the composer's text; it stays in the composer when the queue refuses it.
    private func queueInput(_ kind: AgentInputQueue.Kind) {
        let text = input
        input = ""
        Task { if !(await vm.queue(text, as: kind)) { input = text } }
    }

    private func takeRestoredDraft() {
        guard let draft = vm.restoredDraft else { return }
        vm.restoredDraft = nil
        input = input.isEmpty ? draft : input + "\n\n" + draft
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
            // Fixed-size glyph in a fixed 36x36 circle, same reasoning as
            // RecorderView's transport controls: letting the icon scale with
            // Dynamic Type would overflow the circle rather than help legibility.
            Button { vm.cancel() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.warning, in: Circle())
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A stop is a request; the reply settles before the composer comes back.
            .disabled(vm.phase == .cancelling)
            .accessibilityLabel(NSLocalizedString("chat.stop", comment: "Stop"))
            .accessibilityIdentifier("chat.stop")
        } else {
            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? .white : Theme.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(canSend ? Theme.accent : Theme.fill, in: Circle())
                    .padding(4)
                    .contentShape(Rectangle())
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

    private var canChat: Bool {
        ChatSourcePresentation.canChat(enabled: settings.semanticSearchEnabled, usesHarness: usesHarness)
    }
    private var canSend: Bool {
        canChat && !vm.isResponding && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sourceValidation == nil
    }

    /// Chat runs only on providers with agent support; on-device shows the cloud-provider notice.
    private var usesHarness: Bool { settings.aiProvider.kind.supportsAgentChat }

    private var resolvedMeetingIDs: Set<UUID> {
        Set(SourceScopeResolver.resolve(vm.scope, meetings: sourceMeetings, tags: sourceTags, folders: sourceFolders).meetings.map(\.id))
    }

    private var sourceValidation: ChatSourceScopeEditor.Validation? {
        ChatSourcePresentation.validation(vm.scope, resolvedMeetingIDs: resolvedMeetingIDs, wikiEnabled: settings.wikiEnabled)
    }

    private var sourceSummary: String {
        ChatSourcePresentation.summary(vm.scope, resolvedMeetingIDs: resolvedMeetingIDs, wikiEnabled: settings.wikiEnabled) {
            NSLocalizedString($0, comment: "Chat sources")
        }
    }

    private func send() {
        sentQuestion = true
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
        guard canChat, sourceValidation == nil else { return }
        let provider = settings.aiProvider
        vm.send(question: question, provider: provider, model: settings.summaryModel(for: provider))
    }
}
