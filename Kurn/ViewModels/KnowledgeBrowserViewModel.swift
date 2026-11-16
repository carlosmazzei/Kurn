import Foundation
import Observation

@MainActor
protocol KnowledgeEvidenceAudio: AnyObject {
    var isPlaying: Bool { get }
    func load(fileName: String, title: String?, subtitle: String?, enhanced: Bool) async throws
    func seek(to time: TimeInterval)
    func play()
    func stop()
}

extension AudioPlayerService: KnowledgeEvidenceAudio {}

@MainActor
@Observable
final class KnowledgeBrowserViewModel {
    typealias Reader = @MainActor () async throws -> KnowledgeBrowserRead
    private(set) var state: KnowledgeBrowserLoadState = .idle
    private(set) var isLoadingAudio = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private let audio: any KnowledgeEvidenceAudio

    init(audio: any KnowledgeEvidenceAudio = AudioPlayerService()) { self.audio = audio }

    var isPlaying: Bool { audio.isPlaying }

    func invalidate() {
        requestID = UUID()
        state = .idle
        audio.stop()
    }

    func load(meetingIDs: Set<UUID>, selection: KnowledgeEvidenceSelection?, isEnabled: () -> Bool, reader: Reader) async {
        invalidate()
        let request = requestID
        guard isEnabled(), !Task.isCancelled else { return }
        state = .loading
        do {
            let read = try await reader()
            guard requestID == request else { return }
            guard !Task.isCancelled, isEnabled() else { invalidate(); return }
            guard Self.matches(read, meetingIDs: meetingIDs, selection: selection) else { state = .unavailable; return }
            state = .loaded(read)
        } catch is CancellationError {
            if requestID == request { invalidate() }
        } catch {
            if requestID == request { state = isEnabled() && !Task.isCancelled ? .unavailable : .idle }
        }
    }

    func presentation(meetingIDs: Set<UUID>, selection: KnowledgeEvidenceSelection?) -> KnowledgeBrowserLoadState {
        if case let .loaded(read) = state, !Self.matches(read, meetingIDs: meetingIDs, selection: selection) { return .idle }
        return state
    }

    /// Revalidate before loading and again after asynchronous audio setup.
    /// Invalidation stops playback and prevents a suspended load from starting
    /// old audio. A pending setup owns the player until it has returned.
    func playEvidence(isEnabled: () -> Bool, reader: Reader) async {
        guard !isLoadingAudio, isEnabled(), case let .loaded(read) = state, let source = read.selectedEvidence else { return }
        isLoadingAudio = true
        defer { isLoadingAudio = false }
        let request = requestID
        do {
            let before = try await reader()
            guard requestID == request, !Task.isCancelled, isEnabled(), before.meetingIDs == read.meetingIDs,
                  before.selectedEvidence == source else { refusePlayback(request: request); return }
            // Audio setup may publish Now Playing metadata before it returns.
            // Keep source names out of that surface until reauthorization.
            try await audio.load(fileName: source.fileName, title: nil, subtitle: nil, enhanced: false)
            let after = try await reader()
            guard requestID == request, !Task.isCancelled, isEnabled(), after.meetingIDs == read.meetingIDs,
                  after.selectedEvidence == source else { refusePlayback(request: request); return }
            audio.seek(to: Double(source.evidence.startMs) / 1_000)
            audio.play()
        } catch {
            audio.stop()
            if requestID == request { invalidate(); state = .unavailable }
        }
    }

    func stopAudio() { audio.stop() }

    private func refusePlayback(request: UUID) {
        audio.stop()
        if requestID == request { invalidate(); state = .unavailable }
    }

    private static func matches(_ read: KnowledgeBrowserRead, meetingIDs: Set<UUID>, selection: KnowledgeEvidenceSelection?) -> Bool {
        guard read.meetingIDs == meetingIDs else { return false }
        switch (selection, read.selectedEvidence) {
        case (nil, nil): return true
        case let (selection?, source?):
            return source.entry.fact.id == selection.assertionID && source.evidence.id == selection.evidenceID
                && meetingIDs.contains(source.entry.fact.source.meetingID)
        default: return false
        }
    }
}
