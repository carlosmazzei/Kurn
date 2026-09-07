//
//  RecordingSettingsView.swift
//  Kurn
//
//  Capture-time preferences: which microphone and quality to record at, the
//  opt-in live transcript preview, and the two privacy switches that guard
//  recordings on device and on the Lock Screen. Split into named sections
//  (Capture / Live Transcription / Playback / Privacy); where a section has
//  several controls, each one carries its own explanation under its title
//  (`SettingsRowLabel`) instead of a footer paragraph per control.
//

import SwiftUI

struct RecordingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads

    var body: some View {
        Form {
            captureSection
            liveTranscriptionSection
            playbackSection
            privacySection
        }
        .navigationTitle(NSLocalizedString("settings.recording", comment: "Recording"))
        .modelDownloadAlerts(downloads, settings: settings)
    }

    // MARK: - Capture

    @ViewBuilder
    private var captureSection: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { settings.micPickup },
                    set: { settings.micPickup = $0 }
                )
            ) {
                ForEach(MicPickup.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.mic_pickup", comment: "Microphone"),
                    detail: NSLocalizedString("settings.mic_pickup_footer", comment: "Explains pickup modes")
                )
            }
            Picker(
                selection: Binding(
                    get: { settings.audioQuality },
                    set: { settings.audioQuality = $0 }
                )
            ) {
                ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.audio_quality", comment: "Audio quality"),
                    detail: NSLocalizedString("settings.audio_quality_footer", comment: "Explains that every tier preserves speech")
                )
            }
            LabeledContent(
                NSLocalizedString("settings.audio_quality.usage", comment: "Storage per hour"),
                value: String(
                    format: NSLocalizedString("settings.audio_quality.per_hour", comment: "Size per hour of recording"),
                    AudioFileStore.formattedSize(settings.audioQuality.approximateBytesPerHour)
                )
            )
            Toggle(
                isOn: Binding(
                    get: { settings.alwaysUseBuiltInMic },
                    set: { settings.alwaysUseBuiltInMic = $0 }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.always_use_built_in_mic", comment: "Always use iPhone microphone"),
                    detail: NSLocalizedString("settings.always_use_built_in_mic_footer", comment: "Explains forcing the iPhone mic vs. being asked")
                )
            }
        } header: {
            Text(NSLocalizedString("settings.recording_section_capture", comment: "Capture"))
        }
    }

    // MARK: - Live transcription

    @ViewBuilder
    private var liveTranscriptionSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.live_transcription", comment: "Live transcription"),
                isOn: Binding(
                    get: { settings.liveTranscriptionEnabled },
                    set: { downloads.setLiveTranscriptionEnabled($0, settings: settings) }
                )
            )
            .disabled(downloads.isDownloading)
            if downloads.downloadingModel == .liveTranscriptionASR {
                ModelDownloadProgressRow(progress: downloads.downloadProgress, onCancel: downloads.cancelDownload)
            }
        } header: {
            Text(NSLocalizedString("settings.recording_section_live_transcription", comment: "Live Transcription"))
        } footer: {
            Text(NSLocalizedString("settings.live_transcription_footer", comment: "Explains the live transcription preview"))
        }
    }

    // MARK: - Playback

    // Playback-side, unlike the capture section above. It lives on this screen
    // because it is about listening to recordings, and the per-recording
    // control is the pill in the player.
    @ViewBuilder
    private var playbackSection: some View {
        Section {
            Toggle(
                NSLocalizedString("settings.playback_enhancement", comment: "Enhanced playback"),
                isOn: Binding(
                    get: { settings.playbackEnhancementEnabled },
                    set: { settings.playbackEnhancementEnabled = $0 }
                )
            )
        } header: {
            Text(NSLocalizedString("settings.recording_section_playback", comment: "Playback"))
        } footer: {
            Text(NSLocalizedString("settings.playback_enhancement_footer", comment: "Explains the enhanced playback copy"))
        }
    }

    // MARK: - Privacy

    @ViewBuilder
    private var privacySection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { settings.requireAuthForRecordings },
                    set: { settings.requireAuthForRecordings = $0 }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.require_auth_for_recordings", comment: "Require authentication for recordings"),
                    detail: NSLocalizedString("settings.require_auth_for_recordings_footer", comment: "Explains authentication and at-rest encryption")
                )
            }
            Toggle(
                isOn: Binding(
                    get: { settings.hideLiveActivityMeetingTitle },
                    set: { settings.hideLiveActivityMeetingTitle = $0 }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.hide_live_activity_meeting_title", comment: "Hide meeting title on Lock Screen"),
                    detail: NSLocalizedString("settings.hide_live_activity_meeting_title_footer", comment: "Explains Live Activity title redaction")
                )
            }
        } header: {
            Text(NSLocalizedString("settings.recording_section_privacy", comment: "Privacy"))
        }
    }
}
