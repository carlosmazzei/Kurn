//
//  LargeTransferPolicy.swift
//  Kurn
//

import Foundation
import KurnCore
import Network

struct NetworkPathSnapshot: Equatable, Sendable {
    var isExpensive: Bool
    var isConstrained: Bool
    var isKnown = true
}

protocol NetworkPathSnapshotProviding: Sendable {
    var snapshot: NetworkPathSnapshot { get }
}

struct LargeTransferPolicy: Equatable, Sendable {
    var allowsExpensiveAccess: Bool
    var allowsConstrainedAccess: Bool

    static let wifiOnly = Self(
        allowsExpensiveAccess: false,
        allowsConstrainedAccess: false
    )

    func validate(_ snapshot: NetworkPathSnapshot) throws {
        guard snapshot.isKnown else { throw AppError.networkPolicyRestricted }
        if blocks(snapshot) { throw AppError.networkPolicyRestricted }
    }

    /// Whether this policy refuses the given (known) path: cellular while
    /// cellular is off, or Low Data Mode while that is off.
    func blocks(_ snapshot: NetworkPathSnapshot) -> Bool {
        (snapshot.isConstrained && !allowsConstrainedAccess)
            || (snapshot.isExpensive && !allowsExpensiveAccess)
    }

    static func restrictionError(for error: Error) -> AppError? {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.networkUnavailableReason {
        case .constrained, .expensive:
            return .networkPolicyRestricted
        default:
            return nil
        }
    }

    /// `restrictionError(for:)`, plus the case the native reason misses.
    /// URLSession does not always populate `networkUnavailableReason` when a
    /// request that disallows expensive/constrained access meets a cellular or
    /// Low Data Mode path; the failure then arrives as a bare
    /// `.notConnectedToInternet`, which read to the user as "you are offline"
    /// while they plainly had signal — and got retried as a transient blip.
    /// Judging it against the live path and the request's own flags tells the
    /// two apart: a genuinely offline device has neither an expensive nor a
    /// constrained path, so it keeps the plain network error.
    static func restrictionError(
        for error: Error,
        request: URLRequest,
        snapshot: NetworkPathSnapshot
    ) -> AppError? {
        if let native = restrictionError(for: error) { return native }
        guard let urlError = error as? URLError,
              urlError.code == .notConnectedToInternet,
              snapshot.isKnown else { return nil }
        let requestPolicy = LargeTransferPolicy(
            allowsExpensiveAccess: request.allowsExpensiveNetworkAccess,
            allowsConstrainedAccess: request.allowsConstrainedNetworkAccess
        )
        return requestPolicy.blocks(snapshot) ? .networkPolicyRestricted : nil
    }

    func apply(to request: inout URLRequest) {
        request.allowsExpensiveNetworkAccess = allowsExpensiveAccess
        request.allowsConstrainedNetworkAccess = allowsConstrainedAccess
    }

    func apply(to configuration: URLSessionConfiguration) {
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveAccess
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedAccess
    }
}

final class NetworkPathObserver: NetworkPathSnapshotProviding, @unchecked Sendable {
    static let shared = NetworkPathObserver()

    private let lock = NSLock()
    private let monitor: NWPathMonitor
    private var currentSnapshot: NetworkPathSnapshot

    private init() {
        monitor = NWPathMonitor()
        currentSnapshot = Self.snapshot(from: monitor.currentPath, isKnown: true)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock {
                self?.currentSnapshot = Self.snapshot(from: path, isKnown: true)
            }
        }
        monitor.start(queue: DispatchQueue(label: "ai.kurn.network-path"))
    }

    var snapshot: NetworkPathSnapshot {
        lock.withLock { currentSnapshot }
    }

    private static func snapshot(from path: NWPath, isKnown: Bool) -> NetworkPathSnapshot {
        NetworkPathSnapshot(
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            isKnown: isKnown
        )
    }
}
