//
//  RecordingSettingsView.swift
//  Kurn
//
//  Capture-time preferences: which microphone and quality to record at, the
//  opt-in live transcript preview, and the two privacy switches that guard
//  recordings on device and on the Lock Screen.
//

import SwiftUI

struct RecordingSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads

    var body: some View {
        Form {
            Section {
                Picker(
                    NSLocalizedString("settings.mic_pickup", comment: "Microphone"),
                    selection: Binding(
                        get: { settings.micPickup },
                        set: { settings.micPickup = $0 }
                    )
                ) {
                    ForEach(MicPickup.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(
                    NSLocalizedString("settings.audio_quality", comment: "Audio quality"),
                    selection: Binding(
                        get: { settings.audioQuality },
                        set: { settings.audioQuality = $0 }
                    )
                ) {
                    ForEach(AudioQuality.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle(
                    NSLocalizedString("settings.always_use_built_in_mic", comment: "Always use iPhone microphone"),
                    isOn: Binding(
                        get: { settings.alwaysUseBuiltInMic },
                        set: { settings.alwaysUseBuiltInMic = $0 }
                    )
                )
                Toggle(
                    NSLocalizedString("settings.live_transcription", comment: "Live transcription"),
                    isOn: Binding(
                        get: { settings.liveTranscriptionEnabled },
                        set: { downloads.setLiveTranscriptionEnabled($0, settings: settings) }
                    )
                )
                .disabled(downloads.isDownloading)
                if downloads.downloadingModel == .liveTranscriptionASR {
                    ModelDownloadProgressRow()
                }
                Toggle(
                    NSLocalizedString("settings.require_auth_for_recordings", comment: "Require authentication for recordings"),
                    isOn: Binding(
                        get: { settings.requireAuthForRecordings },
                        set: { settings.requireAuthForRecordings = $0 }
                    )
                )
                Toggle(
                    NSLocalizedString("settings.hide_live_activity_meeting_title", comment: "Hide meeting title on Lock Screen"),
                    isOn: Binding(
                        get: { settings.hideLiveActivityMeetingTitle },
                        set: { settings.hideLiveActivityMeetingTitle = $0 }
                    )
                )
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("settings.mic_pickup_footer", comment: "Explains pickup modes"))
                    Text(NSLocalizedString("settings.always_use_built_in_mic_footer", comment: "Explains forcing the iPhone mic vs. being asked"))
                    Text(NSLocalizedString("settings.require_auth_for_recordings_footer", comment: "Explains authentication and at-rest encryption"))
                    Text(NSLocalizedString("settings.hide_live_activity_meeting_title_footer", comment: "Explains Live Activity title redaction"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.recording", comment: "Recording"))
        .modelDownloadAlerts(downloads, settings: settings)
    }
}
