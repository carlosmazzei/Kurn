import Foundation

@MainActor
protocol KnowledgeEvidenceAudio: AnyObject {
    var isPlaying: Bool { get }
    func load(fileName: String, title: String?, subtitle: String?, enhanced: Bool) async throws
    func seek(to time: TimeInterval)
    func play()
    func stop()
}

/// Loading cannot expose a remote Play command before the browser has completed
/// its post-load authorization. AudioPlayerService.play activates transport
/// only when the browser deliberately starts the authorized recording.
@MainActor
final class KnowledgeEvidenceAudioPlayer: KnowledgeEvidenceAudio {
    private let backend: any KnowledgeEvidenceAudio
    private var ownsSession = false
    var isPlaying: Bool { ownsSession && backend.isPlaying }

    init(backend: (any KnowledgeEvidenceAudio)? = nil) {
        self.backend = backend ?? KnowledgeEvidenceAudioTransport()
    }

    func load(fileName: String, title: String?, subtitle: String?, enhanced: Bool) async throws {
        ownsSession = true
        // stop() may release our session while setup is suspended. The setup
        // can still finish afterwards; return ownership so the caller's stale
        // request guard can tear down whatever it just prepared, even on error.
        defer { ownsSession = true }
        try await backend.load(fileName: fileName, title: title, subtitle: subtitle, enhanced: enhanced)
    }

    func seek(to time: TimeInterval) { if ownsSession { backend.seek(to: time) } }
    func play() { if ownsSession { backend.play() } }
    func stop() {
        guard ownsSession else { return }
        ownsSession = false
        backend.stop()
    }
}

@MainActor
private final class KnowledgeEvidenceAudioTransport: KnowledgeEvidenceAudio {
    private let player = AudioPlayerService()
    var isPlaying: Bool { player.isPlaying }

    func load(fileName: String, title: String?, subtitle: String?, enhanced: Bool) async throws {
        try await player.load(fileName: fileName, title: title, subtitle: subtitle, enhanced: enhanced, activateTransport: false)
    }

    func seek(to time: TimeInterval) { player.seek(to: time) }
    func play() { player.play() }
    func stop() { player.stop() }
}
