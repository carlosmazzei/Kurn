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

    private var layout: PlaybackScrubberLayout {
        PlaybackScrubberLayout(currentTime: currentTime, duration: duration)
    }

    private var playableDuration: TimeInterval { layout.playableDuration }
    private var sliderUpperBound: TimeInterval { layout.sliderUpperBound }
    private var boundedCurrentTime: TimeInterval { layout.boundedCurrentTime }
    private var isEnhancing: Bool { enhancementProgress != nil }

    /// "1×", "1.5×", "0.5×" — `%g` drops trailing zeros and the decimal point.
    private var rateLabel: String { PlaybackScrubberLayout.rateLabel(playbackRate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let markerWidth = CGFloat(PlaybackScrubberLayout.markerWidth)
                let markerX = CGFloat(layout.markerCenterX(trackWidth: Double(proxy.size.width)))

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
            .tint(Theme.ink)
            .disabled(playableDuration <= 0)
            // VoiceOver's Adjustable rotor acts on the slider itself, so it
            // needs its own label/value — the container's `.contain` grouping
            // below keeps this reachable but doesn't supply them on its own.
            .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
            .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    leadingTimeLabel
                    Spacer(minLength: 8)
                    transportButtons
                    Text(playableDuration.clockDisplay)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        leadingTimeLabel
                        Spacer(minLength: 8)
                        Text(playableDuration.clockDisplay)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        transportButtons
                    }
                }
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

    @ViewBuilder
    private var leadingTimeLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: isPlaying ? "waveform" : "timer")
                .font(Theme.caption2Emphasized)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text("0:00")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var transportButtons: some View {
        Button { onSkip(-AudioPlayerService.skipInterval) } label: {
            Image(systemName: "gobackward.15")
                .accessibilityHidden(true)
                .font(Theme.captionEmphasized)
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 34)
                .padding(.vertical, 3)
                .background(Theme.fill, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("detail.skip_backward", comment: "Skip back 15 seconds"))
        Button { onSkip(AudioPlayerService.skipInterval) } label: {
            Image(systemName: "goforward.15")
                .accessibilityHidden(true)
                .font(Theme.captionEmphasized)
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 34)
                .padding(.vertical, 3)
                .background(Theme.fill, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
                        .accessibilityHidden(true)
                        .font(Theme.caption2Emphasized)
                        .foregroundStyle(isEnhanced ? Theme.ink : Theme.textTertiary)
                }
            }
            .frame(minWidth: 34)
            .padding(.vertical, 3)
            .background(Theme.fill, in: Capsule())
            .frame(minWidth: 44, minHeight: 44)
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
        Button(action: onCycleRate) {
            Text(rateLabel)
                .font(Theme.caption2Emphasized)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 6)
                .frame(minWidth: 34)
                .padding(.vertical, 3)
                .background(Theme.fill, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("detail.playback_speed", comment: "Playback speed"))
        .accessibilityValue(rateLabel)
    }
}
