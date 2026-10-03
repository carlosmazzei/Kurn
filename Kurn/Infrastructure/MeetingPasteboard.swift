//
//  MeetingPasteboard.swift
//  Kurn
//
//  Copying meeting content (a transcript, a summary) to the clipboard. A plain
//  `UIPasteboard.general.string = …` leaves the text there indefinitely, for
//  any app that later reads the pasteboard, and Universal Clipboard hands it
//  to every other device on the same Apple Account. Meeting text is the most
//  private thing the app holds, so a copy stays on this device and expires.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

enum MeetingPasteboard {
    /// Long enough to switch apps and paste; short enough that the text does
    /// not sit on the pasteboard for the rest of the day.
    static let lifetime: TimeInterval = 120

    /// `.localOnly` keeps it off Universal Clipboard; `.expirationDate`
    /// clears it after `lifetime`.
    static func options(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [
            .localOnly: true,
            .expirationDate: now.addingTimeInterval(lifetime)
        ]
    }

    @MainActor
    static func copy(_ text: String, to pasteboard: UIPasteboard = .general, now: Date = Date()) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: options(now: now)
        )
    }
}
