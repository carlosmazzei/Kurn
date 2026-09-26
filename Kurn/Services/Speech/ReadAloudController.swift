//
//  ReadAloudController.swift
//  Kurn
//
//  Reads a summary, a meeting's wiki article or a generated document aloud.
//
//  One instance for the whole app (`shared`, like `RecordingCommandRouter`):
//  there is one audio route, so there is one thing being read, and a button on
//  any screen needs to know whether *its* text is the one playing. Being a
//  singleton rather than an environment value also keeps it reachable from the
//  Settings screen hosted in the security cover window, which inherits no
//  environment.
//
//  The provider comes from `AppSettings.readAloud`: the system voice by
//  default, so a fresh install reads offline and sends nothing anywhere, or a
//  cloud voice the user chose in Settings — the same opt-in-before-network
//  rule every other cloud feature here follows.
//
//  Playback is a media session like `AudioPlayerService`'s: `.spokenAudio`,
//  Now Playing metadata and Lock Screen controls (skip moves by paragraph),
//  pause on interruption and when headphones disappear, and the session is
//  handed back with `.notifyOthersOnDeactivation` when reading ends.
//

import AVFoundation
import Foundation
import KurnCore
import Observation

/// Something that can be read aloud. `id` identifies the content ("which
/// button is playing"), `ownerID` the screen's subject (a meeting or a
/// document) so leaving that screen can stop only what belongs to it.
struct ReadAloudItem: Equatable, Sendable {
    let id: String
    let ownerID: UUID
    let title: String
    let subtitle: String
    let spokenText: String
}

@MainActor
@Observable
final class ReadAloudController: NSObject {
    static let shared = ReadAloudController()

    enum Phase: Equatable {
        case idle
        /// Waiting for the first audio (a cloud request in flight).
        case preparing
        case speaking
        case paused
    }

    private(set) var phase: Phase = .idle
    private(set) var item: ReadAloudItem?
    private(set) var chunkIndex = 0
    private(set) var chunkCount = 0
    /// The last failure and the item it belongs to, so only that item's
    /// control shows it.
    private(set) var failure: (itemID: String, error: AppError)?

    var isActive: Bool { phase != .idle }

    @ObservationIgnored private var engine: ReadAloudEngine?
    @ObservationIgnored private var chunks: [String] = []
    @ObservationIgnored private let nowPlaying = NowPlayingController()
    @ObservationIgnored private var holdsAudioSession = false

    override init() {
        super.init()
        registerNotifications()
    }

    // MARK: - Queries

    func phase(for itemID: String) -> Phase {
        item?.id == itemID ? phase : .idle
    }

    func error(for itemID: String) -> AppError? {
        failure?.itemID == itemID ? failure?.error : nil
    }

    func clearError() { failure = nil }

    // MARK: - Transport

    /// Start `item`, or pause/resume it when it is already the one reading.
    func toggle(_ item: ReadAloudItem, settings: AppSettings) {
        if self.item?.id == item.id, isActive {
            if phase == .paused { resume() } else { pause() }
        } else {
            start(item, settings: settings)
        }
    }

    func start(_ item: ReadAloudItem, settings: AppSettings) {
        let provider = settings.speechProvider
        let chunks = SpokenText.chunks(item.spokenText, maxCharacters: provider.maxSpeechCharacters)
        guard !chunks.isEmpty else {
            stop()
            failure = (item.id, .speechSynthesisFailed(
                NSLocalizedString("read_aloud.error.empty", comment: "Nothing to read")
            ))
            return
        }
        // Keep the session across a switch from one text to another, so a
        // paused music app does not resume for the length of the swap.
        let hadAudioSession = holdsAudioSession
        stop(releasingAudioSession: false)
        failure = nil
        let language = SystemSpeechEngine.dominantLanguage(of: item.spokenText)
        let engine: ReadAloudEngine
        do {
            engine = try Self.makeEngine(provider: provider, preferences: settings.readAloud, languageCode: language)
            try activateAudioSession()
        } catch {
            if hadAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            fail(item.id, error)
            return
        }
        AppLog.generation.atNotice.notice("ReadAloud: start provider=\(provider.displayName, privacy: .public) chunks=\(chunks.count, privacy: .public)")
        engine.onChunkStarted = { [weak self] index in self?.chunkStarted(index) }
        engine.onFinished = { [weak self] in self?.stop() }
        engine.onFailed = { [weak self] error in
            guard let self, let id = self.item?.id else { return }
            self.stop()
            self.failure = (id, error)
        }
        self.engine = engine
        self.chunks = chunks
        self.item = item
        chunkIndex = 0
        chunkCount = chunks.count
        phase = .preparing
        nowPlaying.activate(handlers: makeHandlers())
        publishNowPlaying()
        engine.start(chunks, at: 0)
    }

