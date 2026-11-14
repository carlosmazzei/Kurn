import Foundation
import KurnCore
import SwiftUI

struct MeetingChatTurnView: View {
    let turn: MeetingChatViewModel.Turn
    let isStreaming: Bool
    let isMeetingScope: Bool
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]
    var artifacts: [ChatDocumentArtifact] = []
    var artifactSession: ChatSession?
    var onJumpToTime: ((TimeInterval) -> Void)?
    var branch: ChatTurnBranchActions?

    var body: some View {
        switch turn.role {
        case .user:
            VStack(alignment: .leading, spacing: 8) {
                if let label = branch?.label {
                    HStack { Spacer(minLength: 40); ChatTurnLabel(text: label) }
                }
                HStack {
                    Spacer(minLength: 40)
                    Text(turn.text)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contextMenu { branchMenu }
                }
                if branch?.isLeftOut == true {
                    HStack {
                        Spacer(minLength: 40)
                        Label(NSLocalizedString("chat.context.left_out", comment: "This exchange is left out of later answers"),
                              systemImage: "eye.slash")
                            .font(Theme.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("chat.context.left_out")
                    }
                }
                if let branch, let versions = branch.versions {
                    HStack {
                        Spacer(minLength: 40)
                        ChatVersionSwitcher(versions: versions, isEnabled: branch.isEnabled, showVersion: branch.showVersion)
                    }
                }
                ChatStepTimelineView(steps: turn.steps, isRunning: false,
                                     meetingTitles: meetingTitles, documentTitles: documentTitles)
                agentFooter
            }
        case .assistant, .system:
            VStack(alignment: .leading, spacing: 8) {
                ChatStepTimelineView(steps: turn.steps, isRunning: isStreaming,
                                     meetingTitles: meetingTitles, documentTitles: documentTitles)
                if !turn.text.isEmpty {
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
                        if isStreaming {
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
                    .kurnAnimation(.easeInOut(duration: 0.2), value: isStreaming)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.separator, lineWidth: 1)
                    )
                }
                agentFooter
                if isMeetingScope {
                    // Make the [m:ss] timestamps the model cited tappable.
                    timestampChips(ChatTimestampCitations.times(in: turn.text))
                }
                usageCaption(turn)
            }
        }
    }

    /// Fork and label, offered on a saved question while no reply runs (NH09).
    @ViewBuilder
    private var branchMenu: some View {
        if let branch, branch.isEnabled {
            Button(action: branch.regenerate) {
                Label(NSLocalizedString("chat.branch.regenerate", comment: "Ask this question again for another answer"),
                      systemImage: "arrow.clockwise")
            }
            Button(action: branch.edit) {
                Label(NSLocalizedString("chat.branch.edit", comment: "Edit this question and ask it again"), systemImage: "pencil")
            }
            Button(action: branch.fork) {
                Label(NSLocalizedString("chat.branch.fork", comment: "Fork from this question"), systemImage: "arrow.triangle.branch")
            }
            Button(action: branch.editLabel) {
                Label(NSLocalizedString("chat.branch.label", comment: "Label this question"), systemImage: "bookmark")
            }
            if branch.isLeftOut {
                Button { branch.setLeftOut(false) } label: {
                    Label(NSLocalizedString("chat.context.include", comment: "Include this exchange in later answers again"),
                          systemImage: "eye")
                }
            } else {
                Button { branch.setLeftOut(true) } label: {
                    Label(NSLocalizedString("chat.context.leave_out", comment: "Leave this exchange out of later answers"),
                          systemImage: "eye.slash")
                }
            }
        }
    }

    private var agentFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = ChatRunNotice.text(steps: turn.steps, hasAnswer: turn.role == .assistant,
                                              localize: { NSLocalizedString($0, comment: "Run limit") }) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("chat.limit.notice")
            }
            ForEach(turn.artifacts) { reference in
                if let artifact = ChatArtifactPresentation.latest(reference, in: artifacts), let artifactSession {
                    ChatArtifactCard(reference: reference, artifact: artifact, session: artifactSession)
                }
            }
        }
    }

    /// Token count, estimated cost, and generation time for a finished reply
    /// — shown only once the answer is confirmed (never mid-stream) and only
    /// when the provider actually reported usage.
    @ViewBuilder
    private func usageCaption(_ turn: MeetingChatViewModel.Turn) -> some View {
        if !isStreaming, let usage = turn.usage {
            Text(Self.usageCaptionText(usage: usage, costUSD: turn.costUSD, elapsedSeconds: turn.elapsedSeconds))
                .font(Theme.caption2)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    static func usageCaptionText(usage: TokenUsage, costUSD: Double?, elapsedSeconds: TimeInterval?) -> String {
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
                                Image(systemName: "clock").font(.caption2)
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
}
