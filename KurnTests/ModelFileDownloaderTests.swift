//
//  ModelFileDownloaderTests.swift
//  KurnTests
//
//  H7 PR 15: proves the fetch → verify → install sequence actually behaves
//  as documented — exact-size verification against the server's declared
//  `Content-Length`, opportunistic SHA-256 verification via `X-Linked-ETag`,
//  atomic replacement of an existing file, and preservation of the previous
//  file whenever verification or install fails — against `MockURLProtocol`
//  rather than a real host. Serialized because `MockURLProtocol`'s scripted
//  state is process-global (see its own header).
//

import CryptoKit
import Foundation
import KurnCore
import Testing
@testable import Kurn

@Suite(.serialized)
struct ModelFileDownloaderTests {

    private func makeDownloader() -> ModelFileDownloader {
        ModelFileDownloader(protocolClasses: [MockURLProtocol.self])
    }

    private func tempDestination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelFileDownloaderTests-\(UUID().uuidString)")
            .appendingPathComponent("model.bin")
    }

    /// Computed directly with `CryptoKit` (rather than by calling
    /// `PipelineDigest`) so the expected value in each test is visibly
    /// derived from the raw bytes, not round-tripped through the same
    /// helper `ModelFileDownloader` uses internally.
    private func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Exact size verification

    @Test("installs a file whose size matches the declared Content-Length")
    func installsWhenSizeMatches() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let body = Data(repeating: 0x41, count: 1_000)
        MockURLProtocol.enqueue([
            .success(status: 200, body: body, headers: ["Content-Length": "\(body.count)"])
        ])

        try await downloader.fetch(
            url: URL(string: "https://example.com/model.bin")!,
            destination: destination,
            minimumPlausibleBytes: 500,
            policy: .wifiOnly,
            logLabel: "test"
        ) { _ in }

        let installed = try Data(contentsOf: destination)
        #expect(installed == body)
    }

    @Test("rejects a file whose size does not match the declared Content-Length")
    func rejectsWhenSizeMismatches() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let body = Data(repeating: 0x41, count: 1_000)
        // Declare a length longer than the body actually delivered.
        MockURLProtocol.enqueue([
            .success(status: 200, body: body, headers: ["Content-Length": "\(body.count + 500)"])
        ])

        await #expect(throws: AppError.self) {
            try await downloader.fetch(
                url: URL(string: "https://example.com/model.bin")!,
                destination: destination,
                minimumPlausibleBytes: 500,
                policy: .wifiOnly,
                logLabel: "test"
            ) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Opportunistic hash verification

    @Test("installs a file whose SHA-256 matches X-Linked-ETag")
    func installsWhenHashMatches() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let body = Data(repeating: 0x7A, count: 2_048)
        let hex = sha256Hex(of: body)
        MockURLProtocol.enqueue([
            .success(status: 200, body: body, headers: [
                "Content-Length": "\(body.count)",
                "X-Linked-ETag": hex
            ])
        ])

        try await downloader.fetch(
            url: URL(string: "https://example.com/model.bin")!,
            destination: destination,
            minimumPlausibleBytes: 500,
            policy: .wifiOnly,
            logLabel: "test"
        ) { _ in }

        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("rejects a file whose SHA-256 does not match X-Linked-ETag")
    func rejectsWhenHashMismatches() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let body = Data(repeating: 0x7A, count: 2_048)
        let wrongHex = String(repeating: "0", count: 64)
        MockURLProtocol.enqueue([
            .success(status: 200, body: body, headers: [
                "Content-Length": "\(body.count)",
                "X-Linked-ETag": wrongHex
            ])
        ])

        await #expect(throws: AppError.self) {
            try await downloader.fetch(
                url: URL(string: "https://example.com/model.bin")!,
                destination: destination,
                minimumPlausibleBytes: 500,
                policy: .wifiOnly,
                logLabel: "test"
            ) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a plain ETag is never treated as a hash to verify")
    func plainETagIsIgnored() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let body = Data(repeating: 0x11, count: 512)
        // A short, quoted git-blob-style ETag: not 64 hex characters, so it
        // must be ignored rather than compared against as a checksum.
        MockURLProtocol.enqueue([
            .success(status: 200, body: body, headers: [
                "Content-Length": "\(body.count)",
                "ETag": "\"abc123\""
            ])
        ])

        try await downloader.fetch(
            url: URL(string: "https://example.com/model.bin")!,
            destination: destination,
            minimumPlausibleBytes: 100,
            policy: .wifiOnly,
            logLabel: "test"
        ) { _ in }

        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Atomic replacement and preservation of the previous file

    @Test("replaces an existing installed file atomically")
    func replacesExistingFile() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data(repeating: 0x01, count: 1_000)
        try original.write(to: destination)

        let replacement = Data(repeating: 0x02, count: 1_500)
        MockURLProtocol.enqueue([
            .success(status: 200, body: replacement, headers: ["Content-Length": "\(replacement.count)"])
        ])

        try await downloader.fetch(
            url: URL(string: "https://example.com/model.bin")!,
            destination: destination,
            // Below the original's size, so `fetch` doesn't short-circuit as
            // "already installed" and skip the network call entirely.
            minimumPlausibleBytes: replacement.count.int64Value,
            policy: .wifiOnly,
            logLabel: "test"
        ) { _ in }

        let installed = try Data(contentsOf: destination)
        #expect(installed == replacement)
        // No leftover backup file beside the installed one.
        let siblingCount = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).count
        #expect(siblingCount == 1)
    }

    @Test("preserves the previous file when the new download fails verification")
    func preservesPreviousFileOnVerificationFailure() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data(repeating: 0x01, count: 1_000)
        try original.write(to: destination)

        let replacement = Data(repeating: 0x02, count: 1_500)
        MockURLProtocol.enqueue([
            // Declared length disagrees with the actual body, so verification
            // must fail before install ever touches the destination.
            .success(status: 200, body: replacement, headers: ["Content-Length": "\(replacement.count + 100)"])
        ])

        await #expect(throws: AppError.self) {
            try await downloader.fetch(
                url: URL(string: "https://example.com/model.bin")!,
                destination: destination,
                minimumPlausibleBytes: replacement.count.int64Value,
                policy: .wifiOnly,
                logLabel: "test"
            ) { _ in }
        }

        let stillThere = try Data(contentsOf: destination)
        #expect(stillThere == original)
    }

    // MARK: - Skip when already installed

    @Test("does not make a network call when a plausible file is already installed")
    func skipsWhenAlreadyInstalled() async throws {
        let downloader = makeDownloader()
        let destination = tempDestination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x01, count: 1_000).write(to: destination)

        MockURLProtocol.enqueue([]) // any request would fail with no stub to consume

        try await downloader.fetch(
            url: URL(string: "https://example.com/model.bin")!,
            destination: destination,
            minimumPlausibleBytes: 500,
            policy: .wifiOnly,
            logLabel: "test"
        ) { _ in }

        #expect(MockURLProtocol.capturedRequests.isEmpty)
    }
}

private extension Int {
    var int64Value: Int64 { Int64(self) }
}
