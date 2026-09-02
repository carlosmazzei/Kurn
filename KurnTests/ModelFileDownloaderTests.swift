//
//  ModelFileDownloaderTests.swift
//  KurnTests
//
//  H7 PR 15: proves the fetch → verify → install sequence actually behaves
//  as documented — exact-size verification against the server's declared
//  `Content-Length`, opportunistic SHA-256 verification via `X-Linked-ETag`,
//  atomic replacement of an existing file, and preservation of the previous
//  file whenever verification or install fails.
//
//  Uses a dedicated `StubDownloadProtocol` rather than the shared
//  `MockURLProtocol`: five other files already share that one's
//  process-global stub queue and are each `.serialized` only *within* their
//  own suite, which does not stop Swift Testing from running two different
//  suites concurrently — a first version of this file used `MockURLProtocol`
//  and, in CI, a request from this suite was captured and consumed by a
//  `ProviderHTTPTests` assertion running at the same moment (and vice
//  versa). A private protocol with its own storage, touched by nothing but
//  this file, removes that cross-suite race instead of trying to serialize
//  the whole test target. `@Suite(.serialized)` is kept because tests
//  within *this* suite still share `StubDownloadProtocol`'s one static stub.
//

import CryptoKit
import Foundation
import KurnCore
import Testing
@testable import Kurn

/// A single-stub `URLProtocol` double, private to this file. Supports both
/// data and download tasks (the URL Loading System buffers a protocol's
/// `didLoad` data and writes it to a temp file for a download task
/// automatically), which is all `ModelFileDownloader` needs.
private final class StubDownloadProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub: Stub?
    nonisolated(unsafe) private static var requestCount = 0

    static func enqueue(_ newStub: Stub?) {
        lock.lock()
        stub = newStub
        requestCount = 0
        lock.unlock()
    }

    static var capturedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let stub = Self.stub
        Self.lock.unlock()

        guard let stub, let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ModelFileDownloaderTests {

    private func makeDownloader() -> ModelFileDownloader {
        ModelFileDownloader(protocolClasses: [StubDownloadProtocol.self])
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
        StubDownloadProtocol.enqueue(.init(body: body, headers: ["Content-Length": "\(body.count)"]))

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
        StubDownloadProtocol.enqueue(.init(body: body, headers: ["Content-Length": "\(body.count + 500)"]))

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
        StubDownloadProtocol.enqueue(.init(body: body, headers: [
            "Content-Length": "\(body.count)",
            "X-Linked-ETag": hex
        ]))

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
        StubDownloadProtocol.enqueue(.init(body: body, headers: [
            "Content-Length": "\(body.count)",
            "X-Linked-ETag": wrongHex
        ]))

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
        StubDownloadProtocol.enqueue(.init(body: body, headers: [
            "Content-Length": "\(body.count)",
            "ETag": "\"abc123\""
        ]))

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
        StubDownloadProtocol.enqueue(.init(body: replacement, headers: ["Content-Length": "\(replacement.count)"]))

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
        // Declared length disagrees with the actual body, so verification
        // must fail before install ever touches the destination.
        StubDownloadProtocol.enqueue(
            .init(body: replacement, headers: ["Content-Length": "\(replacement.count + 100)"])
        )

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

        StubDownloadProtocol.enqueue(nil) // any request would fail with no stub to answer it

        try await downloader.fetch(
            url: URL(string: "https://example.com/model.bin")!,
            destination: destination,
            minimumPlausibleBytes: 500,
            policy: .wifiOnly,
            logLabel: "test"
        ) { _ in }

        #expect(StubDownloadProtocol.capturedRequestCount == 0)
    }
}

private extension Int {
    var int64Value: Int64 { Int64(self) }
}
