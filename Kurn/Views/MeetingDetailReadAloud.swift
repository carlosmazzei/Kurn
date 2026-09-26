//
//  MeetingDetailReadAloud.swift
//  Kurn
//
//  How a meeting's recording player and read-aloud share the one audio route.
//  Kept out of `MeetingDetailView`, whose body is already long, as a single
//  modifier.
//

import SwiftUI

extension View {
    /// Each side hands the route to the other instead of playing over it:
    /// starting to read pauses the recording (keeping its position), playing
    /// the recording stops reading without deactivating the session under the
    /// player, and opening the recorder or leaving the meeting stops reading.
    func readAloudCoordination(player: AudioPlayerService, meetingID: UUID, isRecording: Bool) -> some View {
        modifier(ReadAloudCoordination(player: player, meetingID: meetingID, isRecording: isRecording))
    }
}

private struct ReadAloudCoordination: ViewModifier {
    let player: AudioPlayerService
    let meetingID: UUID
    let isRecording: Bool

    private var readAloud: ReadAloudController { .shared }

    func body(content: Content) -> some View {
        content
            .onChange(of: readAloud.isActive) { _, reading in
                if reading { player.yieldToOtherAudio() }
            }
            .onChange(of: player.isPlaying) { _, playing in
                if playing { readAloud.stop(releasingAudioSession: false) }
            }
            .onChange(of: isRecording) { _, recording in
                if recording { readAloud.stop() }
            }
            .onDisappear { readAloud.stop(owner: meetingID) }
    }
}
