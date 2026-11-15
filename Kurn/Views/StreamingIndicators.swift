//
//  StreamingIndicators.swift
//  Kurn
//
//  The two cues shared by everything that streams a model's output into
//  view — the chat's reply and the summary's live draft: the "thinking for
//  Ns" row shown before the first fragment arrives, and the blinking cursor
//  trailing text that is still being written. Split out of
//  `MeetingChatView` so both screens use the same ones.
//

import SwiftUI

/// A small blinking bar trailing a streaming reply's text, the same "still
/// typing" cue Claude/ChatGPT-style chat UIs use. Purely decorative — the
/// growing text and the "reasoning" row above it already convey progress to
/// VoiceOver, so this renders solid (no blink) rather than looping under
/// Reduce Motion, matching `RecorderView`'s `PulsingDot`.
struct StreamingCursor: View {
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

/// The "thinking" row shown before a summary's first fragment arrives: a generic label plus a
/// live elapsed-time readout, the same shape Claude's own "Thinking for Ns" indicator uses so a
/// long wait still reads as active work. The label "breathes" — a slow, looping opacity pulse —
/// under normal motion; Reduce Motion keeps it at full opacity and drops the pulse entirely,
/// matching `StreamingCursor`.
struct ThinkingRow: View {
    let startedAt: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    private var label: String { NSLocalizedString("chat.thinking", comment: "Assistant thinking") }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis")
                .font(.caption)
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
