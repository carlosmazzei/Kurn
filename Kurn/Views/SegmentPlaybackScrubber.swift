import SwiftUI

struct SegmentPlaybackScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let playbackRate: Float
    let isEnhanced: Bool
    let enhancementProgress: Double?
    let onSeek: (TimeInterval) -> Void
    let onSkip: (TimeInterval) -> Void
    let onCycleRate: () -> Void
    let onToggleEnhancement: () -> Void

    private var playableDuration: TimeInterval { max(duration, 0) }
    private var sliderUpperBound: TimeInterval { max(playableDuration, 1) }
    private var boundedCurrentTime: TimeInterval {
        min(max(currentTime, 0), sliderUpperBound)
    }
    private var isEnhancing: Bool { enhancementProgress != nil }

    /// "1×", "1.5×", "0.5×" — `%g` drops trailing zeros and the decimal point.
    private var rateLabel: String {
        String(format: "%g×", playbackRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let fraction = sliderUpperBound > 0 ? boundedCurrentTime / sliderUpperBound : 0
                let markerWidth: CGFloat = 54
                let markerX = min(
                    max(markerWidth / 2, proxy.size.width * fraction),
                    max(markerWidth / 2, proxy.size.width - markerWidth / 2)
                )

                Text(boundedCurrentTime.clockDisplay)
                    .font(Theme.caption2Emphasized)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: markerWidth, height: 22)
                    .background(Theme.fill, in: Capsule())
                    .position(x: markerX, y: 11)
            }
            .frame(height: 24)

            Slider(
                value: Binding(
                    get: { boundedCurrentTime },
                    set: { onSeek($0) }
                ),
                in: 0...sliderUpperBound
            )
            .tint(Theme.accent)
            .disabled(playableDuration <= 0)
            // VoiceOver's Adjustable rotor acts on the slider itself, so it
            // needs its own label/value — the container's `.contain` grouping
            // below keeps this reachable but doesn't supply them on its own.
            .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
            .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")

            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "waveform" : "timer")
                    .font(Theme.caption2Emphasized)
                    .foregroundStyle(Theme.textTertiary)
                Text("0:00")
                Spacer(minLength: 8)
                Button { onSkip(-AudioPlayerService.skipInterval) } label: {
                    Image(systemName: "gobackward.15")
                        .font(Theme.captionEmphasized)
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 34)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("detail.skip_backward", comment: "Skip back 15 seconds"))
                Button { onSkip(AudioPlayerService.skipInterval) } label: {
                    Image(systemName: "goforward.15")
                        .font(Theme.captionEmphasized)
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 34)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("detail.skip_forward", comment: "Skip forward 15 seconds"))
                Button(action: onToggleEnhancement) {
                    Group {
                        if isEnhancing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.5)
                        } else {
                            Image(systemName: "sparkles")
                                .font(Theme.caption2Emphasized)
                                .foregroundStyle(isEnhanced ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .frame(minWidth: 34)
                    .padding(.vertical, 3)
                    .background(Theme.fill, in: Capsule())
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
                Button(action: onCycleRate) {
                    Text(rateLabel)
                        .font(Theme.caption2Emphasized)
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 34)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("detail.playback_speed", comment: "Playback speed"))
                .accessibilityValue(rateLabel)
                Text(playableDuration.clockDisplay)
            }
            .font(Theme.caption2)
            .foregroundStyle(Theme.textTertiary)

            if let enhancementProgress {
                EnhancementProgressView(progress: enhancementProgress)
            }
        }
        .padding(.leading, 46)
        // `.contain` rather than `.combine`: combining flattens the children into
        // one element, which makes the speed and enhancement buttons unreachable
        // to VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
        .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")
    }
}
