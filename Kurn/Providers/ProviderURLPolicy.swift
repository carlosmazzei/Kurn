//
//  ProviderURLPolicy.swift
//  Kurn
//

import Foundation
import KurnCore

extension LLMHTTP {
    static func isValidBaseURL(_ baseURLString: String) -> Bool {
        validatedBaseURLComponents(baseURLString) != nil
    }

    static func endpoint(baseURLString: String, path: String) -> URL? {
        guard var components = validatedBaseURLComponents(baseURLString),
              !containsUnsafePath(path) else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }

    static func requireEndpoint(provider: AIProvider, path: String) throws -> URL {
        guard let url = endpoint(baseURLString: provider.baseURLString, path: path) else {
            throw AppError.invalidProviderURL
        }
        return url
    }

    static func redirectRequest(
        approvedURL: URL,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        guard let proposedURL = proposedRequest.url,
              let approvedOrigin = HTTPOrigin(approvedURL),
              let proposedOrigin = HTTPOrigin(proposedURL),
              approvedOrigin == proposedOrigin else { return nil }
        return proposedRequest
    }

    /// Fail fast with `AppError.noAPIKey` when a provider has no configured key.
    static func requireAPIKey(_ key: String, provider: AIProvider) throws {
        guard !key.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }
    }

    /// Build a `POST <base URL>/<path>` request carrying a JSON body — the shape
    /// every vendor's summary and chat call shares. `headers` carries the vendor's
    /// auth style (`Authorization: Bearer`, `x-api-key`, `x-goog-api-key`) on top
    /// of the JSON `Content-Type` set here.
    static func jsonRequest(
        provider: AIProvider,
        path: String,
        timeout: TimeInterval,
        headers: [String: String],
        body: [String: Any]
    ) throws -> URLRequest {
        var request = URLRequest(url: try requireEndpoint(provider: provider, path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private struct HTTPOrigin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = components.host?.lowercased(),
                  !host.isEmpty,
                  components.user == nil,
                  components.password == nil else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = components.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    private static func validatedBaseURLComponents(_ baseURLString: String) -> URLComponents? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              !isDisallowedHost(host),
              !containsUnsafePath(components.percentEncodedPath) else { return nil }
        return components
    }

    private static func containsUnsafePath(_ path: String) -> Bool {
        var decoded = path
        while true {
            guard let next = decoded.removingPercentEncoding else { return true }
            if next == decoded { break }
            decoded = next
        }
        let normalized = decoded.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/", omittingEmptySubsequences: false).contains {
            $0 == "." || $0 == ".."
        }
    }

    private static func isDisallowedHost(_ host: String) -> Bool {
        if host.contains(":") { return true }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return true }
        if host == "localhost" || host == "home.arpa" { return true }
        let localSuffixes = [".localhost", ".local", ".internal", ".lan", ".home", ".home.arpa"]
        if localSuffixes.contains(where: host.hasSuffix) { return true }
        return isIPv4Literal(host)
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            !octet.isEmpty && octet.allSatisfy(\.isNumber)
        }
    }
}
