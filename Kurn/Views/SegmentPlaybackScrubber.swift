import SwiftUI

/// The loaded recording's player card content: elapsed/remaining times, the
/// scrub slider, and one transport row (speed, ±15 s, play/pause, enhanced
/// voice). Lives on the Audio tab directly under the Recordings section;
/// playback logic stays in `AudioPlayerService` — this only renders it.
struct SegmentPlaybackScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let playbackRate: Float
    let isEnhanced: Bool
    let enhancementProgress: Double?
    let onSeek: (TimeInterval) -> Void
    let onSkip: (TimeInterval) -> Void
    let onTogglePlay: () -> Void
    let onCycleRate: () -> Void
    let onToggleEnhancement: () -> Void

    private var layout: PlaybackScrubberLayout {
        PlaybackScrubberLayout(currentTime: currentTime, duration: duration)
    }

    private var playableDuration: TimeInterval { layout.playableDuration }
    private var sliderUpperBound: TimeInterval { layout.sliderUpperBound }
    private var boundedCurrentTime: TimeInterval { layout.boundedCurrentTime }
    private var remainingTime: TimeInterval { max(0, playableDuration - boundedCurrentTime) }
    private var isEnhancing: Bool { enhancementProgress != nil }

    /// "1×", "1.5×", "0.5×" — `%g` drops trailing zeros and the decimal point.
    private var rateLabel: String { PlaybackScrubberLayout.rateLabel(playbackRate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(boundedCurrentTime.clockDisplay)
                Spacer(minLength: 8)
                Text("-\(remainingTime.clockDisplay)")
            }
            .font(Theme.footnote)
            .monospacedDigit()
            .foregroundStyle(Theme.textSecondary)

            Slider(
                value: Binding(
                    get: { boundedCurrentTime },
                    set: { onSeek($0) }
                ),
                in: 0...sliderUpperBound
            )
            .tint(Theme.ink)
            .disabled(playableDuration <= 0)
            // VoiceOver's Adjustable rotor acts on the slider itself, so it
            // needs its own label/value — the container's `.contain` grouping
            // below keeps this reachable but doesn't supply them on its own.
            .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
            .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")

            HStack(spacing: 12) {
                rateChip
                skipButton(interval: -AudioPlayerService.skipInterval,
                           icon: "gobackward.15",
                           label: NSLocalizedString("detail.skip_backward", comment: "Skip back 15 seconds"))
                togglePlayButton
                skipButton(interval: AudioPlayerService.skipInterval,
                           icon: "goforward.15",
                           label: NSLocalizedString("detail.skip_forward", comment: "Skip forward 15 seconds"))
                voiceChip
            }
            .frame(maxWidth: .infinity)

            if let enhancementProgress {
                EnhancementProgressView(progress: enhancementProgress)
            }
        }
        // `.contain` rather than `.combine`: combining flattens the children into
        // one element, which makes the speed and enhancement buttons unreachable
        // to VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
        .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")
    }

    private var rateChip: some View {
        Button(action: onCycleRate) {
            Text(rateLabel)
                .font(Theme.footnoteEmphasized)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Theme.fill, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("detail.playback_speed", comment: "Playback speed"))
        .accessibilityValue(rateLabel)
    }

    private func skipButton(interval: TimeInterval, icon: String, label: String) -> some View {
        Button { onSkip(interval) } label: {
            Image(systemName: icon)
                .accessibilityHidden(true)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var togglePlayButton: some View {
        Button(action: onTogglePlay) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.onInk)
                .frame(width: 46, height: 46)
                .background(Theme.ink, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying
            ? NSLocalizedString("detail.pause_recording", comment: "Pause recording")
            : NSLocalizedString("detail.play_recording", comment: "Play recording"))
    }

    /// The "Voice" chip: enhanced audio when a rendered copy exists, ink-filled
    /// while it is on.
    private var voiceChip: some View {
        Button(action: onToggleEnhancement) {
            HStack(spacing: 5) {
                if isEnhancing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(.caption, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(NSLocalizedString("detail.voice", comment: "Voice"))
                    .font(Theme.footnoteEmphasized)
            }
            .foregroundStyle(isEnhanced ? Theme.onInk : Theme.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(isEnhanced ? Theme.ink : Theme.fill, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEnhancing)
        .accessibilityLabel(NSLocalizedString("detail.playback_enhancement", comment: "Enhanced audio"))
        .accessibilityValue(
            isEnhancing
                ? NSLocalizedString("detail.enhancing_audio", comment: "Enhancing audio")
                : (isEnhanced
                    ? NSLocalizedString("common.on", comment: "On")
                    : NSLocalizedString("common.off", comment: "Off"))
        )
    }
}
