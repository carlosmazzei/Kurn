//
//  MeetingPasteboardTests.swift
//  KurnTests
//
//  Meeting text copied to the clipboard stays on this device and expires.
//

import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Kurn

@MainActor
struct MeetingPasteboardTests {

    @Test func copiesAreLocalOnlyAndExpire() {
        let now = Date(timeIntervalSince1970: 1_000)
        let options = MeetingPasteboard.options(now: now)
        #expect(options[.localOnly] as? Bool == true)
        #expect(options[.expirationDate] as? Date == now.addingTimeInterval(MeetingPasteboard.lifetime))
        #expect(MeetingPasteboard.lifetime <= 300)
    }

    @Test func theTextIsWrittenAsPlainText() throws {
        let pasteboard = try #require(UIPasteboard(name: UIPasteboard.Name("kurn-tests-\(UUID().uuidString)"), create: true))
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        MeetingPasteboard.copy("Decision: ship on Monday", to: pasteboard)

        #expect(pasteboard.string == "Decision: ship on Monday")
    }
}
