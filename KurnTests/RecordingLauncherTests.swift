//
//  RecordingLauncherTests.swift
//  KurnTests
//
//  `RecordingLauncher` is a singleton reached by `StartRecordingIntent` and
//  observed by `MeetingsListView`, so these tests share process-wide state
//  (`.shared`, and `RecordingCommandRouter.shared`) with each other — hence
//  `.serialized`, the same pattern `ProviderFactoryTests` uses for its own
//  shared Keychain/singleton state.
//

import SwiftData
import Testing
@testable import Kurn

@MainActor
@Suite(.serialized)
struct RecordingLauncherTests {

    private func makeLauncher(defaultLanguage: MeetingLanguage = .autoDetect) -> (RecordingLauncher, ModelContext) {
        let context = ModelContext(TestModelContainer.make())
        let settings = AppSettings()
        settings.defaultLanguage = defaultLanguage
        let launcher = RecordingLauncher.shared
        launcher.configure(modelContext: context, settings: settings)
        // Leave no state behind from a previous test in this suite.
        _ = launcher.consumePendingAutoStart()
        RecordingCommandRouter.shared.unregister()
        return (launcher, context)
    }

    @Test func requestAutoStartCreatesMeetingWithDefaultLanguage() throws {
        let (launcher, context) = makeLauncher(defaultLanguage: .portuguese)
        launcher.requestAutoStart()

        let meeting = try #require(launcher.pendingAutoStartMeeting)
        #expect(meeting.language == .portuguese)
        #expect(!meeting.title.isEmpty)

        let all = try context.fetch(FetchDescriptor<Meeting>())
        #expect(all.count == 1)
    }

    @Test func consumePendingAutoStartClearsPendingMeeting() {
        let (launcher, _) = makeLauncher()
        launcher.requestAutoStart()
        #expect(launcher.pendingAutoStartMeeting != nil)

        let consumed = launcher.consumePendingAutoStart()
        #expect(consumed != nil)
        #expect(launcher.pendingAutoStartMeeting == nil)
    }

    @Test func requestAutoStartIsNoOpWhileARecordingIsAlreadyInProgress() throws {
        let (launcher, context) = makeLauncher()
        RecordingCommandRouter.shared.register(
            onTogglePause: {}, onPause: {}, onResume: {}, onStop: {}, onHighlight: {}
        )
        defer { RecordingCommandRouter.shared.unregister() }

        launcher.requestAutoStart()

        #expect(launcher.pendingAutoStartMeeting == nil)
        let all = try context.fetch(FetchDescriptor<Meeting>())
        #expect(all.isEmpty)
    }
}
