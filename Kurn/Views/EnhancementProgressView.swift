//
//  EnhancementProgressView.swift
//  Kurn
//
//  Shared progress presentation used both inside a loaded playback scrubber and
//  directly on a recording row after navigation has unloaded its local player.
//

import SwiftUI

struct EnhancementProgressView: View {
    let progress: Double

    var body: some View {
        let clamped = min(1, max(0, progress))
        let percent = Int((clamped * 100).rounded())
        ProgressView(value: clamped) {
            Text(
                String(
                    format: NSLocalizedString(
                        "detail.enhancing_audio_progress",
                        comment: "Enhancing audio with percent"
                    ),
                    percent
                )
            )
            .font(.caption2)
            .foregroundStyle(Theme.textTertiary)
        }
        .progressViewStyle(.linear)
        .tint(Theme.accent)
        .animation(.easeInOut(duration: 0.25), value: clamped)
    }
}
