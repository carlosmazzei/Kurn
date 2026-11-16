import KurnCore
import SwiftData
import SwiftUI

/// The app-wide capture action, shared by legacy toolbars and the floating
/// root button. Reopening a minimized session never creates a second meeting.
struct RecordingActionButton: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingSessionController.self) private var session
    @State private var saveError: AppError?

    private var title: String {
        guard session.isActive else { return NSLocalizedString("meetings.record", comment: "Record") }
        return session.isPaused
            ? NSLocalizedString("recorder.mini.paused", comment: "Mini recorder bar: paused")
            : NSLocalizedString("recorder.mini.recording", comment: "Mini recorder bar: recording")
    }

    private var symbol: String {
        guard session.isActive else { return "record.circle.fill" }
        return session.isPaused ? "pause.circle.fill" : "waveform"
    }

    var body: some View {
        Button(action: startRecording) { Label(title, systemImage: symbol) }
            .tint(Theme.accent)
            .buttonStyle(.glassProminent)
            .accessibilityLabel(title)
            .accessibilityHint(session.isActive
                ? NSLocalizedString("recorder.mini.hint", comment: "Opens the full recorder") : "")
            .accessibilityIdentifier("meetings.record")
            .errorAlert($saveError)
    }

    private func startRecording() {
        guard !session.isActive else { session.expand(); return }
        do throws(AppError) {
            let meeting = try MeetingLibrary(context: modelContext)
                .createMeeting(title: "", language: settings.defaultLanguage)
            session.begin(meeting: meeting)
        } catch { saveError = error }
    }
}
