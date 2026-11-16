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
    private let player = AudioPlayerService()
    var isPlaying: Bool { player.isPlaying }

    func load(fileName: String, title: String?, subtitle: String?, enhanced: Bool) async throws {
        try await player.load(fileName: fileName, title: title, subtitle: subtitle, enhanced: enhanced, activateTransport: false)
    }

    func seek(to time: TimeInterval) { player.seek(to: time) }
    func play() { player.play() }
    func stop() { player.stop() }
}
