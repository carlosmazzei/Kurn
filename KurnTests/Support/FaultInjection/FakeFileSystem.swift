//
//  FakeFileSystem.swift
//  KurnTests
//
//  A `FileSystem` double that reports a fixed set of URLs and can be told to
//  fail `removeItem` for specific paths, so a test can prove a call site
//  handles a deletion failure the way it does today (log and continue)
//  without needing a real, hard-to-provoke filesystem error.
//

import Foundation
import KurnCore

final class FakeFileSystem: FileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [URL: [URL]] = [:]
    private var failingRemovals: Set<URL> = []
    private(set) var removalAttempts: [URL] = []

    func setContents(_ urls: [URL], of directory: URL) {
        lock.lock(); defer { lock.unlock() }
        contents[directory] = urls
    }

    func failRemoval(of url: URL) {
        lock.lock(); defer { lock.unlock() }
        failingRemovals.insert(url)
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return contents[url] ?? []
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        removalAttempts.append(url)
        let shouldFail = failingRemovals.contains(url)
        lock.unlock()
        if shouldFail {
            throw NSError(domain: "FakeFileSystem", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "simulated removal failure"
            ])
        }
    }
}
