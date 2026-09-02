//
//  WhisperBackgroundUploaderTests.swift
//  KurnTests
//
//  H8 PR 18: `WhisperBackgroundUploader.session` used to be a `lazy var` —
//  not thread-safe, since concurrent first accesses can run the initializer
//  twice and silently drop one of the constructed `URLSession`s. That was
//  already fixed (a lock-guarded `storedSession` check-and-set, see the
//  file's own header) before this PR, but nothing proved the fix actually
//  holds under real concurrent access. This does, using a dedicated
//  instance rather than `.shared` so the test doesn't touch the app-wide
//  singleton other tests/production code might rely on.
//

import Foundation
import Testing
@testable import Kurn

struct WhisperBackgroundUploaderTests {

    @Test func concurrentFirstAccessesShareOneSessionInstance() async {
        let uploader = WhisperBackgroundUploader()

        let sessions = await withTaskGroup(of: URLSession.self) { group in
            for _ in 0..<20 {
                group.addTask { uploader.sessionForTesting }
            }
            var results: [URLSession] = []
            for await session in group {
                results.append(session)
            }
            return results
        }

        #expect(sessions.count == 20)
        let first = sessions[0]
        #expect(sessions.allSatisfy { $0 === first })
    }
}
