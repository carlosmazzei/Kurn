//
//  FileSystem.swift
//  KurnCore
//
//  `FileManager.default` is called directly and pervasively across the app
//  (40+ call sites) with no seam anywhere — every filesystem interaction is
//  untestable except against a real directory. This is deliberately not a
//  full `FileManager` wrapper: it covers only the two operations
//  `TempFileCleaner.sweep` actually calls, so a test can inject a removal
//  failure without pretending to model every filesystem operation the app
//  performs. Widening this to cover `AudioFileStore`'s much larger surface
//  (`createDirectory`, file-protection attributes, `attributesOfItem`, …) is
//  deliberately left for when H1/H3 touch the real audio-write path.
//

import Foundation

public protocol FileSystem: Sendable {
    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL]

    func removeItem(at url: URL) throws
}

public struct SystemFileSystem: FileSystem {
    public init() {}

    public func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: options
        )
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
