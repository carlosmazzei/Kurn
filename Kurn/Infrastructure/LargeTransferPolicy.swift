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
        if snapshot.isConstrained && !allowsConstrainedAccess {
            throw AppError.networkPolicyRestricted
        }
        if snapshot.isExpensive && !allowsExpensiveAccess {
            throw AppError.networkPolicyRestricted
        }
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