    func pause() {
        guard phase == .speaking || phase == .preparing else { return }
        engine?.pause()
        phase = .paused
        publishNowPlaying()
    }

    func resume() {
        guard phase == .paused else { return }
        engine?.resume()
        phase = .speaking
        publishNowPlaying()
    }

    /// Move by whole chunks (paragraph-sized): the unit a listener skips by,
    /// since the text has no timeline to scrub.
    func skip(by offset: Int) {
        guard isActive, let engine, !chunks.isEmpty else { return }
        let target = min(max(0, chunkIndex + offset), chunks.count - 1)
        chunkIndex = target
        phase = .preparing
        engine.start(chunks, at: target)
        publishNowPlaying()
    }

    /// Stop reading. `releasingAudioSession: false` is for handing the route
    /// straight to other in-app audio (recording playback): deactivating the
    /// shared session under a playing `AVAudioPlayer` would stop it too.
    func stop(releasingAudioSession: Bool = true) {
        engine?.stop()
        engine = nil
        chunks = []
        item = nil
        chunkIndex = 0
        chunkCount = 0
        guard phase != .idle || holdsAudioSession else { return }
        phase = .idle
        nowPlaying.deactivate()
        if holdsAudioSession {
            holdsAudioSession = false
            if releasingAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// Stop only if what is reading belongs to `ownerID` — called when a
    /// meeting or document screen goes away.
    func stop(owner ownerID: UUID) {
        guard item?.ownerID == ownerID else { return }
        stop()
    }

    // MARK: - Engine callbacks

    private func chunkStarted(_ index: Int) {
        chunkIndex = index
        if phase != .paused { phase = .speaking }
        publishNowPlaying()
    }

    private func fail(_ itemID: String, _ error: Error) {
        let appError = error as? AppError ?? .speechSynthesisFailed(error.localizedDescription)
        AppLog.generation.atError.error("ReadAloud: failed code=\(appError.logCode, privacy: .public)")
        stop()
        failure = (itemID, appError)
    }

    private static func makeEngine(
        provider: AIProvider,
        preferences: ReadAloudPreferences,
        languageCode: String?
    ) throws -> ReadAloudEngine {
        if provider.speechSynthesisAPI == .system {
            return SystemSpeechEngine(
                voiceIdentifier: preferences.voices[provider.id] ?? "",
                languageCode: languageCode,
                rate: preferences.rate
            )
        }
        let speech = try ProviderFactory.speechProvider(
            for: provider,
            model: preferences.model(for: provider),
            voice: preferences.voice(for: provider)
        )
        return CloudSpeechEngine(provider: speech, languageCode: languageCode, rate: preferences.rate)
    }

    private func activateAudioSession() throws {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            holdsAudioSession = true
        } catch {
            throw AppError.audioError(error.localizedDescription)
        }
    }

    // MARK: - System transport

    private func makeHandlers() -> NowPlayingController.Handlers {
        NowPlayingController.Handlers(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in
                guard let self else { return }
                if self.phase == .paused { self.resume() } else { self.pause() }
            },
            skip: { [weak self] interval in self?.skip(by: interval < 0 ? -1 : 1) },
            // Text has no timeline to scrub; the chunk position is published
            // as the elapsed time only so the Lock Screen shows progress.
            seek: { _ in }
        )
    }

    private func publishNowPlaying() {
        nowPlaying.update(
            title: item?.title,
            subtitle: item?.subtitle,
            duration: 0,
            position: 0,
            rate: phase == .speaking ? 1 : 0
        )
    }

    // MARK: - Session events

    private func registerNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    /// A call or alarm pauses reading; it does not auto-resume — a summary
    /// restarting mid-sentence after a phone call is more surprising than
    /// useful, and resume is one tap.
    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in self.pause() }
    }

    /// Unplugging headphones must not move a meeting's content to the speaker.
    @objc private nonisolated func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        Task { @MainActor in self.pause() }
    }
}
