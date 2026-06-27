//
//  MockURLProtocol.swift
//  KurnTests
//
//  A `URLProtocol` that intercepts requests and replays scripted responses so
//  provider tests can exercise request construction and response parsing
//  without ever touching the network. Inject it with `MockURLProtocol.session()`
//  and feed it stubs with `enqueue(_:)` — one stub is consumed per request, in
//  order, which is enough to drive the retry path (e.g. 429 then 200).
//
//  The scripted state is process-global, so suites that use it must be marked
//  `@Suite(.serialized)`.
//

import Foundation

final class MockURLProtocol: URLProtocol {

    /// One scripted outcome for a single request.
    enum Stub {
        case success(status: Int, body: Data, headers: [String: String])
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    // MARK: - Test-facing API

    /// A `URLSession` wired to this protocol (and nothing else).
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Replace the scripted responses and reset captured requests.
    static func enqueue(_ newStubs: [Stub]) {
        lock.lock(); defer { lock.unlock() }
        stubs = newStubs
        captured = []
    }

    /// Convenience: a 2xx JSON response built from a `JSONSerialization` object.
    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Stub {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .success(status: status, body: data, headers: headers)
    }

    /// Requests captured since the last `enqueue`, in order. Each has had its
    /// body stream drained into `httpBody` so tests can assert on the payload.
    static var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static var lastRequest: URLRequest? { capturedRequests.last }

    /// Read a request body, whether delivered as `httpBody` or a body stream
    /// (URLProtocol normally exposes the body as a stream).
    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Internal helpers

    private static func nextStub() -> Stub? {
        lock.lock(); defer { lock.unlock() }
        guard !stubs.isEmpty else { return nil }
        return stubs.removeFirst()
    }

    private static func capture(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Snapshot the request with its body materialized so tests can inspect it.
        var snapshot = request
        snapshot.httpBody = MockURLProtocol.body(of: request)
        MockURLProtocol.capture(snapshot)

        guard let stub = MockURLProtocol.nextStub() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        switch stub {
        case let .success(status, body, headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
